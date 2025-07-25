#!/bin/bash
#
# Multi-Distribution ZFS Root Builder - Orchestrates the complete build process
#
# This script serves as the main entry point for creating a new ZFS-based
# root filesystem. It calls other specialized scripts to handle each stage
# of the process, from dataset creation to system configuration.

# --- Script Setup ---
# Source the common library to get access to standardized functions
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$script_dir/../lib/common.sh"

# --- Script-specific Default values ---
# These are defaults for this script, which can be overridden by command-line args.
BUILD_NAME=""
HOSTNAME=""
DISTRIBUTION="${DEFAULT_DISTRIBUTION}"
VERSION=""
CODENAME=""
ARCH="${DEFAULT_ARCH}"
INSTALL_PROFILE="${DEFAULT_INSTALL_PROFILE:-minimal}"
POOL_NAME="${DEFAULT_POOL_NAME}"
ANSIBLE_TAGS=""
ANSIBLE_LIMIT=""
# --- Configuration ---
DRY_RUN=false
VERBOSE=false
DEBUG=false
CREATE_SNAPSHOTS=true
FORCE_RESTART=false

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

OPTIONS:
  -d, --distribution DIST Distribution to build (default: ${DEFAULT_DISTRIBUTION}).
  -v, --version VERSION   Distribution version (e.g., 25.04, 12).
  -c, --codename CODENAME Distribution codename (e.g., noble, bookworm).
                          For Ubuntu, you can specify either version or codename.
  -a, --arch ARCH         Target architecture (default: ${DEFAULT_ARCH}).
  -p, --pool POOL         ZFS pool to use (default: ${DEFAULT_POOL_NAME}).
      --profile PROFILE   Package installation profile (minimal, standard, full; default: ${DEFAULT_INSTALL_PROFILE:-minimal}).
  -t, --tags TAGS         Comma-separated list of Ansible tags to run.
  -l, --limit PATTERN     Ansible limit pattern (default: HOSTNAME).
      --snapshots         Create ZFS snapshots after major build stages (default: enabled).
      --no-snapshots      Disable ZFS snapshot creation for faster builds.
      --restart           Force restart from beginning, ignoring existing build status.
      --verbose           Enable verbose output, showing all command outputs.
      --dry-run           Show all commands that would be run without executing them.
      --debug             Enable detailed debug logging.
  -h, --help              Show this help message.

EXAMPLES:
  # Build an Ubuntu 24.04 system for host 'blackbox'
  $0 --version 24.04 ubuntu-noble blackbox

  # Build an Ubuntu server with standard packages (ubuntu-server equivalent)
  $0 --version 24.04 --profile standard ubuntu-server blackbox

  # Build a Debian 12 system, cleaning up any previous build with the same name
    # Build a Debian system
  $0 --distribution debian --version 12 debian-bookworm my-server

  # Perform a dry run to see all the steps for a new build
  $0 --dry-run --codename noble ubuntu-test test-host

REQUIREMENTS:
  - Docker must be installed and running for the OS installation stage.
  - The target ZFS pool must exist.
  - An Ansible host variables file must exist at 'config/host_vars/HOSTNAME.yml'.
EOF
    exit 0
}

# --- Argument Parsing ---
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -d|--distribution) DISTRIBUTION="$2"; shift 2 ;;
            -v|--version) VERSION="$2"; shift 2 ;;
            -c|--codename) CODENAME="$2"; shift 2 ;;
            -a|--arch) ARCH="$2"; shift 2 ;;
            -p|--pool) POOL_NAME="$2"; shift 2 ;;
            --profile) INSTALL_PROFILE="$2"; shift 2 ;;
            -t|--tags) ANSIBLE_TAGS="$2"; shift 2 ;;
            -l|--limit) ANSIBLE_LIMIT="$2"; shift 2 ;;
            --snapshots) CREATE_SNAPSHOTS=true; shift ;;
            --no-snapshots) CREATE_SNAPSHOTS=false; shift ;;
            --restart) FORCE_RESTART=true; shift ;;
            --verbose) VERBOSE=true; shift ;;
            --dry-run) DRY_RUN=true; shift ;;
            --debug) DEBUG=true; shift ;;
            -h|--help) show_usage ;;
            -*) die "Unknown option: $1" ;;
            *)
                if [[ -z "$BUILD_NAME" ]]; then
                    BUILD_NAME="$1"
                elif [[ -z "$HOSTNAME" ]]; then
                    HOSTNAME="$1"
                else
                    die "Too many arguments. Expected BUILD_NAME and HOSTNAME."
                fi
                shift
                ;;
        esac
    done
}

# --- Prerequisite Checks ---
check_prerequisites() {
    log_info "Performing prerequisite checks..."

    if [[ -z "$BUILD_NAME" || -z "$HOSTNAME" ]]; then
        show_usage
        die "Missing required arguments: BUILD_NAME and HOSTNAME."
    fi

    local host_vars_file
    host_vars_file="$(dirname "$script_dir")/config/host_vars/${HOSTNAME}.yml"
    if [[ ! -f "$host_vars_file" ]]; then
        die "Ansible host_vars file not found for '$HOSTNAME' at '$host_vars_file'."
    fi

    # Check for required helper scripts in the same directory
    require_command "$script_dir/manage-root-datasets.sh"
    require_command "$script_dir/install-root-os.sh"
    require_command "$script_dir/configure-root-os.sh"
    if [[ "$CREATE_SNAPSHOTS" == true ]]; then
        require_command "$script_dir/manage-root-snapshots.sh"
    fi

    # Check for system dependencies
    check_zfs_pool "$POOL_NAME"
    check_docker
    log_info "All prerequisite checks passed."
}

# --- Helper to create snapshots ---
take_snapshot() {
    local stage="$1"
    if [[ "$CREATE_SNAPSHOTS" != true ]]; then
        return 0
    fi

    log_info "Creating snapshot for stage: $stage"
    local snapshot_args=(
        "--pool" "$POOL_NAME"
        "create"
        "$BUILD_NAME"
        "$stage"
    )
    [[ "$VERBOSE" == true ]] && snapshot_args+=("--verbose")
    [[ "$DRY_RUN" == true ]] && snapshot_args+=("--dry-run")
    [[ "$DEBUG" == true ]] && snapshot_args+=("--debug")

    run_cmd "$script_dir/manage-root-snapshots.sh" "${snapshot_args[@]}"
}

# --- Helper to manage build status ---
set_build_status() {
    local status="$1"
    log_debug "Setting build status to: $status"
    run_cmd "$script_dir/manage-build-status.sh" set "$status" "$BUILD_NAME"
}

log_build_event() {
    local message="$1"
    run_cmd "$script_dir/manage-build-status.sh" log "$BUILD_NAME" "$message"
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
    check_prerequisites

    # Define container name used throughout the build process
    container_name="${BUILD_NAME}"

    # Resolve distribution version and codename
    resolve_dist_info "$DISTRIBUTION" "$VERSION" "$CODENAME"

    # Set Ansible limit if not provided
    if [[ -z "$ANSIBLE_LIMIT" ]]; then
        ANSIBLE_LIMIT="$HOSTNAME"
    fi

    log_info "Starting build process with the following settings:"
    log_info "  Build Name:     $BUILD_NAME"
    log_info "  Target Host:    $HOSTNAME"
    log_info "  ZFS Pool:       $POOL_NAME"
    log_info "  Distribution:   $DISTRIBUTION"
    log_info "  Version:        $DIST_VERSION"
    log_info "  Codename:       $DIST_CODENAME"
    log_info "  Architecture:   $ARCH"
    log_info "  Ansible Tags:   ${ANSIBLE_TAGS:-'(none)'}"
    log_info "  Ansible Limit:  $ANSIBLE_LIMIT"
    log_info "  Snapshots:      $CREATE_SNAPSHOTS"
    log_info "  Force Restart:  $FORCE_RESTART"
    log_info "  Dry Run:        $DRY_RUN"

    # Log build start
    log_build_event "Build initiated: $DISTRIBUTION $DIST_VERSION ($ARCH) -> hostname '$HOSTNAME' on pool '$POOL_NAME'"

    # Check current build status
    local current_status
    current_status=$(check_build_status)
    if [[ -n "$current_status" ]]; then
        log_info "Current build status: $current_status"
        if [[ "$FORCE_RESTART" == true ]]; then
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
        log_info "Stage 1: Creating ZFS root dataset..."
        log_build_event "Starting Stage 1: Creating ZFS datasets for distribution $DISTRIBUTION $DIST_VERSION"
        local zfs_script_args=(
            "--pool" "$POOL_NAME"
            "create"
            "$BUILD_NAME"
        )
        [[ "$VERBOSE" == true ]] && zfs_script_args+=("--verbose")
        [[ "$DRY_RUN" == true ]] && zfs_script_args+=("--dry-run")
        [[ "$DEBUG" == true ]] && zfs_script_args+=("--debug")

        run_cmd "$script_dir/manage-root-datasets.sh" "${zfs_script_args[@]}"
        set_build_status "datasets-created"
        log_build_event "Completed Stage 1: ZFS datasets created successfully"
        take_snapshot "1-datasets-created"
    else
        log_info "Stage 1: Skipping ZFS dataset creation (already completed)"
    fi

    # --- STAGE 2: Install Base OS ---
    if should_run_stage "os-installed"; then
        log_info "Stage 2: Installing base operating system..."
        log_build_event "Starting Stage 2: Installing $DISTRIBUTION $DIST_VERSION base OS on $ARCH architecture"
        
        # If we're rerunning Stage 2 (i.e., datasets already exist but OS install failed),
        # roll back to the clean state from Stage 1 to ensure a fresh start
        local current_status
        current_status=$(check_build_status)
        if [[ "$current_status" == "datasets-created" ]]; then
            log_info "Rolling back to clean state before OS installation..."
            # Use the simplified rollback to stage 1 snapshot
            local rollback_args=(
                "--pool" "$POOL_NAME"
                "rollback"
                "$BUILD_NAME"
                "build-stage-1-datasets-created"
            )
            [[ "$VERBOSE" == true ]] && rollback_args+=("--verbose")
            [[ "$DRY_RUN" == true ]] && rollback_args+=("--dry-run")
            [[ "$DEBUG" == true ]] && rollback_args+=("--debug")
            
            if run_cmd "$script_dir/manage-root-snapshots.sh" "${rollback_args[@]}"; then
                log_info "Successfully rolled back to stage 1 snapshot"
            else
                log_warn "Failed to rollback to stage 1 snapshot, proceeding with current state"
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
        [[ "$VERBOSE" == true ]] && os_install_args+=("--verbose")
        [[ "$DRY_RUN" == true ]] && os_install_args+=("--dry-run")
        [[ "$DEBUG" == true ]] && os_install_args+=("--debug")

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
        local varlog_args=(
            "--pool" "$POOL_NAME"
            "mount-varlog"
            "$BUILD_NAME"
        )
        [[ "$VERBOSE" == true ]] && varlog_args+=("--verbose")
        [[ "$DRY_RUN" == true ]] && varlog_args+=("--dry-run")
        [[ "$DEBUG" == true ]] && varlog_args+=("--debug")

        run_cmd "$script_dir/manage-root-datasets.sh" "${varlog_args[@]}"
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
        local container_args=(
            "create"
            "--pool" "$POOL_NAME"
            "--name" "$container_name"
            "--hostname" "$HOSTNAME"
            "--install-packages" "ansible,python3-apt"
            "$BUILD_NAME"
        )
        [[ "$VERBOSE" == true ]] && container_args+=("--verbose")
        [[ "$DRY_RUN" == true ]] && container_args+=("--dry-run")
        [[ "$DEBUG" == true ]] && container_args+=("--debug")
        
        run_cmd "$script_dir/manage-root-containers.sh" "${container_args[@]}"
        
        # Start the container
        run_cmd "$script_dir/manage-root-containers.sh" start --name "$container_name" "$BUILD_NAME"
        
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
        [[ "$VERBOSE" == true ]] && ansible_args+=("--verbose")
        [[ "$DRY_RUN" == true ]] && ansible_args+=("--dry-run")
        [[ "$DEBUG" == true ]] && ansible_args+=("--debug")

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
        run_cmd "$script_dir/manage-root-containers.sh" destroy --name "$container_name" "$BUILD_NAME"
        
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
