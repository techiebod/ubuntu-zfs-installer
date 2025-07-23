#!/bin/bash

# ZFS Snapshot Manager for Build Stages
# Usage: ./zfs-snapshot-manager.sh [OPTIONS] <action> <dataset> [snapshot_name]
#
# QUICK REFERENCE:
# - Snapshots are named: build-stage-{stage}-{timestamp}
# - Common stages: datasets-created, base-os, varlog-mounted, ansible-complete
# - List snapshots: ./zfs-snapshot-manager.sh list zroot/ROOT/plucky
# - Create snapshot: ./zfs-snapshot-manager.sh create zroot/ROOT/plucky my-stage
# - Rollback: ./zfs-snapshot-manager.sh rollback zroot/ROOT/plucky <full-snapshot-name>
# - Cleanup old: ./zfs-snapshot-manager.sh cleanup zroot/ROOT/plucky base-os

set -euo pipefail

# Source common library
script_dir="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
source "$script_dir/../lib/common.sh"

# Default snapshot prefix
SNAPSHOT_PREFIX="build-stage"

# Function to create a snapshot with timestamp
create_snapshot() {
    local dataset="$1"
    local stage_name="$2"
    local timestamp=$(date +"%Y%m%d-%H%M%S")
    local snapshot_name="${SNAPSHOT_PREFIX}-${stage_name}-${timestamp}"
    local full_snapshot="${dataset}@${snapshot_name}"
    
    log_info "Creating ZFS snapshot: $full_snapshot"
    
    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY RUN] Would create snapshot: $full_snapshot"
        return 0
    fi
    
    if zfs snapshot "$full_snapshot"; then
        log_info "Successfully created snapshot: $full_snapshot"
        echo "$full_snapshot"
        return 0
    else
        log_error "Failed to create snapshot: $full_snapshot"
        return 1
    fi
}

# Function to list snapshots for a dataset
list_snapshots() {
    local dataset="$1"
    local filter_pattern="${2:-${SNAPSHOT_PREFIX}}"
    
    log_info "Listing snapshots for dataset: $dataset"
    
    if ! zfs list -t snapshot -o name,creation,used -H "$dataset" 2>/dev/null | grep "$filter_pattern" | sort; then
        log_info "No snapshots found matching pattern: $filter_pattern"
        return 0
    fi
}

# Function to rollback to a snapshot
rollback_to_snapshot() {
    local full_snapshot="$1"
    local force="${2:-false}"
    
    log_info "Rolling back to snapshot: $full_snapshot"
    
    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY RUN] Would rollback to: $full_snapshot"
        return 0
    fi
    
    # Validate snapshot exists
    if ! zfs list -t snapshot "$full_snapshot" >/dev/null 2>&1; then
        log_error "Snapshot does not exist: $full_snapshot"
        return 1
    fi
    
    # Perform rollback
    local rollback_cmd="zfs rollback"
    if [[ "$force" == true ]]; then
        rollback_cmd="$rollback_cmd -r"
    fi
    
    if $rollback_cmd "$full_snapshot"; then
        log_info "Successfully rolled back to: $full_snapshot"
        return 0
    else
        log_error "Failed to rollback to: $full_snapshot"
        return 1
    fi
}

# Function to remove old snapshots (keep latest N)
cleanup_old_snapshots() {
    local dataset="$1"
    local stage_name="$2"
    local keep_count="${3:-5}"
    
    log_info "Cleaning up old snapshots for stage: $stage_name (keeping latest $keep_count)"
    
    local pattern="${SNAPSHOT_PREFIX}-${stage_name}"
    local snapshots=($(zfs list -t snapshot -o name -H "$dataset" 2>/dev/null | grep "$pattern" | sort -r))
    
    if [[ ${#snapshots[@]} -le $keep_count ]]; then
        log_info "Only ${#snapshots[@]} snapshots found, no cleanup needed"
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
                log_error "Failed to remove snapshot: $snapshot"
            fi
        fi
    done
}

# Function to show usage
show_usage() {
    cat << EOF
Usage: $0 [OPTIONS] <action> <dataset> [stage_name|snapshot_name]

Manage ZFS snapshots for build stages.

ACTIONS:
    create <dataset> <stage_name>     Create a snapshot for a build stage
    list <dataset> [pattern]          List snapshots (optionally filtered)
    rollback <dataset> <snapshot>     Rollback to a specific snapshot
    cleanup <dataset> <stage_name>    Remove old snapshots (keep latest 5)

OPTIONS:
    --verbose, -v       Enable verbose output
    --dry-run, -n       Show what would be done without executing
    --debug, -d         Enable debug output
    --help, -h          Show this help message

STAGE NAMES:
    base-os            After mmdebstrap base OS installation
    ansible-init       After initial Ansible run
    ansible-complete   After complete Ansible configuration
    pre-boot           Before setting as boot environment

EXAMPLES:
    # Create snapshot after base OS installation
    $0 create zroot/ROOT/plucky base-os

    # List all build-stage snapshots
    $0 list zroot/ROOT/plucky

    # Rollback to base OS state
    $0 rollback zroot/ROOT/plucky zroot/ROOT/plucky@build-stage-base-os-20250723-143022

    # Clean up old snapshots for ansible-init stage
    $0 cleanup zroot/ROOT/plucky ansible-init

EXIT CODES:
    0  Success
    1  Error occurred
    2  Invalid arguments
EOF
}

# Main function
main() {
    local action=""
    local dataset=""
    local stage_or_snapshot=""
    
    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --verbose|-v)
                VERBOSE=true
                shift
                ;;
            --dry-run|-n)
                DRY_RUN=true
                shift
                ;;
            --debug|-d)
                DEBUG=true
                shift
                ;;
            --help|-h)
                show_usage
                exit 0
                ;;
            -*)
                log_error "Unknown option '$1'"
                echo "Use --help for usage information" >&2
                exit 2
                ;;
            *)
                if [[ -z "$action" ]]; then
                    action="$1"
                elif [[ -z "$dataset" ]]; then
                    dataset="$1"
                elif [[ -z "$stage_or_snapshot" ]]; then
                    stage_or_snapshot="$1"
                else
                    log_error "Too many arguments"
                    exit 2
                fi
                shift
                ;;
        esac
    done
    
    # Validate required arguments
    if [[ -z "$action" || -z "$dataset" ]]; then
        log_error "Missing required arguments"
        show_usage
        exit 2
    fi
    
    # Validate dataset exists
    if ! zfs list "$dataset" >/dev/null 2>&1; then
        log_error "Dataset does not exist: $dataset"
        exit 1
    fi
    
    # Execute action
    case "$action" in
        create)
            if [[ -z "$stage_or_snapshot" ]]; then
                log_error "Stage name required for create action"
                exit 2
            fi
            create_snapshot "$dataset" "$stage_or_snapshot"
            ;;
        list)
            list_snapshots "$dataset" "$stage_or_snapshot"
            ;;
        rollback)
            if [[ -z "$stage_or_snapshot" ]]; then
                log_error "Snapshot name required for rollback action"
                exit 2
            fi
            rollback_to_snapshot "$stage_or_snapshot"
            ;;
        cleanup)
            if [[ -z "$stage_or_snapshot" ]]; then
                log_error "Stage name required for cleanup action"
                exit 2
            fi
            cleanup_old_snapshots "$dataset" "$stage_or_snapshot"
            ;;
        *)
            log_error "Unknown action: $action"
            show_usage
            exit 2
            ;;
    esac
}

# Run main function with all arguments
main "$@"
