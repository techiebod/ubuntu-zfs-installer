#!/bin/bash
#
# Build status management for ZFS build system
#

# --- Script Setup ---
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
lib_dir="$script_dir/../lib"

# Load the core library which sets up essential project structure and variables
source "$lib_dir/core.sh"

# Load libraries we need - this is a core infrastructure script
source "$lib_dir/logging.sh"         # For logging functions
source "$lib_dir/execution.sh"       # For argument parsing
source "$lib_dir/validation.sh"      # For build name validation  
source "$lib_dir/build-status.sh"    # For build_* functions
source "$lib_dir/zfs.sh"             # For ZFS operations (used in clean command)
source "$lib_dir/containers.sh"      # For container operations (used in clean command)
source "$lib_dir/flag-helpers.sh"    # For common flag definitions

# Load shflags library
source "$lib_dir/vendor/shflags"

# --- Flag definitions ---
DEFINE_string 'pool' "${DEFAULT_POOL_NAME}" 'The ZFS pool to operate on' 'p'
define_common_flags  # Add standard dry-run and debug flags

# --- Constants ---
# Constants are now loaded from lib/constants.sh

# Status progression is available via STATUS_PROGRESSION from constants.sh

# --- Functions ---
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

# --- Usage Information ---
show_usage() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS] ACTION [ARGUMENTS]

Manages build status and logs for ZFS build system.
This script focuses on status tracking and integrates information from other manage-* scripts.

ACTIONS:
  set STATUS BUILD_NAME       Set status for a build
  get BUILD_NAME              Get current status for a build
  clean BUILD_NAME            Complete cleanup - stop container, destroy datasets, clear status
  list                        List all builds with their status
  show BUILD_NAME             Show comprehensive build information (integrates data from other scripts)
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

EOF
    flags_help
    cat << EOF

EXAMPLES:
  # Set status
  $(basename "$0") set datasets-created ubuntu-noble

  # Get current status
  $(basename "$0") get ubuntu-noble

  # Complete cleanup of a build
  $(basename "$0") clean ubuntu-noble
  $(basename "$0") --pool tank clean ubuntu-noble

  # Show detailed build information
  $(basename "$0") show ubuntu-noble
  $(basename "$0") --pool tank show ubuntu-noble

  # Show build stage history and timings
  $(basename "$0") history ubuntu-noble

  # Add log entry
  $(basename "$0") log ubuntu-noble "Starting custom configuration"

  # Check if stage should run
  $(basename "$0") should-run os-installed ubuntu-noble

  # List all builds
  $(basename "$0") list
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

# --- Main Logic ---
main() {
    # Parse arguments first
    parse_arguments "$@"
    eval set -- "${FLAGS_ARGV}"
    
    # Disable timestamps for cleaner output in interactive mode
    if is_interactive_mode; then
        # shellcheck disable=SC2034  # Used by logging system
        LOG_WITH_TIMESTAMPS=false
    fi
    
    if [[ $# -eq 0 ]]; then
        echo "Usage: $(basename "$0") [OPTIONS] ACTION [ARGUMENTS]"
        echo ""
        echo "ACTIONS: set, get, clean, list, show, history, log, next, should-run"
        echo "Run '$(basename "$0") --help' for detailed usage and flag options"
        echo ""
        echo "Examples:"
        echo "  $(basename "$0") set datasets-created ubuntu-noble"
        echo "  $(basename "$0") get ubuntu-noble"
        echo "  $(basename "$0") list"
        exit 1
    fi

    local action="$1"
    shift

    case "$action" in
        set)
            if [[ $# -ne 2 ]]; then
                die "Usage: $(basename "$0") set STATUS BUILD_NAME"
            fi
            build_set_status "$2" "$1"
            log_status_change "$2" "" "$1" false
            ;;
        get)
            if [[ $# -ne 1 ]]; then
                die "Usage: $(basename "$0") get BUILD_NAME"
            fi
            build_get_status "$1"
            ;;
        clean)
            if [[ $# -lt 1 ]]; then
                die "Usage: $(basename "$0") clean BUILD_NAME"
            fi
            build_clean_artifacts "$1" "$POOL_NAME"
            ;;
        clear)
            # Internal command - not documented in usage
            if [[ $# -ne 1 ]]; then
                die "Usage: $(basename "$0") clear BUILD_NAME"
            fi
            build_clear_status "$1"
            ;;
        list)
            build_list_all_with_status
            ;;
        show)
            if [[ $# -lt 1 ]]; then
                die "Usage: $(basename "$0") show BUILD_NAME"
            fi
            build_show_details "$1" "$POOL_NAME"
            ;;
        history)
            if [[ $# -ne 1 ]]; then
                die "Usage: $(basename "$0") history BUILD_NAME"
            fi
            build_show_history "$1"
            ;;
        log)
            if [[ $# -ne 2 ]]; then
                die "Usage: $(basename "$0") log BUILD_NAME MESSAGE"
            fi
            log_build_event "$1" "$2"
            ;;
        next)
            if [[ $# -ne 1 ]]; then
                die "Usage: $(basename "$0") next BUILD_NAME"
            fi
            local current_status
            current_status=$(build_get_status "$1")
            if [[ -n "$current_status" ]]; then
                build_get_next_stage "$current_status"
            fi
            ;;
        should-run)
            if [[ $# -lt 2 ]]; then
                die "Usage: $(basename "$0") should-run STAGE BUILD_NAME [force]"
            fi
            local force="${3:-false}"
            if build_should_run_stage "$1" "$2" "$force"; then
                echo "yes"
                exit 0
            else
                echo "no"
                exit 1
            fi
            ;;
        *)
            die "Unknown action: $action. Use --help for usage information."
            ;;
    esac
}

# --- Execute Main Function ---
main "$@"
