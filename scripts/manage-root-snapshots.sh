#!/bin/bash
#
# Manage ZFS Root Snapshots
#
# This script handles the creation, deletion, and listing of ZFS snapshots
# for root datasets.

# --- Script Setup ---
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
lib_dir="$script_dir/../lib"

# Load the core library which sets up essential project structure and variables
source "$lib_dir/core.sh"

# Load libraries we need
source "$lib_dir/logging.sh"         # For logging functions
source "$lib_dir/execution.sh"       # For argument parsing and run_cmd
source "$lib_dir/validation.sh"      # For build name validation
source "$lib_dir/dependencies.sh"    # For require_command (zfs)
source "$lib_dir/zfs.sh"             # For ZFS operations (primary functionality)
source "$lib_dir/flag-helpers.sh"    # For common flag definitions

# Load shflags library
source "$lib_dir/vendor/shflags"

# --- Flag definitions ---
DEFINE_string 'pool' "${DEFAULT_POOL_NAME}" 'The ZFS pool to operate on' 'p'
define_common_flags  # Add standard dry-run and debug flags

# --- Function to create a snapshot without timestamp ---
create_snapshot() {
    local dataset="$1"
    local stage_name="$2"
    
    log_info "Creating ZFS snapshot for stage: $stage_name"

    # Use the ZFS library function with timestamp
    local snapshot_path
    snapshot_path=$(zfs_create_snapshot "$dataset" "$stage_name")
    
    echo "$snapshot_path"
}

# --- Function to list snapshots for a dataset ---
list_snapshots() {
    local dataset="$1"
    local filter_pattern="${2:-${SNAPSHOT_PREFIX}}"

    log_info "Listing snapshots for dataset: $dataset"

    # Use ZFS library function
    local snapshots
    snapshots=$(zfs_list_snapshots "$dataset" "$filter_pattern")

    if [[ -z "$snapshots" ]]; then
        log_info "no snapshots found matching pattern: $filter_pattern"
        return 0
    fi

    # Get detailed information for each snapshot
    local snapshot_details
    snapshot_details=$(zfs list -t snapshot -o name,creation,used -S creation -H "$dataset" 2>/dev/null | grep "@${filter_pattern}")
    
    if [[ -z "$snapshot_details" ]]; then
        log_info "no snapshots found matching pattern: $filter_pattern"
        return 0
    fi

    printf "%-60s %-20s %-10s\n" "snapshot name" "creation time" "used"
    printf "%-60s %-20s %-10s\n" "-----------------------------------------------------------" "--------------------" "----------"
    echo "$snapshot_details" | while read -r name creation used; do
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

    # Use ZFS library function with force flag
    zfs_rollback_snapshot "$full_snapshot" --force
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
    mapfile -t snapshots < <(zfs list -t snapshot -o name -S creation -H "$dataset" 2>/dev/null | grep "$pattern")

    if [[ ${#snapshots[@]} -le $keep_count ]]; then
        log_info "Only ${#snapshots[@]} snapshots found, no cleanup needed."
        return 0
    fi

    local to_remove=("${snapshots[@]:$keep_count}")

    for snapshot in "${to_remove[@]}"; do
        log_info "Removing old snapshot: $snapshot"
        run_cmd zfs destroy "$snapshot"
    done
}

# --- Usage Information ---
show_usage() {
    cat << EOF
Usage: $0 [OPTIONS] <ACTION> <NAME> [ARGUMENT]

Manage ZFS snapshots for root datasets.

ACTIONS:
  create NAME STAGE        Create a snapshot for a build stage.
                              'STAGE' is a descriptive name (e.g., 'base-os').

  list NAME [PATTERN]      List snapshots for a root dataset.
                              'PATTERN' filters by snapshot name.

  rollback NAME SNAPSHOT   Rollback to a specific snapshot.
                              'SNAPSHOT' is the full name (e.g., build-stage-base-os-...).

  cleanup NAME STAGE       Remove old snapshots for a stage, keeping the last 3.

ARGUMENTS:
  NAME                        The name of the root dataset (e.g., 'plucky').
  STAGE                       A short name for the build stage (e.g., 'base-os', 'ansible-done').
  SNAPSHOT                    The full name of the snapshot to roll back to.
  PATTERN                     A pattern to filter snapshot names in the list action.

EOF
    flags_help
    cat << EOF

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
}

# --- Parse command line arguments ---
parse_arguments() {
    # Parse flags
    FLAGS "$@" || exit 1
    eval set -- "${FLAGS_ARGV}"
    
    # Set global variables from flags with proper boolean conversion
    POOL_NAME="${FLAGS_pool}"
    # Process common flags (dry-run and debug)
    process_common_flags
}

# --- Main function ---
main() {
    # Parse arguments
    parse_arguments "$@"
    eval set -- "${FLAGS_ARGV}"
    
    # Disable timestamps for cleaner output in interactive mode
    if is_interactive_mode; then
        # shellcheck disable=SC2034  # Used by logging system
        LOG_WITH_TIMESTAMPS=false
    fi

    local action=""
    local root_name=""
    local argument=""

    # Parse positional arguments
    if [[ $# -gt 0 ]]; then
        action="$1"
        shift
    fi
    
    if [[ $# -gt 0 ]]; then
        root_name="$1"
        shift
    fi
    
    if [[ $# -gt 0 ]]; then
        argument="$1"
        shift
    fi

    # Validate required arguments
    if [[ -z "$action" || -z "$root_name" ]]; then
        echo "Usage: $(basename "$0") [OPTIONS] <ACTION> <NAME> [ARGUMENT]"
        echo ""
        echo "ACTIONS: create, list, rollback, cleanup"
        echo "Run '$(basename "$0") --help' for flag options"
        echo ""
        echo "Examples:"
        echo "  $(basename "$0") create plucky base-os"
        echo "  $(basename "$0") list plucky"
        echo "  $(basename "$0") rollback plucky build-stage-base-os-20250723-143022"
        echo "  $(basename "$0") cleanup plucky base-os"
        die "Missing required arguments: action and/or name."
    fi

    local dataset
    dataset=$(zfs_get_root_dataset_path "$POOL_NAME" "$root_name")

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
main "$@"
