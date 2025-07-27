#!/bin/bash
#
# Multi-Distribution ZFS Root Builder - Orchestrates the complete build process
#
# This script serves as the main entry point for creating a new ZFS-based
# root filesystem. It calls other specialized scripts to handle each stage
# of the process, from dataset creation to system configuration.

# --- Script Setup ---
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
lib_dir="$script_dir/../lib"

# Load the core library which sets up essential project structure and variables
source "$lib_dir/core.sh"

# Load libraries we need
source "$lib_dir/logging.sh"         # For logging functions
source "$lib_dir/execution.sh"       # For argument parsing and run_cmd
source "$lib_dir/validation.sh"      # For input validation
source "$lib_dir/dependencies.sh"    # For require_command
source "$lib_dir/recovery.sh"        # For cleanup management
source "$lib_dir/ubuntu-api.sh"      # For version resolution
source "$lib_dir/zfs.sh"             # For ZFS dataset paths
source "$lib_dir/containers.sh"      # For container operations
source "$lib_dir/build-status.sh"    # For build status management

# Load shflags library for standardized argument parsing
source "$lib_dir/vendor/shflags"

# --- Flag Definitions ---
# Define all command-line flags with defaults and descriptions
DEFINE_string 'distribution' "${DEFAULT_DISTRIBUTION}" 'Distribution to build (e.g., ubuntu, debian)' 'd'
DEFINE_string 'version' '' 'Distribution version (e.g., 25.04, 12)' 'v'
DEFINE_string 'codename' '' 'Distribution codename (e.g., noble, bookworm)' 'c'
DEFINE_string 'arch' "${DEFAULT_ARCH}" 'Target architecture' 'a'
DEFINE_string 'pool' "${DEFAULT_POOL_NAME}" 'ZFS pool to use' 'p'
DEFINE_string 'profile' "${DEFAULT_INSTALL_PROFILE:-minimal}" 'Package installation profile (minimal, standard, full)'
DEFINE_string 'tags' '' 'Comma-separated list of Ansible tags to run' 't'
DEFINE_string 'limit' '' 'Ansible limit pattern (default: HOSTNAME)' 'l'
DEFINE_boolean 'snapshots' true 'Create ZFS snapshots after major build stages'
DEFINE_boolean 'restart' false 'Force restart from beginning, ignoring existing build status'
DEFINE_boolean 'verbose' false 'Enable verbose output, showing all command outputs'
DEFINE_boolean 'dry-run' false 'Show all commands that would be run without executing them'
DEFINE_boolean 'debug' false 'Enable detailed debug logging'

# --- Script-specific Variables ---
# These will be set based on positional arguments
BUILD_NAME=""
HOSTNAME=""

# --- Usage Information ---
show_usage() {
    cat << EOF
Usage: $0 [OPTIONS] BUILD_NAME HOSTNAME

Orchestrates the entire process of building a new ZFS root filesystem.
It handles ZFS dataset creation, base OS installation, and Ansible configuration.

ARGUMENTS:
  BUILD_NAME              A unique name for this build (e.g., ubuntu-25.04, server-build).
  HOSTNAME                The target hostname. A corresponding Ansible host_vars file
                          (config/host_vars/HOSTNAME.yml) must exist.

EOF
    echo "OPTIONS:"
    flags_help
    cat << EOF

EXAMPLES:
  # Build an Ubuntu 24.04 system for host 'blackbox'
  $0 --version 24.04 ubuntu-noble blackbox

  # Build an Ubuntu server with standard packages (ubuntu-server equivalent)
  $0 --version 24.04 --profile standard ubuntu-server blackbox

  # Build a Debian 12 system, cleaning up any previous build with the same name
  $0 --distribution debian --version 12 debian-bookworm my-server

  # Perform a dry run to see all the steps for a new build
  $0 --dry_run --codename noble ubuntu-test test-host

REQUIREMENTS:
  - Docker must be installed and running for the OS installation stage.
  - The target ZFS pool must exist.
  - An Ansible host variables file must exist at 'config/host_vars/HOSTNAME.yml'.
EOF
}

# --- Argument Parsing ---
parse_args() {
    # Parse flags and return non-flag arguments
    FLAGS "$@" || exit 1
    eval set -- "${FLAGS_ARGV}"
    
    # Process positional arguments
    if [[ $# -lt 2 ]]; then
        log_error "Missing required arguments BUILD_NAME and HOSTNAME"
        echo ""
        show_usage
        exit 1
    fi
    
    BUILD_NAME="$1"
    HOSTNAME="$2"
    
    # Check for extra arguments
    if [[ $# -gt 2 ]]; then
        log_error "Too many arguments. Expected BUILD_NAME and HOSTNAME."
        echo ""
        show_usage
        exit 1
    fi
    
    # Set global variables from flags for compatibility with existing code
    DISTRIBUTION="${FLAGS_distribution}"
    VERSION="${FLAGS_version}"
    CODENAME="${FLAGS_codename}"
    ARCH="${FLAGS_arch}"
    POOL_NAME="${FLAGS_pool}"
    INSTALL_PROFILE="${FLAGS_profile}"
    ANSIBLE_TAGS="${FLAGS_tags}"
    ANSIBLE_LIMIT="${FLAGS_limit}"
    # Convert shflags boolean values (0=true, 1=false) to traditional bash boolean
    CREATE_SNAPSHOTS=$([ "${FLAGS_snapshots}" -eq 0 ] && echo "true" || echo "false")
    FORCE_RESTART=$([ "${FLAGS_restart}" -eq 0 ] && echo "true" || echo "false")
    # Update global environment variables (exported by lib/core.sh)
    VERBOSE=$([ "${FLAGS_verbose}" -eq 0 ] && echo "true" || echo "false")
    export VERBOSE
    # shellcheck disable=SC2154  # FLAGS_dry_run is set by shflags
    DRY_RUN=$([ "${FLAGS_dry_run}" -eq 0 ] && echo "true" || echo "false")
    export DRY_RUN
    DEBUG=$([ "${FLAGS_debug}" -eq 0 ] && echo "true" || echo "false")
    export DEBUG
}

# --- Prerequisite Checks ---
check_prerequisites() {
    log_debug "Starting prerequisite validation"

    # Validate input arguments (BUILD_NAME and HOSTNAME are already checked in parse_args)
    validate_build_name "$BUILD_NAME" "build name"
    validate_hostname "$HOSTNAME"
    validate_architecture "$ARCH"
    validate_distribution "$DISTRIBUTION"
    
    if [[ -n "$INSTALL_PROFILE" ]]; then
        validate_install_profile "$INSTALL_PROFILE"
    fi

    # Validate global configuration (includes external dependencies)
    validate_global_config

    # Check for required system commands with install hints
    require_command "docker"
    require_command "systemd-nspawn"
    
    # Check host variables file exists
    local host_vars_file="$PROJECT_ROOT/config/host_vars/${HOSTNAME}.yml"
    if [[ ! -f "$host_vars_file" ]]; then
        die_with_context \
            "Host variables file not found: $host_vars_file" \
            "Create the file with: cp examples/host_vars/ubuntu-minimal.yml config/host_vars/${HOSTNAME}.yml"
    fi

    log_debug "Prerequisite validation completed"
}

# --- Helper to create snapshots ---
take_snapshot() {
    local stage="$1"
    if [[ "$CREATE_SNAPSHOTS" -ne 0 ]]; then
        return 0
    fi

    log_info "Creating snapshot for stage: $stage"
    invoke_script "manage-root-snapshots.sh" "--pool" "$POOL_NAME" "create" "$BUILD_NAME" "$stage"
}

# --- Helper to manage build status ---
set_build_status() {
    local status="$1"
    log_debug "Setting build status to: $status"
    run_cmd "$script_dir/manage-build-status.sh" set "$status" "$BUILD_NAME"
}

check_build_status() {
    "$script_dir/manage-build-status.sh" get "$BUILD_NAME" 2>/dev/null || echo ""
}

should_run_stage() {
    local stage="$1"
    "$script_dir/manage-build-status.sh" should-run "$stage" "$BUILD_NAME" "$FORCE_RESTART" >/dev/null 2>&1
}

clear_build_status() {
    run_cmd "$script_dir/manage-build-status.sh" clear "$BUILD_NAME"
}

# --- Main Build Logic ---
main() {
    parse_args "$@"
    
    # Disable timestamps for cleaner output in interactive mode
    if is_interactive_mode; then
        # shellcheck disable=SC2034  # Used by logging system
        LOG_WITH_TIMESTAMPS=false
    fi
    
    # Set up cleanup handling only after confirming we're doing actual work
    # (not just showing help or validating arguments)
    setup_cleanup_trap
    
    check_prerequisites

    # Define container name used throughout the build process
    container_name="${BUILD_NAME}"

    # Set up build-specific logging context
    set_build_log_context "$BUILD_NAME"

    # Add cleanup for container if created
    add_cleanup "cleanup_container"

    # Resolve distribution version and codename
    resolve_dist_info "$DISTRIBUTION" "$VERSION" "$CODENAME"

    # Set Ansible limit if not provided
    if [[ -z "$ANSIBLE_LIMIT" ]]; then
        ANSIBLE_LIMIT="$HOSTNAME"
    fi

    log_operation_start "ZFS root build for '$BUILD_NAME'"
    log_info "Build settings:"
    log_info "  🏗️  Build Name:     $BUILD_NAME"
    log_info "  🖥️  Target Host:    $HOSTNAME"
    log_info "  💾 ZFS Pool:       $POOL_NAME"
    log_info "  🐧 Distribution:   $DISTRIBUTION"
    log_info "  📊 Version:        $DIST_VERSION"
    log_info "  📋 Codename:       $DIST_CODENAME"
    log_info "  🏗️  Architecture:   $ARCH"
    log_info "  🎯 Ansible Tags:   ${ANSIBLE_TAGS:-'(none)'}"
    log_info "  🎭 Ansible Limit:  $ANSIBLE_LIMIT"
    log_info "  📸 Snapshots:      $([ "$CREATE_SNAPSHOTS" -eq 0 ] && echo "true" || echo "false")"
    log_info "  🔄 Force Restart:  $([ "$FORCE_RESTART" -eq 0 ] && echo "true" || echo "false")"
    log_info "  🧪 Dry Run:        $([ "$DRY_RUN" -eq 0 ] && echo "true" || echo "false")"

    # Log build start (this goes to both console and file)
    log_build_event "Build initiated: $DISTRIBUTION $DIST_VERSION ($ARCH) → hostname '$HOSTNAME' on pool '$POOL_NAME'"

    # Check current build status
    local current_status
    current_status=$(check_build_status)
    if [[ -n "$current_status" ]]; then
        log_info "Current build status: $current_status"
        if [[ "$FORCE_RESTART" -eq 0 ]]; then
            log_info "Force restart requested - clearing build status"
            clear_build_status
            current_status=""
        fi
    fi

    # Set initial status
    if [[ -z "$current_status" ]]; then
        set_build_status "started"
    fi

    # --- STAGE 1: Create ZFS Datasets ---
    if should_run_stage "datasets-created"; then
        log_step 1 6 "Creating ZFS root dataset"
        log_build_event "Starting Stage 1: Creating ZFS datasets for distribution $DISTRIBUTION $DIST_VERSION"
        
        invoke_script "manage-root-datasets.sh" "--pool" "$POOL_NAME" "create" "$BUILD_NAME"
        
        set_build_status "datasets-created"
        log_build_event "Completed Stage 1: ZFS datasets created successfully"
        take_snapshot "1-datasets-created"
    else
        log_info "📋 Step 1/6: ZFS dataset creation (already completed)"
    fi

    # --- STAGE 2: Install Base OS ---
    if should_run_stage "os-installed"; then
        log_step 2 6 "Installing base operating system"
        log_build_event "Starting Stage 2: Installing $DISTRIBUTION $DIST_VERSION base OS on $ARCH architecture"
        
        # If we're rerunning Stage 2 (i.e., datasets already exist but OS install failed),
        # roll back to the clean state from Stage 1 to ensure a fresh start
        local current_status
        current_status=$(check_build_status)
        if [[ "$current_status" == "datasets-created" ]]; then
            log_build_warn "Rolling back to clean state before OS installation"
            invoke_script "manage-root-snapshots.sh" "--pool" "$POOL_NAME" "rollback" "$BUILD_NAME" "build-stage-1-datasets-created"
            
            if [[ $? -eq 0 ]]; then
                log_build_info "Successfully rolled back to stage 1 snapshot"
            else
                log_build_warn "Failed to rollback to stage 1 snapshot, proceeding with current state"
            fi
        fi
        
        local os_install_args=(
            "--pool" "$POOL_NAME"
            "--arch" "$ARCH"
            "--distribution" "$DISTRIBUTION"
            "--version" "$DIST_VERSION"
            "--codename" "$DIST_CODENAME"
            "$BUILD_NAME"
        )
        [[ -n "$INSTALL_PROFILE" ]] && os_install_args+=("--profile" "$INSTALL_PROFILE")
        add_common_flags os_install_args

        run_cmd "$script_dir/install-root-os.sh" "${os_install_args[@]}"
        set_build_status "os-installed"
        log_build_event "Completed Stage 2: Base OS installation finished successfully"
        take_snapshot "2-os-installed"
    else
        log_info "Stage 2: Skipping base OS installation (already completed)"
    fi

    # --- STAGE 3: Mount Varlog Dataset ---
    if should_run_stage "varlog-mounted"; then
        log_info "Stage 3: Mounting varlog dataset..."
        log_build_event "Starting Stage 3: Mounting varlog dataset for persistent logging"
        
        invoke_script "manage-root-datasets.sh" "--pool" "$POOL_NAME" "mount-varlog" "$BUILD_NAME"
        
        set_build_status "varlog-mounted"
        log_build_event "Completed Stage 3: Varlog dataset mounted successfully"
        take_snapshot "3-varlog-mounted"
    else
        log_info "Stage 3: Skipping varlog mount (already completed)"
    fi

    # --- STAGE 4: Create and Prepare Container ---
    if should_run_stage "container-created"; then
        log_info "Stage 4: Creating container for Ansible execution..."
        log_build_event "Starting Stage 4: Creating systemd-nspawn container '$HOSTNAME' for configuration"
        
        invoke_script "manage-root-containers.sh" "create" "--pool" "$POOL_NAME" "--name" "$container_name" "--hostname" "$HOSTNAME" "--install-packages" "ansible,python3-apt" "$BUILD_NAME"
        
        # Start the container
        invoke_script "manage-root-containers.sh" "start" "--name" "$container_name" "$BUILD_NAME"
        
        set_build_status "container-created"
        log_build_event "Completed Stage 4: Container created and started successfully"
        take_snapshot "4-container-created"
    else
        log_info "Stage 4: Skipping container creation (already completed)"
    fi

    # Set up container cleanup on script exit
    cleanup_container() {
        log_info "Cleaning up container: $container_name"
        "$script_dir/manage-root-containers.sh" destroy --name "$container_name" "$BUILD_NAME" 2>/dev/null || true
    }
    trap cleanup_container EXIT

    # --- STAGE 5: Configure System with Ansible ---
    if should_run_stage "ansible-configured"; then
        log_info "Stage 5: Configuring system with Ansible..."
        log_build_event "Starting Stage 5: Running Ansible configuration with tags='$ANSIBLE_TAGS' limit='$ANSIBLE_LIMIT'"
        
        # Ensure container is running before executing Ansible commands
        local container_name="$BUILD_NAME"
        log_info "Ensuring container '$container_name' is running..."
        if ! "$script_dir/manage-root-containers.sh" list 2>/dev/null | grep -q "$container_name"; then
            log_info "Starting container '$container_name'..."
            run_cmd "$script_dir/manage-root-containers.sh" start --name "$container_name" "$BUILD_NAME"
        else
            log_debug "Container '$container_name' is already running"
        fi
        
        local ansible_args=(
            "--pool" "$POOL_NAME"
            "--limit" "$ANSIBLE_LIMIT"
            "$BUILD_NAME"
            "$HOSTNAME"
        )
        [[ -n "$ANSIBLE_TAGS" ]] && ansible_args+=("--tags" "$ANSIBLE_TAGS")
        add_common_flags ansible_args

        run_cmd "$script_dir/configure-root-os.sh" "${ansible_args[@]}"
        set_build_status "ansible-configured"
        log_build_event "Completed Stage 5: Ansible configuration completed successfully"
        take_snapshot "5-ansible-configured"
    else
        log_info "Stage 5: Skipping Ansible configuration (already completed)"
    fi

    # --- STAGE 6: Cleanup and Complete ---
    if should_run_stage "completed"; then
        log_info "Stage 6: Finalizing build..."
        log_build_event "Starting Stage 6: Finalizing build and cleaning up resources"
        
        # Stop and destroy the container
        invoke_script "manage-root-containers.sh" "destroy" "--name" "$container_name" "$BUILD_NAME"
        
        # Clear the cleanup trap since we're doing it manually
        trap - EXIT
        
        set_build_status "completed"
        log_build_event "Completed Stage 6: Build finished successfully - ready for deployment"
        take_snapshot "6-completed"
    else
        log_info "Stage 6: Build already completed"
    fi

    # --- Build Complete ---
    local final_mountpoint="${DEFAULT_MOUNT_BASE}/${BUILD_NAME}"
    log_info "Build '$BUILD_NAME' completed successfully!"
    log_info "The new root filesystem is available at: $final_mountpoint"
    log_info ""
    log_info "To activate this build as the next boot environment:"
    log_info "  $script_dir/manage-root-datasets.sh promote '$BUILD_NAME'"
    log_info ""
    log_info "To list all available root environments:"
    log_info "  $script_dir/manage-root-datasets.sh list"
}

# --- Execute Main Function ---
# Wrap in a subshell to prevent 'set -e' from exiting the user's shell
# if the script is sourced.
(
    main "$@"
)
