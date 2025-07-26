#!/bin/bash
#
# Build status management for ZFS build system
#

# --- Script Setup ---
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
lib_dir="$script_dir/../lib"
PROJECT_ROOT="$(dirname "$script_dir")"

# Load global configuration
if [[ -f "$PROJECT_ROOT/config/global.conf" ]]; then
    source "$PROJECT_ROOT/config/global.conf"
fi

# Load libraries we need - this is a core infrastructure script
source "$lib_dir/constants.sh"       # For STATUS_* constants
source "$lib_dir/logging.sh"         # For logging functions
source "$lib_dir/execution.sh"       # For argument parsing
source "$lib_dir/validation.sh"      # For build name validation  
source "$lib_dir/build-status.sh"    # For build_* functions
source "$lib_dir/zfs.sh"             # For ZFS operations (used in clean command)
source "$lib_dir/containers.sh"      # For container operations (used in clean command)

# --- Constants ---
# Constants are now loaded from lib/constants.sh

# Status progression is available via STATUS_PROGRESSION from constants.sh

# --- Functions ---
# Status file and log file path helpers now use library functions

log_build_event() {
    local build_name="$1"
    local message="$2"
    
    # Use the integrated logging system
    local old_context="$BUILD_LOG_CONTEXT"
    build_set_logging_context "$build_name"
    
    # Log to file only (console logging is handled elsewhere)
    log_file_info "$message"
    
    # Restore previous context
    BUILD_LOG_CONTEXT="$old_context"
}

set_status() {
    local status="$1"
    local build_name="$2"
    
    # Use library function instead of manual implementation
    build_set_status "$build_name" "$status"
    
    # Log the status change using integrated logging
    log_status_change "$build_name" "" "$status" false
}

get_status() {
    local build_name="$1"
    # Use library function instead of manual implementation
    build_get_status "$build_name"
}

get_status_timestamp() {
    local build_name="$1"
    # Use library function instead of manual implementation
    build_get_status_timestamp "$build_name"
}

clear_status() {
    local build_name="$1"
    # Use library function instead of manual implementation
    build_clear_status "$build_name"
}

clean_build() {
    local build_name="$1"
    local pool_name="${2:-$DEFAULT_POOL_NAME}"
    
    # Use library function for comprehensive cleanup
    build_clean_all_artifacts "$build_name" "$pool_name"
}

list_builds_with_status() {
    # Use library function instead of manual implementation
    build_list_all_with_status
}

show_build_details() {
    local build_name="$1"
    local pool_name="${2:-$DEFAULT_POOL_NAME}"
    
    # Use library function instead of complex manual implementation
    build_show_details "$build_name" "$pool_name"
}

show_build_history() {
    local build_name="$1"
    
    # Use library function instead of manual implementation
    build_show_history "$build_name"
}

get_next_stage() {
    local current_status="$1"
    # Use library function instead of manual implementation
    build_get_next_stage "$current_status"
}

should_run_stage() {
    local stage="$1"
    local build_name="$2"
    local force_restart="${3:-false}"
    
    # Use library function instead of manual implementation
    build_should_run_stage "$stage" "$build_name" "$force_restart"
}

# --- Usage Information ---
show_usage() {
    cat << EOF
Usage: $0 ACTION [OPTIONS] BUILD_NAME

Manages build status and logs for ZFS build system.
This script focuses on status tracking and integrates information from other manage-* scripts.

ACTIONS:
  set STATUS BUILD_NAME       Set status for a build
  get BUILD_NAME              Get current status for a build
  clean BUILD_NAME [POOL]     Complete cleanup - stop container, destroy datasets, clear status
  list                        List all builds with their status
  show BUILD_NAME [POOL]      Show comprehensive build information (integrates data from other scripts)
  history BUILD_NAME          Show build stage progression and timing history
  log BUILD_NAME MESSAGE      Add a log entry for a build
  next BUILD_NAME             Get next stage that should be run
  should-run STAGE BUILD_NAME Check if a stage should be run

RELATED COMMANDS:
  For direct infrastructure management, use:
  - scripts/manage-root-datasets.sh    (ZFS dataset operations)
  - scripts/manage-root-snapshots.sh   (ZFS snapshot operations) 
  - scripts/manage-root-containers.sh  (Container lifecycle management)

VALID STATUSES:
$(printf "  %s\n" "${VALID_STATUSES[@]}")
  failed

EXAMPLES:
  # Set status
  $0 set datasets-created ubuntu-noble

  # Get current status
  $0 get ubuntu-noble

  # Complete cleanup of a build
  $0 clean ubuntu-noble
  $0 clean ubuntu-noble tank

  # Show detailed build information
  $0 show ubuntu-noble
  $0 show ubuntu-noble tank

  # Show build stage history and timings
  $0 history ubuntu-noble

  # Add log entry
  $0 log ubuntu-noble "Starting custom configuration"

  # Check if stage should run
  $0 should-run os-installed ubuntu-noble

  # List all builds
  $0 list
EOF
    exit 0
}

# --- Main Logic ---
main() {
    if [[ $# -eq 0 ]]; then
        show_usage
    fi

    local action="$1"
    shift

    case "$action" in
        set)
            if [[ $# -ne 2 ]]; then
                die "Usage: $0 set STATUS BUILD_NAME"
            fi
            set_status "$1" "$2"
            ;;
        get)
            if [[ $# -ne 1 ]]; then
                die "Usage: $0 get BUILD_NAME"
            fi
            get_status "$1"
            ;;
        clean)
            if [[ $# -lt 1 ]]; then
                die "Usage: $0 clean BUILD_NAME [POOL]"
            fi
            local pool_name="${2:-$DEFAULT_POOL_NAME}"
            clean_build "$1" "$pool_name"
            ;;
        clear)
            # Internal command - not documented in usage
            if [[ $# -ne 1 ]]; then
                die "Usage: $0 clear BUILD_NAME"
            fi
            clear_status "$1"
            ;;
        list)
            list_builds_with_status
            ;;
        show)
            if [[ $# -lt 1 ]]; then
                die "Usage: $0 show BUILD_NAME [POOL]"
            fi
            local pool_name="${2:-$DEFAULT_POOL_NAME}"
            show_build_details "$1" "$pool_name"
            ;;
        history)
            if [[ $# -ne 1 ]]; then
                die "Usage: $0 history BUILD_NAME"
            fi
            show_build_history "$1"
            ;;
        log)
            if [[ $# -ne 2 ]]; then
                die "Usage: $0 log BUILD_NAME MESSAGE"
            fi
            log_build_event "$1" "$2"
            ;;
        next)
            if [[ $# -ne 1 ]]; then
                die "Usage: $0 next BUILD_NAME"
            fi
            local current_status
            current_status=$(get_status "$1")
            if [[ -n "$current_status" ]]; then
                get_next_stage "$current_status"
            fi
            ;;
        should-run)
            if [[ $# -lt 2 ]]; then
                die "Usage: $0 should-run STAGE BUILD_NAME [force]"
            fi
            local force="${3:-false}"
            if should_run_stage "$1" "$2" "$force"; then
                echo "yes"
                exit 0
            else
                echo "no"
                exit 1
            fi
            ;;
        --help|-h)
            show_usage
            ;;
        *)
            die "Unknown action: $action. Use --help for usage information."
            ;;
    esac
}

# --- Execute Main Function ---
main "$@"
