#!/bin/bash
#
# Manage systemd-nspawn containers for ZFS root datasets
#

# --- Script Setup ---
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
lib_dir="$script_dir/../lib"
PROJECT_ROOT="$(dirname "$script_dir")"

# Load global configuration
if [[ -f "$PROJECT_ROOT/config/global.conf" ]]; then
    source "$PROJECT_ROOT/config/global.conf"
fi

# Load libraries we need
source "$lib_dir/constants.sh"       # For status constants
source "$lib_dir/logging.sh"         # For logging functions
source "$lib_dir/execution.sh"       # For argument parsing and run_cmd
source "$lib_dir/validation.sh"      # For build name validation
source "$lib_dir/dependencies.sh"    # For require_command (systemd-nspawn)
source "$lib_dir/zfs.sh"             # For ZFS operations (mount paths)
source "$lib_dir/containers.sh"      # For container operations (primary functionality)
source "$lib_dir/build-status.sh"    # For build status integration

# --- Script-specific Default values ---
ACTION=""
BUILD_NAME=""
CONTAINER_NAME=""
POOL_NAME="${DEFAULT_POOL_NAME}"
HOSTNAME=""
INSTALL_PACKAGES=""
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

OPTIONS:
  -p, --pool POOL         ZFS pool where the build dataset resides (default: ${DEFAULT_POOL_NAME}).
  -n, --name NAME         Container name (default: BUILD_NAME).
  -h, --hostname HOST     Hostname to set in container (default: BUILD_NAME).
  --install-packages LIST Comma-separated list of packages to install during create.
      --verbose           Enable verbose output.
      --dry-run           Show commands without executing them.
      --debug             Enable detailed debug logging.
  -h, --help              Show this help message.

EXAMPLES:
  # Create container and install Ansible
  $0 create --install-packages ansible,python3-apt ubuntu-noble

  # Start container
  $0 start ubuntu-noble

  # Get shell access
  $0 shell ubuntu-noble

  # Stop and destroy container
  $0 destroy ubuntu-noble

  # List all containers
  $0 list
EOF
    exit 0
}

# --- Argument Parsing ---
parse_args() {
    local remaining_args=()
    
    # First pass: handle common arguments
    parse_common_args remaining_args "$@"
    
    if [[ ${#remaining_args[@]} -eq 0 ]]; then
        show_usage
    fi

    # Check for help first
    if [[ "${remaining_args[0]}" == "--help" || "${remaining_args[0]}" == "-h" ]]; then
        show_usage
    fi

    ACTION="${remaining_args[0]}"
    local args=("${remaining_args[@]:1}")

    local positional_args=()

    while [[ ${#args[@]} -gt 0 ]]; do
        case "${args[0]}" in
            -p|--pool) POOL_NAME="${args[1]}"; args=("${args[@]:2}") ;;
            -n|--name) CONTAINER_NAME="${args[1]}"; args=("${args[@]:2}") ;;
            -h|--hostname) HOSTNAME="${args[1]}"; args=("${args[@]:2}") ;;
            --install-packages) INSTALL_PACKAGES="${args[1]}"; args=("${args[@]:2}") ;;
            --help) show_usage ;;
            -*) die "Unknown option: ${args[0]}" ;;
            *) positional_args+=("${args[0]}"); args=("${args[@]:1}") ;;
        esac
    done

    if [[ "$ACTION" != "list" && "$ACTION" != "exec" ]]; then
        if [[ ${#positional_args[@]} -ne 1 ]]; then
            die "Invalid number of arguments. Expected BUILD_NAME."
        fi
        BUILD_NAME="${positional_args[0]}"
    elif [[ "$ACTION" == "exec" ]]; then
        if [[ ${#positional_args[@]} -lt 2 ]]; then
            die "exec action requires BUILD_NAME and COMMAND arguments."
        fi
        BUILD_NAME="${positional_args[0]}"
        # Build command from remaining positional arguments
        for ((i=1; i<${#positional_args[@]}; i++)); do
            if [[ -n "$EXEC_COMMAND" ]]; then
                EXEC_COMMAND="$EXEC_COMMAND ${positional_args[i]}"
            else
                EXEC_COMMAND="${positional_args[i]}"
            fi
        done
    fi

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
