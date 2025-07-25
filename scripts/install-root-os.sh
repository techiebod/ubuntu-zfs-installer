#!/bin/bash
#
# Install Base OS using mmdebstrap
#
# This script creates a minimal, ZFS-ready base OS inside a target root dataset.
# It uses mmdebstrap running inside a Docker container for maximum compatibility.

# --- Script Setup ---
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$script_dir/../lib/common.sh"

# --- Script-specific Default values ---
POOL_NAME="${DEFAULT_POOL_NAME}"
MOUNT_BASE="${DEFAULT_MOUNT_BASE}"
BUILD_NAME=""
DISTRIBUTION="" # Now required
VERSION=""      # Now required
CODENAME=""     # Now required
ARCH="${DEFAULT_ARCH}"
PROFILE="${DEFAULT_INSTALL_PROFILE:-minimal}"  # Installation profile with fallback
VARIANT="${DEFAULT_VARIANT}"
DOCKER_IMAGE="${DEFAULT_DOCKER_IMAGE}"

# --- Usage Information ---
show_usage() {
    cat << EOF
Usage: $0 [OPTIONS] BUILD_NAME

Installs a base OS into the specified root dataset using mmdebstrap.
This script is typically called by the main 'build-new-root.sh' orchestrator.

ARGUMENTS:
  BUILD_NAME              The name of the target root dataset (e.g., 'ubuntu-noble').

OPTIONS:
  -p, --pool POOL         The ZFS pool where the root dataset exists (default: ${DEFAULT_POOL_NAME}).
  -d, --distribution DIST Distribution to install (e.g., 'ubuntu', 'debian').
  -v, --version VERSION   Distribution version (e.g., '25.04', '12').
  -c, --codename CODENAME Distribution codename (e.g., 'noble', 'bookworm').
  -a, --arch ARCH         Target architecture (default: ${DEFAULT_ARCH}).
      --profile PROFILE   Installation profile: minimal, standard, full (default: ${DEFAULT_INSTALL_PROFILE:-minimal}).
      --variant VARIANT   Debootstrap variant (default: ${DEFAULT_VARIANT}).
      --docker-image IMG  Docker image to use for the build (default: ${DEFAULT_DOCKER_IMAGE}).

$(show_common_options_help)

REQUIREMENTS:
  - Docker must be installed and running.
  - The target root dataset must already exist and be mounted.
EOF
    exit 0
}

# --- Argument Parsing ---
parse_args() {
    local remaining_args=()
    
    # First pass: handle common arguments
    parse_common_args remaining_args "$@"
    
    # Second pass: handle script-specific arguments
    local args=("${remaining_args[@]}")
    
    while [[ ${#args[@]} -gt 0 ]]; do
        case "${args[0]}" in
            -p|--pool) POOL_NAME="${args[1]}"; args=("${args[@]:2}") ;;
            -d|--distribution) DISTRIBUTION="${args[1]}"; args=("${args[@]:2}") ;;
            -v|--version) VERSION="${args[1]}"; args=("${args[@]:2}") ;;
            -c|--codename) CODENAME="${args[1]}"; args=("${args[@]:2}") ;;
            -a|--arch) ARCH="${args[1]}"; args=("${args[@]:2}") ;;
            --profile) PROFILE="${args[1]}"; args=("${args[@]:2}") ;;
            --variant) VARIANT="${args[1]}"; args=("${args[@]:2}") ;;
            --docker-image) DOCKER_IMAGE="${args[1]}"; args=("${args[@]:2}") ;;
            -h|--help) show_usage ;;
            -*) die "Unknown option: ${args[0]}" ;;
            *)
                if [[ -z "$BUILD_NAME" ]]; then
                    BUILD_NAME="${args[0]}"
                else
                    die "Too many arguments. Expected a single BUILD_NAME."
                fi
                args=("${args[@]:1}")
                ;;
        esac
    done
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
    local verbose_flag=""
    [[ "$VERBOSE" == "true" ]] && verbose_flag="--verbose"
    if ! base_packages=$("$package_script" --codename "$CODENAME" --arch "$ARCH" $verbose_flag $seeds); then
        die "Failed to get package list for $distribution $CODENAME"
    fi
    
    # Add ZFS and other required packages
    local zfs_packages="zfsutils-linux
zfs-initramfs"
    local keyring_packages="ubuntu-keyring"
    
    # Combine all packages
    local all_packages=$(echo -e "$base_packages\n$zfs_packages\n$keyring_packages" | sort -u | tr '\n' ',' | sed 's/,$//')
    
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
    if ! mountpoint -q "$mount_point"; then
        die "Target mount point '$mount_point' is not a mountpoint. The dataset must be mounted first."
    fi
}

# --- Main Logic ---
main() {
    parse_args "$@"
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
