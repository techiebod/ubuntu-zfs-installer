#!/bin/bash
#
# Manage ZFS Root Snapshots
#
# This script handles the creation, deletion, and listing of ZFS snapshots
# for root datasets.

# --- Script Setup ---
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$script_dir/../lib/common.sh"

# --- Script-specific Default values ---
POOL_NAME="${DEFAULT_POOL_NAME}"
SNAPSHOT_PREFIX="build-stage"

# --- Function to create a snapshot without timestamp ---
create_snapshot() {
    local dataset="$1"
    local stage_name="$2"
    local snapshot_name="${SNAPSHOT_PREFIX}-${stage_name}"
    local full_snapshot="${dataset}@${snapshot_name}"

    log_info "Creating ZFS snapshot: $full_snapshot"

    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY RUN] Would create snapshot: $full_snapshot"
        echo "$full_snapshot" # Still output the name for scripting
        return 0
    fi

    # Remove any existing snapshot with the same name first
    if zfs list -t snapshot "$full_snapshot" >/dev/null 2>&1; then
        log_info "Removing existing snapshot: $full_snapshot"
        if ! zfs destroy "$full_snapshot"; then
            die "Failed to remove existing snapshot: $full_snapshot"
        fi
    fi

    if zfs snapshot "$full_snapshot"; then
        log_info "Successfully created snapshot: $full_snapshot"
        echo "$full_snapshot"
    else
        die "Failed to create snapshot: $full_snapshot"
    fi
}

# --- Function to list snapshots for a dataset ---
list_snapshots() {
    local dataset="$1"
    local filter_pattern="${2:-${SNAPSHOT_PREFIX}}"

    echo "listing snapshots for dataset: $dataset"

    local snapshots
    snapshots=$(zfs list -t snapshot -o name,creation,used -S creation -H "$dataset" 2>/dev/null | grep "@${filter_pattern}")

    if [[ -z "$snapshots" ]]; then
        echo "no snapshots found matching pattern: $filter_pattern"
        return 0
    fi

    printf "%-60s %-20s %-10s\n" "snapshot name" "creation time" "used"
    printf "%-60s %-20s %-10s\n" "-----------------------------------------------------------" "--------------------" "----------"
    echo "$snapshots" | while read -r name creation used; do
        printf "%-60s %-20s %-10s\n" \
            "$(basename "$name")" \
            "$creation" \
            "$used"
    done
}

# --- Function to rollback to a snapshot ---
rollback_to_snapshot() {
    local dataset="$1"
    local snapshot_name="$2"
    local full_snapshot="${dataset}@${snapshot_name}"

    log_warn "This is a destructive operation."
    log_warn "Rolling back dataset '$dataset' to snapshot:"
    log_warn "  $snapshot_name"

    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY RUN] Would rollback to: $full_snapshot"
        return 0
    fi

    # Validate snapshot exists
    if ! zfs list -t snapshot -H -o name "$full_snapshot" &>/dev/null; then
        die "Snapshot does not exist: $full_snapshot"
    fi

    # Perform rollback
    if zfs rollback -r "$full_snapshot"; then
        log_info "Successfully rolled back to: $full_snapshot"
    else
        die "Failed to rollback to: $full_snapshot"
    fi
}

# --- Function to rollback to a specific stage (convenience wrapper) ---
rollback_to_stage() {
    local dataset="$1"
    local stage_name="$2"
    local snapshot_name="${SNAPSHOT_PREFIX}-${stage_name}"

    log_info "Rolling back $dataset to stage: $stage_name"
    rollback_to_snapshot "$dataset" "$snapshot_name"
}

# --- Function to remove old snapshots (keep latest N) ---
cleanup_old_snapshots() {
    local dataset="$1"
    local stage_name="$2"
    local keep_count="${3:-3}" # Default to keeping 3

    log_info "Cleaning up old snapshots for stage: '$stage_name' (keeping latest $keep_count)"

    local pattern="${dataset}@${SNAPSHOT_PREFIX}-${stage_name}"
    local snapshots
    snapshots=($(zfs list -t snapshot -o name -S creation -H "$dataset" 2>/dev/null | grep "$pattern"))

    if [[ ${#snapshots[@]} -le $keep_count ]]; then
        log_info "Only ${#snapshots[@]} snapshots found, no cleanup needed."
        return 0
    fi

    local to_remove=("${snapshots[@]:$keep_count}")

    for snapshot in "${to_remove[@]}"; do
        log_info "Removing old snapshot: $snapshot"

        if [[ "$DRY_RUN" == true ]]; then
            log_info "[DRY RUN] Would remove: $snapshot"
        else
            if zfs destroy "$snapshot"; then
                log_info "Removed snapshot: $snapshot"
            else
                log_error "Failed to remove snapshot: $snapshot" # Non-fatal
            fi
        fi
    done
}

# --- Usage Information ---
show_usage() {
    cat << EOF
Usage: $0 [OPTIONS] <ACTION> <NAME> [ARGUMENT]

Manage ZFS snapshots for root datasets.

ACTIONS:
  create <NAME> <stage>       Create a snapshot for a build stage.
                              'stage' is a descriptive name (e.g., 'base-os').

  list <NAME> [pattern]       List snapshots for a root dataset.
                              'pattern' filters by snapshot name.

  rollback <NAME> <snapshot>  Rollback to a specific snapshot.
                              'snapshot' is the full name (e.g., build-stage-base-os-...).

  cleanup <NAME> <stage>      Remove old snapshots for a stage, keeping the last 3.

ARGUMENTS:
  NAME                        The name of the root dataset (e.g., 'plucky').
  stage                       A short name for the build stage (e.g., 'base-os', 'ansible-done').
  snapshot                    The full name of the snapshot to roll back to.
  pattern                     A pattern to filter snapshot names in the list action.

OPTIONS:
  -p, --pool POOL             The ZFS pool to operate on (default: ${DEFAULT_POOL_NAME}).
  -v, --verbose               Enable verbose output.
  -n, --dry-run               Show what would be done without executing.
  -d, --debug                 Enable detailed debug logging.
  -h, --help                  Show this help message.

EXAMPLES:
  # Create a snapshot after base OS installation for 'plucky'
  $0 create plucky base-os

  # List all snapshots for 'plucky'
  $0 list plucky

  # Rollback 'plucky' to a specific state
  $0 rollback plucky build-stage-base-os-20250723-143022

  # Clean up old 'base-os' snapshots for 'plucky'
  $0 cleanup plucky base-os
EOF
    exit 0
}

# --- Main function ---
main() {
    # For list action, disable timestamps for cleaner output
    [[ "${1:-}" == "list" ]] && LOG_WITH_TIMESTAMPS=false

    local action=""
    local root_name=""
    local argument=""

    # Argument parsing
    while [[ $# -gt 0 ]]; do
        case $1 in
            -p|--pool) POOL_NAME="$2"; shift 2 ;;
            -v|--verbose) VERBOSE=true; shift ;;
            -n|--dry-run) DRY_RUN=true; shift ;;
            -d|--debug) DEBUG=true; shift ;;
            -h|--help) show_usage ;;
            -*) die "Unknown option: $1" ;;
            *)
                if [[ -z "$action" ]]; then
                    action="$1"
                elif [[ -z "$root_name" ]]; then
                    root_name="$1"
                elif [[ -z "$argument" ]]; then
                    argument="$1"
                else
                    die "Too many arguments."
                fi
                shift
                ;;
        esac
    done

    # Validate required arguments
    if [[ -z "$action" || -z "$root_name" ]]; then
        show_usage
        die "Missing required arguments: action and/or name."
    fi

    local dataset="${POOL_NAME}/ROOT/${root_name}"

    # Validate dataset exists
    if ! zfs list -H -o name "$dataset" &>/dev/null; then
        die "Root dataset does not exist: $dataset"
    fi

    # Execute action
    case "$action" in
        create)
            if [[ -z "$argument" ]]; then
                die "Stage name required for 'create' action."
            fi
            create_snapshot "$dataset" "$argument"
            ;;
        list)
            list_snapshots "$dataset" "$argument"
            ;;
        rollback)
            if [[ -z "$argument" ]]; then
                die "Snapshot name required for 'rollback' action."
            fi
            rollback_to_snapshot "$dataset" "$argument"
            ;;
        cleanup)
            if [[ -z "$argument" ]]; then
                die "Stage name required for 'cleanup' action."
            fi
            cleanup_old_snapshots "$dataset" "$argument"
            ;;
        *)
            die "Unknown action: $action"
            ;;
    esac
}

# --- Execute Main Function ---
(
    main "$@"
)
