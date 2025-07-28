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
source "$lib_dir/flag-helpers.sh"    # For common flag definitions

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
define_common_flags  # Add standard dry-run and debug flags

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

  # Build a Debian 12 system
  $0 --distribution debian --version 12 debian-bookworm my-server

  # Perform a dry run to see all the steps for a new build
  $0 --dry_run --codename noble ubuntu-test test-host

CLEANUP:
  This script automatically resumes builds from their last successful stage.
  To start fresh or clean up a failed build, use the build status management:
  
  # Clear build status to start from scratch
  scripts/manage-build-status.sh clear BUILD_NAME
  
  # Clean up all resources (datasets, containers, etc.)
  scripts/manage-root-datasets.sh --cleanup destroy BUILD_NAME

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
    # Process common flags (dry-run and debug)
    process_common_flags
}

# --- Prerequisite Checks ---
check_prerequisites() {
    log_build_debug "Starting prerequisite validation"

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
    if [[ "$CREATE_SNAPSHOTS" != "true" ]]; then
        return 0
    fi

    # Skip snapshots in dry-run mode since no actual datasets are created
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "Would create snapshot for stage: $stage"
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
    
    # In dry-run mode, also update virtual status for stage progression
    if [[ "$DRY_RUN" == "true" ]]; then
        VIRTUAL_BUILD_STATUS="$status"
    fi
}

check_build_status() {
    # In dry-run mode, return virtual status if it exists
    if [[ "$DRY_RUN" == "true" && -n "$VIRTUAL_BUILD_STATUS" ]]; then
        echo "$VIRTUAL_BUILD_STATUS"
        return 0
    fi
    
    "$script_dir/manage-build-status.sh" get "$BUILD_NAME" 2>/dev/null || echo ""
}

# Check if build is already completed
is_build_completed() {
    local current_status
    current_status=$(check_build_status)
    [[ "$current_status" == "completed" ]]
}

# Get the next stage that should run based on current build status
get_next_stage_to_run() {
    local current_status
    current_status=$(check_build_status)
    
    # Handle empty/no status - start with first stage
    if [[ -z "$current_status" ]]; then
        echo "$STAGE_1_CREATE_DATASETS"
        return 0
    fi
    
    # If already completed, return completed
    if [[ "$current_status" == "$STATUS_COMPLETED" ]]; then
        echo "completed"
        return 0
    fi
    
    # Use the mapping from constants.sh
    local stage="${STATUS_TO_STAGE[$current_status]:-$STAGE_1_CREATE_DATASETS}"
    echo "$stage"
}

clear_build_status() {
    run_cmd "$script_dir/manage-build-status.sh" clear "$BUILD_NAME"
}

# ==============================================================================
# STAGE IMPLEMENTATION FUNCTIONS
# ==============================================================================

# Get step number for a stage function
get_stage_step_number() {
    local stage_function="$1"
    for i in "${!STAGE_FUNCTIONS[@]}"; do
        if [[ "${STAGE_FUNCTIONS[$i]}" == "$stage_function" ]]; then
            echo $((i + 1))  # 1-based indexing for display
            return 0
        fi
    done
    echo "?"  # Unknown stage
}

# Stage 1: Create ZFS Datasets
stage_1_create_datasets() {
    local step_num
    step_num=$(get_stage_step_number "$STAGE_1_CREATE_DATASETS")
    log_step "$step_num" "Creating ZFS root dataset"
    log_build_event "Starting Stage $step_num: Creating ZFS datasets for distribution $DISTRIBUTION $DIST_VERSION"
    
    # Create datasets without cleanup flag - let it fail cleanly if they exist
    local dataset_args=("--pool" "$POOL_NAME" "create" "$BUILD_NAME")
    
    if ! invoke_script "manage-root-datasets.sh" "${dataset_args[@]}"; then
        if [[ "$DRY_RUN" == "true" ]]; then
            log_info "Dataset creation would have failed (likely already exists) - continuing dry run"
        else
            log_error "Failed to create ZFS datasets. Check the error above for details."
            log_info "If the dataset already exists, you can:"
            log_info "  1. Clear the build status: scripts/manage-build-status.sh clear $BUILD_NAME"
            log_info "  2. Or manually clean up with: scripts/manage-root-datasets.sh --cleanup destroy $BUILD_NAME"
            return 1
        fi
    fi
    
    set_build_status "$STATUS_DATASETS_CREATED"
    log_build_event "Completed Stage $step_num: ZFS datasets created successfully"
    take_snapshot "1-datasets-created"
}

# Stage 2: Install Operating System
stage_2_install_os() {
    local step_num
    step_num=$(get_stage_step_number "$STAGE_2_INSTALL_OS")
    log_step "$step_num" "Installing OS to root dataset"
    log_build_event "Starting Stage $step_num: Installing $DISTRIBUTION $DIST_VERSION to ZFS root"
    
    if ! invoke_script "install-root-os.sh" "$BUILD_NAME"; then
        log_error "Failed to install operating system to root dataset"
        return 1
    fi
    
    set_build_status "$STATUS_OS_INSTALLED"
    log_build_event "Completed Stage $step_num: Operating system installed successfully"
    take_snapshot "2-os-installed"
}

# Stage 3: Mount Varlog Dataset
stage_3_mount_varlog() {
    local step_num
    step_num=$(get_stage_step_number "$STAGE_3_MOUNT_VARLOG")
    log_step "$step_num" "Mounting varlog dataset"
    log_build_event "Starting Stage $step_num: Mounting varlog dataset for persistent logging"
    
    if ! invoke_script "manage-root-datasets.sh" "--pool" "$POOL_NAME" "mount-varlog" "$BUILD_NAME"; then
        if [[ "$DRY_RUN" == "true" ]]; then
            log_info "Varlog mount would have failed (dataset doesn't exist) - continuing dry run"
        else
            log_error "Failed to mount varlog dataset. Check the error above for details."
            return 1
        fi
    fi
    
    set_build_status "$STATUS_VARLOG_MOUNTED"
    log_build_event "Completed Stage $step_num: Varlog dataset mounted successfully"
    take_snapshot "3-varlog-mounted"
}

# Stage 4: Create and Prepare Container
stage_4_create_container() {
    local step_num
    step_num=$(get_stage_step_number "$STAGE_4_CREATE_CONTAINER")
    log_step "$step_num" "Creating container for Ansible execution"
    log_build_event "Starting Stage $step_num: Creating systemd-nspawn container '$HOSTNAME' for configuration"
    
    local container_name="$BUILD_NAME"
    if ! invoke_script "manage-root-containers.sh" "create" "--pool" "$POOL_NAME" "--name" "$container_name" "--hostname" "$HOSTNAME" "--install-packages" "ansible,python3-apt" "$BUILD_NAME"; then
        if [[ "$DRY_RUN" == "true" ]]; then
            log_info "Container creation would have failed (dataset doesn't exist) - continuing dry run"
        else
            log_error "Failed to create container. Check the error above for details."
            return 1
        fi
    else
        # Start the container
        if ! invoke_script "manage-root-containers.sh" "start" "--name" "$container_name" "$BUILD_NAME"; then
            if [[ "$DRY_RUN" == "true" ]]; then
                log_info "Container start would have failed - continuing dry run"
            else
                log_error "Failed to start container. Check the error above for details."
                return 1
            fi
        fi
    fi
    
    set_build_status "$STATUS_CONTAINER_CREATED"
    log_build_event "Completed Stage $step_num: Container created and started successfully"
    take_snapshot "4-container-created"
}

# Stage 5: Configure System with Ansible
stage_5_configure_ansible() {
    local step_num
    step_num=$(get_stage_step_number "$STAGE_5_CONFIGURE_ANSIBLE")
    log_step "$step_num" "Configuring system with Ansible"
    log_build_event "Starting Stage $step_num: Running Ansible configuration with tags='$ANSIBLE_TAGS' limit='$ANSIBLE_LIMIT'"
    
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

    if ! run_cmd "$script_dir/configure-root-os.sh" "${ansible_args[@]}"; then
        if [[ "$DRY_RUN" == "true" ]]; then
            log_info "Ansible configuration would have failed - continuing dry run"
        else
            log_error "Failed to configure system with Ansible. Check the error above for details."
            return 1
        fi
    fi
    
    set_build_status "$STATUS_ANSIBLE_CONFIGURED"
    log_build_event "Completed Stage $step_num: Ansible configuration completed successfully"
    take_snapshot "5-ansible-configured"
}

# Stage 6: Cleanup and Complete
stage_6_finalize_build() {
    local step_num
    step_num=$(get_stage_step_number "$STAGE_6_FINALIZE_BUILD")
    log_step "$step_num" "Finalizing build"
    log_build_event "Starting Stage $step_num: Finalizing build and cleaning up resources"
    
    # Stop and destroy the container
    local container_name="$BUILD_NAME"
    if ! invoke_script "manage-root-containers.sh" "destroy" "--name" "$container_name" "$BUILD_NAME"; then
        if [[ "$DRY_RUN" == "true" ]]; then
            log_info "Container destruction would have failed - continuing dry run"
        else
            log_warning "Failed to destroy container - may need manual cleanup"
        fi
    fi
    
    # Clear the cleanup trap since we're doing it manually
    trap - EXIT
    
    set_build_status "$STATUS_COMPLETED"
    log_build_event "Completed Stage $step_num: Build finished successfully - ready for deployment"
    take_snapshot "6-completed"
}

# Execute a specific stage by name
execute_stage() {
    local stage_name="$1"
    
    case "$stage_name" in
        "stage_1_create_datasets")   stage_1_create_datasets ;;
        "stage_2_install_os")        stage_2_install_os ;;
        "stage_3_mount_varlog")      stage_3_mount_varlog ;;
        "stage_4_create_container")  stage_4_create_container ;;
        "stage_5_configure_ansible") stage_5_configure_ansible ;;
        "stage_6_finalize_build")    stage_6_finalize_build ;;
        "completed")                 return 0 ;;  # Nothing to do
        *)
            log_error "Unknown stage: $stage_name"
            return 1
            ;;
    esac
}

# --- Main Build Logic ---
main() {
    parse_args "$@"
    
    # Initialize virtual build status for dry-run mode
    VIRTUAL_BUILD_STATUS=""
    
    # Disable timestamps for cleaner output in interactive mode
    if is_interactive_mode; then
        # shellcheck disable=SC2034  # Used by logging system
        LOG_WITH_TIMESTAMPS=false
    fi
    
    # Set up cleanup handling only after confirming we're doing actual work
    # (not just showing help or validating arguments)
    setup_cleanup_trap
    
    check_prerequisites

    # Set up build-specific logging context
    set_build_log_context "$BUILD_NAME"

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
    log_info "  📸 Snapshots:      $CREATE_SNAPSHOTS"
    log_info "  🧪 Dry Run:        $DRY_RUN"

    # Log build start (this goes to both console and file)
    log_build_event "Build initiated: $DISTRIBUTION $DIST_VERSION ($ARCH) → hostname '$HOSTNAME' on pool '$POOL_NAME'"

    # Check current build status and determine starting stage
    local current_status
    current_status=$(check_build_status)
    if [[ -n "$current_status" ]]; then
        log_info "Current build status: $current_status - checking which stages need to run"
    fi

    # Set initial status if none exists
    if [[ -z "$current_status" ]]; then
        set_build_status "$STATUS_STARTED"
    fi

    # Check if build is already completed
    current_status=$(check_build_status)
    if [[ "$current_status" == "$STATUS_COMPLETED" ]]; then
        log_info "Build '$BUILD_NAME' is already completed!"
        local final_mountpoint="${DEFAULT_MOUNT_BASE}/${BUILD_NAME}"
        log_info "The root filesystem is available at: $final_mountpoint"
        return 0
    fi

    # Execute stages sequentially until completion
    while true; do
        local next_stage
        next_stage=$(get_next_stage_to_run)
        
        if [[ "$next_stage" == "completed" ]]; then
            log_info "All stages completed successfully!"
            break
        fi
        
        log_debug "Executing next stage: $next_stage"
        if ! execute_stage "$next_stage"; then
            if [[ "$DRY_RUN" == "true" ]]; then
                log_info "Stage would have failed in real run - continuing dry run"
            else
                log_error "Stage $next_stage failed"
                set_build_status "$STATUS_FAILED"
                exit 1
            fi
        fi
        
        # Safety check to prevent infinite loops
        local new_status
        new_status=$(check_build_status)
        if [[ "$new_status" == "$current_status" ]]; then
            log_error "Stage completed but status didn't change. This indicates a bug."
            exit 1
        fi
        current_status="$new_status"
    done

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
