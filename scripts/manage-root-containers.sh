#!/bin/bash
#
# Manage systemd-nspawn containers for ZFS root datasets
#

# --- Script Setup ---
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(dirname "$script_dir")"
# shellcheck source=../lib/common.sh
source "$project_dir/lib/common.sh"

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

get_mount_point() {
    local mount_point
    mount_point=$(zfs get -H -o value mountpoint "${POOL_NAME}/ROOT/${BUILD_NAME}")
    if [[ "$mount_point" == "none" || "$mount_point" == "legacy" ]]; then
        mount_point="${DEFAULT_MOUNT_BASE}/${BUILD_NAME}"
    fi
    echo "$mount_point"
}

check_dataset_exists() {
    local dataset="${POOL_NAME}/ROOT/${BUILD_NAME}"
    if ! zfs list -H -o name "$dataset" &>/dev/null; then
        die "Target dataset '$dataset' does not exist."
    fi
}

is_container_running() {
    local name="$1"
    machinectl show "$name" &>/dev/null
}

create_container() {
    log_info "Creating container '$CONTAINER_NAME' for build '$BUILD_NAME'..."
    
    check_dataset_exists
    local mount_point
    mount_point=$(get_mount_point)
    
    if [[ ! -d "$mount_point" ]]; then
        die "Target mountpoint '$mount_point' does not exist or is not mounted."
    fi

    if is_container_running "$CONTAINER_NAME"; then
        die "Container '$CONTAINER_NAME' is already running."
    fi

    # Copy hostid for ZFS compatibility
    local host_id
    host_id=$(hostid)
    log_debug "Copying hostid '$host_id' to container for ZFS compatibility..."
    run_cmd cp /etc/hostid "$mount_point/etc/hostid" || {
        log_debug "Creating hostid file in container..."
        run_cmd bash -c "echo '$host_id' > '$mount_point/etc/hostid'"
    }

    # Install packages if requested
    if [[ -n "$INSTALL_PACKAGES" ]]; then
        log_info "Installing packages in container: $INSTALL_PACKAGES"
        
        # Convert comma-separated list to space-separated
        local packages
        packages=$(echo "$INSTALL_PACKAGES" | tr ',' ' ')
        
        run_cmd chroot "$mount_point" bash -c "
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -q
            apt-get install -y -q $packages
        "
    fi

    # Enable networking services for proper container networking
    log_info "Enabling systemd-networkd and systemd-resolved services..."
    run_cmd chroot "$mount_point" bash -c "
        systemctl enable systemd-networkd
        systemctl enable systemd-resolved
    "

    log_info "Container '$CONTAINER_NAME' created and prepared."
}

start_container() {
    log_info "Starting container '$CONTAINER_NAME'..."
    
    check_dataset_exists
    local mount_point
    mount_point=$(get_mount_point)

    if is_container_running "$CONTAINER_NAME"; then
        log_info "Container '$CONTAINER_NAME' is already running."
        return 0
    fi

    # Start the container - systemd-nspawn with --boot runs as a daemon
    local nspawn_cmd=(
        "systemd-nspawn"
        "--directory=$mount_point"
        "--machine=$CONTAINER_NAME"
        "--boot"
        "--network-veth"
        "--resolv-conf=copy-host"
        "--timezone=auto"
        "--console=passive"
        "--link-journal=try-guest"
        "--hostname=$HOSTNAME"
        "--capability=all"
        "--property=DevicePolicy=auto"
    )
    
    log_debug "Starting container with command: ${nspawn_cmd[*]}"
    
    # Start the container in the background
    "${nspawn_cmd[@]}" &
    local nspawn_pid=$!
    
    # Wait for the machine to be registered with systemd-machined
    log_info "Waiting for container to be ready..."
    local retries=30
    while [ $retries -gt 0 ]; do
        if machinectl show "$CONTAINER_NAME" >/dev/null 2>&1; then
            log_debug "Container '$CONTAINER_NAME' is registered with machinectl"
            break
        fi
        sleep 1
        retries=$((retries - 1))
    done
    
    if [ $retries -eq 0 ]; then
        log_error "Container '$CONTAINER_NAME' failed to register within timeout"
        # Kill the background process if it's still running
        if kill -0 "$nspawn_pid" 2>/dev/null; then
            kill "$nspawn_pid"
        fi
        return 1
    fi
    
    # Wait for systemd to be fully ready inside the container
    log_info "Waiting for systemd to be fully ready in container..."
    retries=60
    while [ $retries -gt 0 ]; do
        if systemd-run --machine="$CONTAINER_NAME" --wait /bin/true >/dev/null 2>&1; then
            log_debug "Container systemd is ready"
            break
        fi
        sleep 2
        retries=$((retries - 1))
    done
    
    if [ $retries -eq 0 ]; then
        log_warn "Container systemd may not be fully ready, but proceeding anyway"
    fi

    # Start networking services in the container
    log_info "Starting networking services in container..."
    systemd-run --machine="$CONTAINER_NAME" --wait systemctl start systemd-networkd || log_warn "Failed to start systemd-networkd"
    systemd-run --machine="$CONTAINER_NAME" --wait systemctl start systemd-resolved || log_warn "Failed to start systemd-resolved"
    
    log_info "Container '$CONTAINER_NAME' started successfully (PID: $nspawn_pid)."
}

stop_container() {
    log_info "Stopping container '$CONTAINER_NAME'..."
    
    if ! is_container_running "$CONTAINER_NAME"; then
        log_info "Container '$CONTAINER_NAME' is not running."
        return 0
    fi

    # Graceful shutdown
    run_cmd machinectl poweroff "$CONTAINER_NAME" || true
    
    # Wait a moment for graceful shutdown
    sleep 3
    
    # Force terminate if still running
    if is_container_running "$CONTAINER_NAME"; then
        log_debug "Container still running, forcing termination..."
        run_cmd machinectl terminate "$CONTAINER_NAME" || true
    fi
    
    log_info "Container '$CONTAINER_NAME' stopped."
}

destroy_container() {
    log_info "Destroying container '$CONTAINER_NAME'..."
    
    # Stop if running
    if is_container_running "$CONTAINER_NAME"; then
        stop_container
    fi
    
    # Remove any persistent container state if it exists
    # (systemd-nspawn containers are typically ephemeral, but clean up just in case)
    
    log_info "Container '$CONTAINER_NAME' destroyed."
}

list_containers() {
    log_info "Listing all systemd-nspawn containers..."
    
    if command -v machinectl >/dev/null; then
        # For listing, we want to see the output even on success
        machinectl list
    else
        log_error "machinectl not available - cannot list containers."
        return 1
    fi
}

shell_container() {
    log_info "Opening shell in container '$CONTAINER_NAME'..."
    
    if ! is_container_running "$CONTAINER_NAME"; then
        die "Container '$CONTAINER_NAME' is not running. Start it first with: $0 start $BUILD_NAME"
    fi
    
    # Open interactive shell - use exec to replace this process
    # This should completely replace the current process, preventing any further execution
    exec machinectl shell "$CONTAINER_NAME"
}

exec_container() {
    local command="$1"
    log_info "Executing command in container '$CONTAINER_NAME': $command"
    
    if ! is_container_running "$CONTAINER_NAME"; then
        die "Container '$CONTAINER_NAME' is not running. Start it first with: $0 start $BUILD_NAME"
    fi
    
    # Execute command in container using systemd-run
    run_cmd systemd-run --machine="$CONTAINER_NAME" --wait /bin/bash -c "$command"
}

# --- Prerequisite Checks ---
check_prerequisites() {
    # Check for required system commands
    require_command "systemd-nspawn" "systemd-nspawn is required to manage containers."
    require_command "machinectl" "machinectl is required to manage containers."

    if [[ "$ACTION" != "list" ]]; then
        check_zfs_pool "$POOL_NAME"
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
