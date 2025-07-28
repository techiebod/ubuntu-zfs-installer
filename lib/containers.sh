#!/bin/bash
#
# Container Management Library
#
# This library provides standardized systemd-nspawn container operations for the Ubuntu ZFS installer.
# It consolidates container lifecycle management, networking setup, and package installation.

# --- Prevent multiple sourcing ---
if [[ "${__CONTAINER_LIB_LOADED:-}" == "true" ]]; then
    return 0
fi
readonly __CONTAINER_LIB_LOADED="true"

# ==============================================================================
# CONTAINER STATE OPERATIONS
# ==============================================================================

# Check if container is running
# Usage: container_is_running "container-name"
container_is_running() {
    local container_name="$1"
    run_cmd_read machinectl show "$container_name" &>/dev/null
}

# Get container status information
# Usage: container_get_status "container-name"
container_get_status() {
    local container_name="$1"
    
    if ! container_is_running "$container_name"; then
        echo "stopped"
        return 1
    fi
    
    local state
    state=$(run_cmd_read machinectl show "$container_name" --property=State --value 2>/dev/null || echo "unknown")
    echo "$state"
}

# Wait for container to be ready
# Usage: container_wait_for_ready "container-name" [timeout]
container_wait_for_ready() {
    local container_name="$1"
    local timeout="${2:-30}"
    
    log_debug "Waiting for container '$container_name' to be ready..."
    
    local retries=$timeout
    while [ $retries -gt 0 ]; do
        if run_cmd_read machinectl show "$container_name" >/dev/null 2>&1; then
            log_debug "Container '$container_name' is registered with machinectl"
            return 0
        fi
        sleep 1
        retries=$((retries - 1))
    done
    
    log_error "Container '$container_name' failed to register within $timeout seconds"
    return 1
}

# Wait for systemd to be ready inside container
# Usage: container_wait_for_systemd "container-name" [timeout]
container_wait_for_systemd() {
    local container_name="$1"
    local timeout="${2:-60}"
    
    log_debug "Waiting for systemd to be ready in container '$container_name'..."
    
    local retries=$timeout
    while [ $retries -gt 0 ]; do
        if systemd-run --machine="$container_name" --wait /bin/true >/dev/null 2>&1; then
            log_debug "Container systemd is ready"
            return 0
        fi
        sleep 2
        retries=$((retries - 1))
    done
    
    log_warn "Container systemd may not be fully ready after $timeout seconds"
    return 1
}

# ==============================================================================
# CONTAINER VALIDATION
# ==============================================================================

# Validate that a directory looks like a valid rootfs
# Usage: container_validate_rootfs "/path/to/directory"
container_validate_rootfs() {
    local rootfs_path="$1"
    
    # Check if directory exists
    if [[ ! -d "$rootfs_path" ]]; then
        return 1
    fi
    
    # Check for essential rootfs directories/files
    local essential_paths=(
        "$rootfs_path/etc"
        "$rootfs_path/usr"
        "$rootfs_path/bin"
        "$rootfs_path/sbin"
    )
    
    for path in "${essential_paths[@]}"; do
        if [[ ! -e "$path" ]]; then
            log_debug "Missing essential rootfs component: $path"
            return 1
        fi
    done
    
    return 0
}

# ==============================================================================
# CONTAINER LIFECYCLE OPERATIONS
# ==============================================================================

# Create, start, and prepare a container from a ZFS dataset
# Usage: container_create "pool" "build-name" "container-name" [options...]
# This function creates the container, starts it, and installs any specified packages
container_create() {
    local pool_name="$1"
    local build_name="$2"
    local container_name="$3"
    shift 3
    
    # Parse options
    local hostname="$build_name"
    local install_packages=""
    local mount_point=""
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --hostname)
                hostname="$2"
                shift 2
                ;;
            --install-packages)
                install_packages="$2"
                shift 2
                ;;
            --mount-point)
                mount_point="$2"
                shift 2
                ;;
            *)
                log_warn "Unknown option: $1"
                shift
                ;;
        esac
    done
    
    log_info "Creating container '$container_name' for build '$build_name'..."
    
    # Get mount point (assume it follows the standard pattern if not provided)
    if [[ -z "$mount_point" ]]; then
        mount_point="${DEFAULT_MOUNT_BASE}/${build_name}"
    fi
    
    # Validate that the directory looks like a valid rootfs
    if ! container_validate_rootfs "$mount_point"; then
        if [[ "${DRY_RUN:-false}" == "true" ]]; then
            log_warn "Target directory '$mount_point' does not look like a valid rootfs, but continuing with dry-run simulation"
        else
            die "Target directory '$mount_point' does not exist or does not look like a valid rootfs"
        fi
    fi
    
    if container_is_running "$container_name"; then
        if [[ "${DRY_RUN:-false}" == "true" ]]; then
            log_warn "Container '$container_name' is already running, but continuing with dry-run simulation"
        else
            log_info "Container '$container_name' is already running - skipping creation"
            return 0
        fi
    fi
    
    # Copy hostid for ZFS compatibility
    log_debug "Copying hostid '$(hostid)' to container for ZFS compatibility..."
    run_cmd cp /etc/hostid "$mount_point/etc/hostid"
    
    log_info "Container '$container_name' created and prepared"
    
    # Start the container to enable package installation and service configuration
    log_info "Starting container '$container_name' for package installation..."
    if ! container_start "$pool_name" "$build_name" "$container_name" --hostname "$hostname"; then
        die "Failed to start container '$container_name'"
    fi
    
    # Enable networking services using container-based execution (not chroot)
    log_info "Enabling networking services in container using modern container-based approach..."
    if ! container_run_command "$container_name" "
        systemctl enable systemd-networkd
        systemctl enable systemd-resolved
    "; then
        log_warn "Failed to enable networking services in container"
    fi
    
    # Install packages using container-based execution (not chroot)
    if [[ -n "$install_packages" ]]; then
        log_info "Installing packages in container using modern container-based approach: $install_packages"
        container_install_packages_in_running "$container_name" "$install_packages"
    fi
}

# Start a container
# Usage: container_start "pool" "build-name" "container-name" [options...]
container_start() {
    local pool_name="$1"
    local build_name="$2"
    local container_name="$3"
    shift 3
    
    # Parse options
    local hostname="$build_name"
    local mount_point=""
    local capabilities="all"
    local network_config="--network-veth"
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --hostname)
                hostname="$2"
                shift 2
                ;;
            --mount-point)
                mount_point="$2"
                shift 2
                ;;
            --capabilities)
                capabilities="$2"
                shift 2
                ;;
            --network)
                network_config="$2"
                shift 2
                ;;
            *)
                log_warn "Unknown option: $1"
                shift
                ;;
        esac
    done
    
    log_info "Starting container '$container_name'..."
    
    # Get mount point (assume it follows the standard pattern if not provided)
    if [[ -z "$mount_point" ]]; then
        mount_point="${DEFAULT_MOUNT_BASE}/${build_name}"
    fi
    
    # Validate that the directory looks like a valid rootfs
    if ! container_validate_rootfs "$mount_point"; then
        if [[ "${DRY_RUN:-false}" == "true" ]]; then
            log_warn "Target directory '$mount_point' does not look like a valid rootfs, but continuing with dry-run simulation"
        else
            die "Target directory '$mount_point' does not exist or does not look like a valid rootfs"
        fi
    fi
    
    if container_is_running "$container_name"; then
        log_info "Container '$container_name' is already running"
        return 0
    fi
    
    # Build systemd-nspawn command
    local nspawn_cmd=(
        "systemd-nspawn"
        "--directory=$mount_point"
        "--machine=$container_name"
        "--boot"
        "$network_config"
        "--resolv-conf=copy-host"
        "--timezone=auto"
        "--console=passive"
        "--link-journal=try-guest"
        "--hostname=$hostname"
        "--capability=$capabilities"
        "--property=DevicePolicy=auto"
    )
    
    log_debug "Starting container with command: ${nspawn_cmd[*]}"
    
    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY RUN] Would start container: ${nspawn_cmd[*]}"
        return 0
    fi
    
    # Start the container in the background
    "${nspawn_cmd[@]}" &
    local nspawn_pid=$!
    
    # Wait for container to be ready
    if ! container_wait_for_ready "$container_name" 30; then
        # Kill the background process if it's still running
        if kill -0 "$nspawn_pid" 2>/dev/null; then
            kill "$nspawn_pid"
        fi
        return 1
    fi
    
    # Wait for systemd to be ready
    container_wait_for_systemd "$container_name" 60
    
    # Start networking services
    container_start_networking "$container_name"
    
    log_info "Container '$container_name' started successfully (PID: $nspawn_pid)"
}

# Stop a container gracefully
# Usage: container_stop "container-name" [--force]
container_stop() {
    local container_name="$1"
    local force=false
    
    if [[ "${2:-}" == "--force" ]]; then
        force=true
    fi
    
    log_info "Stopping container '$container_name'..."
    
    if ! container_is_running "$container_name"; then
        log_info "Container '$container_name' is not running"
        return 0
    fi
    
    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY RUN] Would stop container: $container_name"
        return 0
    fi
    
    if [[ "$force" == true ]]; then
        # Force terminate immediately
        run_cmd machinectl terminate "$container_name" || true
    else
        # Graceful shutdown
        run_cmd machinectl poweroff "$container_name" || true
        
        # Wait a moment for graceful shutdown
        sleep 3
        
        # Force terminate if still running
        if container_is_running "$container_name"; then
            log_debug "Container still running, forcing termination..."
            run_cmd machinectl terminate "$container_name" || true
        fi
    fi
    
    log_info "Container '$container_name' stopped"
}

# Destroy a container (stop and clean up)
# Usage: container_destroy "container-name"
container_destroy() {
    local container_name="$1"
    
    log_info "Destroying container '$container_name'..."
    
    # Stop if running
    if container_is_running "$container_name"; then
        container_stop "$container_name"
    fi
    
    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY RUN] Would destroy container: $container_name"
        return 0
    fi
    
    # Remove any persistent container state if it exists
    # (systemd-nspawn containers are typically ephemeral, but clean up just in case)
    
    log_info "Container '$container_name' destroyed"
}

# ==============================================================================
# CONTAINER PACKAGE MANAGEMENT
# ==============================================================================

# Install packages in a container chroot (legacy method)
# Usage: container_install_packages "mount-point" "package1,package2,..."
container_install_packages() {
    local mount_point="$1"
    local packages="$2"
    
    log_info "Installing packages in container: $packages"
    
    # Convert comma-separated list to space-separated
    local package_list
    package_list=$(echo "$packages" | tr ',' ' ')
    
    if ! run_cmd chroot "$mount_point" bash -c "
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -q
        apt-get install -y -q $package_list
    "; then
        die "Failed to install packages: $package_list"
    fi
    
    log_debug "Successfully installed packages: $package_list"
}

# Install packages in a running container (modern method)
# Usage: container_install_packages_in_running "container-name" "package1,package2,..."
container_install_packages_in_running() {
    local container_name="$1"
    local packages="$2"
    
    log_info "Installing packages in running container '$container_name': $packages"
    
    # Convert comma-separated list to space-separated
    local package_list
    package_list=$(echo "$packages" | tr ',' ' ')
    
    if ! container_run_command "$container_name" "
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -q
        apt-get install -y -q $package_list
    "; then
        die "Failed to install packages in container: $package_list"
    fi
    
    log_debug "Successfully installed packages in container: $package_list"
}

# ==============================================================================
# CONTAINER NETWORKING
# ==============================================================================

# Set up networking services in container chroot
# Usage: container_setup_networking "mount-point"
container_setup_networking() {
    local mount_point="$1"
    
    log_info "Enabling systemd-networkd and systemd-resolved services..."
    
    if ! run_cmd chroot "$mount_point" bash -c "
        systemctl enable systemd-networkd
        systemctl enable systemd-resolved
    "; then
        log_warn "Failed to enable networking services"
        return 1
    fi
    
    log_debug "Successfully enabled networking services"
}

# Start networking services in running container
# Usage: container_start_networking "container-name"
container_start_networking() {
    local container_name="$1"
    
    log_info "Starting networking services in container..."
    
    # Start networking services (non-fatal if they fail)
    container_run_command "$container_name" "systemctl start systemd-networkd" || \
        log_warn "Failed to start systemd-networkd"
    
    container_run_command "$container_name" "systemctl start systemd-resolved" || \
        log_warn "Failed to start systemd-resolved"
    
    log_debug "Networking services started"
}

# ==============================================================================
# CONTAINER COMMAND EXECUTION
# ==============================================================================

# Execute a command in a running container using systemd-run
# Usage: container_run_command "container-name" "command-string"
container_run_command() {
    local container_name="$1"
    local command="$2"
    
    log_debug "Executing in container '$container_name': $command"
    
    if ! container_is_running "$container_name"; then
        die "Container '$container_name' is not running"
    fi
    
    run_cmd systemd-run --machine="$container_name" --wait bash -c "$command"
}

# Execute a command in a running container (legacy interface for compatibility)
# Usage: container_exec "container-name" "command" [args...]
container_exec() {
    local container_name="$1"
    shift
    local command=("$@")
    
    log_debug "Executing in container '$container_name': ${command[*]}"
    
    if ! container_is_running "$container_name"; then
        die "Container '$container_name' is not running"
    fi
    
    run_cmd systemd-run --machine="$container_name" --wait "${command[@]}"
}

# Open an interactive shell in a running container
# Usage: container_shell "container-name" [shell]
container_shell() {
    local container_name="$1"
    local shell="${2:-/bin/bash}"
    
    log_info "Opening shell in container '$container_name'..."
    
    if ! container_is_running "$container_name"; then
        die "Container '$container_name' is not running"
    fi
    
    log_build_debug "Executing: machinectl shell $container_name $shell"
    
    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY RUN] Would open shell: machinectl shell $container_name $shell"
        return 0
    fi
    
    # Execute directly without run_cmd to preserve terminal interaction
    exec machinectl shell "$container_name" "$shell"
}

# ==============================================================================
# CONTAINER LISTING AND INFORMATION
# ==============================================================================

# List all systemd-nspawn containers
# Usage: container_list_all
container_list_all() {
    log_info "Listing all systemd-nspawn containers..."
    
    if command -v machinectl &>/dev/null; then
        # Use run_cmd_read since this is a read-only operation
        run_cmd_read machinectl list
    else
        log_warn "machinectl not available - cannot list containers"
        return 1
    fi
}

# Show detailed information about a container
# Usage: container_show_info "container-name"
container_show_info() {
    local container_name="$1"
    
    log_info "Container information for: $container_name"
    
    if container_is_running "$container_name"; then
        log_info "Status: Running"
        
        if command -v machinectl &>/dev/null; then
            echo
            log_info "Container Details:"
            run_cmd_read machinectl show "$container_name" 2>/dev/null || log_info "  Details not available"
            
            echo
            log_info "Container Status:"
            run_cmd_read machinectl status "$container_name" 2>/dev/null || log_info "  Status not available"
        fi
    else
        log_info "Status: Stopped"
    fi
}

# ==============================================================================
# CONVENIENCE FUNCTIONS
# ==============================================================================

# Get mount point for a build dataset
# Usage: container_get_mount_point "pool" "build-name"
container_get_mount_point() {
    local pool_name="$1"
    local build_name="$2"
    
    local dataset
    dataset=$(zfs_get_root_dataset_path "$pool_name" "$build_name")
    local mount_point
    mount_point=$(zfs_get_property "$dataset" "mountpoint")
    
    if [[ "$mount_point" == "none" || "$mount_point" == "legacy" ]]; then
        mount_point="${DEFAULT_MOUNT_BASE}/${build_name}"
    fi
    
    echo "$mount_point"
}

# Validate that a dataset exists for container operations
# Usage: container_validate_dataset "pool" "build-name"
container_validate_dataset() {
    local pool_name="$1"
    local build_name="$2"
    
    local dataset
    dataset=$(zfs_get_root_dataset_path "$pool_name" "$build_name")
    if ! zfs_dataset_exists "$dataset"; then
        die "Target dataset '$dataset' does not exist"
    fi
}

# ==============================================================================
# HIGH-LEVEL CONTAINER STATUS OPERATIONS
# ==============================================================================

# Get detailed container status suitable for display
# Returns a user-friendly status message that includes machinectl availability
# Usage: container_get_detailed_status "container-name"
container_get_detailed_status() {
    local container_name="$1"
    
    if ! command -v machinectl &>/dev/null; then
        echo "machinectl not available"
        return 1
    fi
    
    if ! run_cmd_read machinectl show "$container_name" &>/dev/null; then
        echo "not found"
        return 1
    fi
    
    local container_state
    container_state=$(run_cmd_read machinectl show "$container_name" --property=State --value 2>/dev/null || echo "unknown")
    echo "$container_state"
    return 0
}

# Cleanup container for build process - stop and remove if exists
# Usage: container_cleanup_for_build "container-name"
container_cleanup_for_build() {
    local container_name="$1"
    
    if ! command -v machinectl &>/dev/null; then
        log_debug "machinectl not available, skipping container cleanup"
        return 0
    fi
    
    if ! run_cmd_read machinectl show "$container_name" &>/dev/null; then
        log_debug "Container '$container_name' does not exist, no cleanup needed"
        return 0
    fi
    
    log_info "Stopping and removing container: $container_name"
    
    # Stop container (ignore errors)
    run_cmd machinectl stop "$container_name" || true
    
    # Remove container (ignore errors)  
    run_cmd machinectl remove "$container_name" || true
    
    log_debug "Container cleanup completed for: $container_name"
}
