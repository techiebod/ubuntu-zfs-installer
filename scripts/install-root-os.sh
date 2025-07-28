#!/bin/bash
#
# Install Base OS using mmdebstrap
#
# This script creates a minimal, ZFS-ready OS inside a target root dataset.
# It uses mmdebstrap running inside a Docker container for maximum compatibility.

# --- Script Setup ---
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
lib_dir="$script_dir/../lib"

# Load the core library which sets up essential project structure and variables
source "$lib_dir/core.sh"

# Load libraries we need
source "$lib_dir/logging.sh"         # For logging functions
source "$lib_dir/execution.sh"       # For argument parsing and run_cmd
source "$lib_dir/validation.sh"      # For input validation
source "$lib_dir/dependencies.sh"    # For require_command (docker)
source "$lib_dir/ubuntu-api.sh"      # For version resolution
source "$lib_dir/zfs.sh"             # For ZFS dataset paths
source "$lib_dir/build-status.sh"    # For build status integration

# Load shflags library for standardized argument parsing
source "$lib_dir/vendor/shflags"

# --- Flag Definitions ---
# Define all command-line flags with defaults and descriptions
DEFINE_string 'pool' "${DEFAULT_POOL_NAME}" 'The ZFS pool where the root dataset exists' 'p'
DEFINE_string 'distribution' '' 'Distribution to install (e.g., ubuntu, debian)' 'd'
DEFINE_string 'version' '' 'Distribution version (e.g., 25.04, 12)' 'v'
DEFINE_string 'codename' '' 'Distribution codename (e.g., noble, bookworm)' 'c'
DEFINE_string 'arch' "${DEFAULT_ARCH}" 'Target architecture' 'a'
DEFINE_string 'profile' "${DEFAULT_INSTALL_PROFILE:-minimal}" 'Installation profile: minimal, standard, full'
DEFINE_string 'variant' "${DEFAULT_VARIANT}" 'Debootstrap variant'
DEFINE_string 'docker_image' "${DEFAULT_DOCKER_IMAGE}" 'Docker image to use for the build'
DEFINE_boolean 'dry-run' false 'Show all commands that would be run without executing them'
DEFINE_boolean 'debug' false 'Enable detailed debug logging'

# --- Script-specific Variables ---
BUILD_NAME=""

# --- Usage Information ---
show_usage() {
    cat << EOF
Usage: $0 [OPTIONS] BUILD_NAME

Installs a base OS into the specified root dataset using mmdebstrap.
This script is typically called by the main 'build-new-root.sh' orchestrator.

ARGUMENTS:
  BUILD_NAME              The name of the target root dataset (e.g., 'ubuntu-noble').

EOF
    echo "OPTIONS:"
    flags_help
    cat << EOF

REQUIREMENTS:
  - Docker must be installed and running.
  - The target root dataset must already exist and be mounted.
EOF
}

# --- Argument Parsing ---
parse_args() {
    # Parse flags and return non-flag arguments
    FLAGS "$@" || exit 1
    eval set -- "${FLAGS_ARGV}"
    
    # Process positional arguments
    if [[ $# -ne 1 ]]; then
        log_error "Expected exactly one BUILD_NAME argument"
        echo ""
        show_usage
        exit 1
    fi
    
    BUILD_NAME="$1"
    
    # Set global variables from flags for compatibility with existing code
    POOL_NAME="${FLAGS_pool}"
    MOUNT_BASE="${DEFAULT_MOUNT_BASE}"  # Not configurable in this script
    DISTRIBUTION="${FLAGS_distribution}"
    VERSION="${FLAGS_version}"
    CODENAME="${FLAGS_codename}"
    ARCH="${FLAGS_arch}"
    PROFILE="${FLAGS_profile}"
    VARIANT="${FLAGS_variant}"
    DOCKER_IMAGE="${FLAGS_docker_image}"
    # shellcheck disable=SC2034,SC2154  # FLAGS_dry_run is set by shflags
    DRY_RUN=$([ "${FLAGS_dry_run}" -eq 0 ] && echo "true" || echo "false")
    DEBUG=$([ "${FLAGS_debug}" -eq 0 ] && echo "true" || echo "false")
}

# --- Package Configuration Loading ---
load_package_config() {
    local distribution="$1"
    local profile_override="$2"  # Optional profile override
    
    log_debug "Loading packages for $distribution with profile: ${profile_override:-default}"
    
    # Use the get-ubuntu-packages script to get base packages
    local package_script="$script_dir/get-ubuntu-packages.sh"
    if [[ ! -f "$package_script" ]]; then
        die "Package generation script not found: $package_script"
    fi
    
    # Determine which seeds to use based on profile
    local seeds
    case "${profile_override:-minimal}" in
        minimal)
            seeds="server-minimal"
            log_info "Using minimal installation profile"
            ;;
        standard)
            seeds="server-minimal ship"
            log_info "Using standard installation profile"
            ;;
        full|server)
            seeds="server-minimal server"
            log_info "Using full/server installation profile"
            ;;
        *)
            log_warn "Unknown installation profile '${profile_override}', using minimal (server-minimal)"
            seeds="server-minimal"
            ;;
    esac
    
    # Get base packages from Ubuntu seeds
    local base_packages
    local package_verbose_flag=""
    # When debug is enabled, pass --verbose to the package utility for detailed output
    [[ "$DEBUG" == "true" ]] && package_verbose_flag="--verbose"
    if ! base_packages=$("$package_script" --codename "$CODENAME" --arch "$ARCH" $package_verbose_flag $seeds); then
        die "Failed to get package list for $distribution $CODENAME"
    fi
    
    # Add ZFS and other required packages
    local zfs_packages="zfsutils-linux
zfs-initramfs"
    local keyring_packages="ubuntu-keyring"
    
    # Combine all packages
    local all_packages
    all_packages=$(echo -e "$base_packages\n$zfs_packages\n$keyring_packages" | sort -u | tr '\n' ',' | sed 's/,$//')
    
    log_debug "Final package list: $all_packages"
    echo "$all_packages"
}

get_apt_components() {
    # Standard APT components for Ubuntu
    echo "main,universe"
}
check_prerequisites() {
    if [[ -z "$BUILD_NAME" || -z "$DISTRIBUTION" || -z "$VERSION" || -z "$CODENAME" ]]; then
        show_usage
        die "Missing required arguments: BUILD_NAME, --distribution, --version, and --codename."
    fi
    
    validate_architecture "$ARCH"
    validate_distribution "$DISTRIBUTION"

    check_docker
    check_zfs_pool "$POOL_NAME"

    local mount_point="${MOUNT_BASE}/${BUILD_NAME}"
    if [[ "$DRY_RUN" != "true" ]]; then
        if ! mountpoint -q "$mount_point"; then
            die "Target mount point '$mount_point' is not a mountpoint. The dataset must be mounted first."
        fi
    else
        log_debug "Skipping mountpoint check in dry-run mode for: $mount_point"
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

    local mount_point="${MOUNT_BASE}/${BUILD_NAME}"
    log_info "Starting base OS installation for '$BUILD_NAME'..."
    log_info "  Distribution: $DISTRIBUTION $VERSION ($CODENAME)"
    log_info "  Target:       $mount_point"

    # Load package configuration for the distribution
    log_info "Loading package configuration for $DISTRIBUTION..."
    local base_packages
    base_packages=$(load_package_config "$DISTRIBUTION" "$PROFILE")
    log_debug "Base packages: $base_packages"
    
    # Get APT components for the distribution
    local apt_components
    apt_components=$(get_apt_components "$DISTRIBUTION")

    local host_id
    host_id=$(hostid)
    log_info "Propagating hostid '$host_id' to new OS for ZFS compatibility."

    # This command will be executed inside the Docker container
    local mmdebstrap_cmd
    mmdebstrap_cmd=$(cat <<EOF
set -euo pipefail
echo 'Updating package lists...'
apt-get update -qq
echo 'Installing mmdebstrap and dependencies...'
apt-get install -y -qq mmdebstrap wget gnupg
echo 'Creating $DISTRIBUTION $VERSION ($CODENAME) base image...'
mmdebstrap \\
    --arch=$ARCH \\
    --variant=$VARIANT \\
    --components="$apt_components" \\
    --include=$base_packages \\
    --customize-hook='echo "\$HOST_ID_VAR" > "\$1/etc/hostid"' \\
    --customize-hook='chroot "\$1" apt-mark hold $GRUB_PACKAGES_TO_HOLD ${ARCH_GRUB_PACKAGES[$ARCH]:-} &>/dev/null || true' \\
    "$CODENAME" \\
    "/output"
EOF
)

    log_debug "mmdebstrap command to be run in Docker:\n$mmdebstrap_cmd"

    # Run mmdebstrap in a Docker container, mounting the target dataset
    run_cmd docker run --rm --privileged \
        -e "HOST_ID_VAR=${host_id}" \
        -v "${mount_point}:/output" \
        "$DOCKER_IMAGE" \
        /bin/bash -c "$mmdebstrap_cmd"

    log_info "Base OS installation for '$BUILD_NAME' complete."
}

# --- Execute Main Function ---
(
    main "$@"
)
