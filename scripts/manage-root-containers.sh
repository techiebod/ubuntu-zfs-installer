#!/bin/bash
#
# Manage systemd-nspawn containers for ZFS root datasets
#

# --- Script Setup ---
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
lib_dir="$script_dir/../lib"

# Load the core library which sets up essential project structure and variables
source "$lib_dir/core.sh"

# Load libraries we need
source "$lib_dir/logging.sh"         # For logging functions
source "$lib_dir/execution.sh"       # For argument parsing and run_cmd
source "$lib_dir/validation.sh"      # For build name validation
source "$lib_dir/dependencies.sh"    # For require_command (systemd-nspawn)
source "$lib_dir/zfs.sh"             # For ZFS operations (mount paths)
source "$lib_dir/containers.sh"      # For container operations (primary functionality)
source "$lib_dir/build-status.sh"    # For build status integration
source "$lib_dir/flag-helpers.sh"    # For common flag definitions

# Load shflags library for standardized argument parsing
source "$lib_dir/vendor/shflags"

# --- Flag Definitions ---
# Define all command-line flags with defaults and descriptions
DEFINE_string 'pool' "${DEFAULT_POOL_NAME}" 'ZFS pool where the build dataset resides' 'p'
DEFINE_string 'name' '' 'Container name (default: BUILD_NAME)' 'n'
DEFINE_string 'hostname' '' 'Hostname to set in container (default: BUILD_NAME)'
DEFINE_string 'install_packages' '' 'Comma-separated list of packages to install during create'
define_common_flags  # Add standard dry-run and debug flags

# --- Script-specific Variables ---
ACTION=""
BUILD_NAME=""
EXEC_COMMAND=""

# --- Usage Information ---
show_usage() {
    cat << EOF
Usage: $0 ACTION [OPTIONS] BUILD_NAME

Manages systemd-nspawn containers for ZFS root datasets.

ACTIONS:
  create                  Create and prepare a container (installs base packages)
  start                   Start an existing container
  stop                    Stop a running container
  destroy                 Stop and remove a container
  list                    List all managed containers
  shell                   Open a shell in a running container
  exec COMMAND            Execute a command in a running container

ARGUMENTS:
  BUILD_NAME              The name of the build/dataset (e.g., ubuntu-noble).

EOF
    echo "OPTIONS:"
    flags_help
    cat << EOF

EXAMPLES:
  # Create container and install Ansible
  $0 create --install_packages ansible,python3-apt ubuntu-noble

  # Start container
  $0 start ubuntu-noble

  # Get shell access
  $0 shell ubuntu-noble

  # Stop and destroy container
  $0 destroy ubuntu-noble

  # List all containers
  $0 list
EOF
}

# --- Argument Parsing ---
parse_args() {
    # Parse flags and return non-flag arguments
    FLAGS "$@" || exit 1
    eval set -- "${FLAGS_ARGV}"
    
    # Process positional arguments
    if [[ $# -eq 0 ]]; then
        log_error "No action specified."
        echo ""
        show_usage
        exit 1
    fi

    ACTION="$1"
    shift

    # Validate action and handle arguments based on action type
    case "$ACTION" in
        list)
            if [[ $# -ne 0 ]]; then
                log_error "Action 'list' takes no additional arguments."
                echo ""
                show_usage
                exit 1
            fi
            ;;
        exec)
            if [[ $# -lt 2 ]]; then
                log_error "Action 'exec' requires BUILD_NAME and COMMAND arguments."
                echo ""
                show_usage
                exit 1
            fi
            BUILD_NAME="$1"
            shift
            # Remaining arguments form the command
            EXEC_COMMAND="$*"
            ;;
        create|start|stop|destroy|shell)
            if [[ $# -ne 1 ]]; then
                log_error "Action '$ACTION' requires exactly one BUILD_NAME argument."
                echo ""
                show_usage
                exit 1
            fi
            BUILD_NAME="$1"
            ;;
        *)
            log_error "Unknown action: $ACTION"
            echo ""
            show_usage
            exit 1
            ;;
    esac
    
    # Set global variables from flags for compatibility with existing code
    POOL_NAME="${FLAGS_pool}"
    CONTAINER_NAME="${FLAGS_name}"
    HOSTNAME="${FLAGS_hostname}"
    INSTALL_PACKAGES="${FLAGS_install_packages}"
    # Process common flags (dry-run and debug)
    process_common_flags
    
    # Set defaults
    if [[ -z "$CONTAINER_NAME" ]]; then
        CONTAINER_NAME="$BUILD_NAME"
    fi
    if [[ -z "$HOSTNAME" ]]; then
        HOSTNAME="$BUILD_NAME"
    fi
}

# --- Container Management Functions ---

# Helper functions now use container library
get_mount_point() {
    container_get_mount_point "$POOL_NAME" "$BUILD_NAME"
}

check_dataset_exists() {
    container_validate_dataset "$POOL_NAME" "$BUILD_NAME"
}

is_container_running() {
    local name="$1"
    container_is_running "$name"
}

create_container() {
    # Use library function with options
    local options=()
    [[ -n "$HOSTNAME" ]] && options+=(--hostname "$HOSTNAME")
    [[ -n "$INSTALL_PACKAGES" ]] && options+=(--install-packages "$INSTALL_PACKAGES")
    
    container_create "$POOL_NAME" "$BUILD_NAME" "$CONTAINER_NAME" "${options[@]}"
}

start_container() {
    # Use library function with options
    local options=()
    [[ -n "$HOSTNAME" ]] && options+=(--hostname "$HOSTNAME")
    
    container_start "$POOL_NAME" "$BUILD_NAME" "$CONTAINER_NAME" "${options[@]}"
}

stop_container() {
    container_stop "$CONTAINER_NAME"
}

destroy_container() {
    container_destroy "$CONTAINER_NAME"
}

list_containers() {
    container_list_all
}

shell_container() {
    container_shell "$CONTAINER_NAME"
}

exec_container() {
    local command="$1"
    container_exec "$CONTAINER_NAME" /bin/bash -c "$command"
}

# --- Prerequisite Checks ---
check_prerequisites() {
    # Check for required system commands
    require_command "systemd-nspawn"
    require_command "machinectl"

    if [[ "$ACTION" != "list" ]]; then
        zfs_check_pool "$POOL_NAME"
    fi
}

# --- Main Logic ---
main() {
    parse_args "$@"
    
    # Disable timestamps for cleaner output in interactive mode
    if is_interactive_mode; then
        # shellcheck disable=SC2034  # Used by logging system
        LOG_WITH_TIMESTAMPS=false
    fi
    
    check_prerequisites

    case "$ACTION" in
        create)
            create_container
            ;;
        start)
            start_container
            ;;
        stop)
            stop_container
            ;;
        destroy)
            destroy_container
            ;;
        list)
            list_containers
            ;;
        shell)
            shell_container
            ;;
        exec)
            exec_container "$EXEC_COMMAND"
            ;;
        *)
            die "Unknown action: $ACTION. Use --help for usage information."
            ;;
    esac
}

# --- Execute Main Function ---
# Handle shell action outside of subshell to avoid exec issues
if [[ "${1:-}" == "shell" ]]; then
    # Parse arguments and run shell directly to avoid subshell exec issues
    parse_args "$@"
    check_prerequisites
    shell_container
else
    # Run other actions in subshell for proper error handling
    (
        main "$@"
    )
fi
