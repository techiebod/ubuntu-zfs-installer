#!/bin/bash
#
# Constants for Ubuntu ZFS Installer Scripts
#
# This file contains all constant values used throughout the project
# to avoid magic strings and improve maintainability.
# This file is sourced by other scripts, so all variables are
# unused according to shellcheck, so help it chill out
# shellcheck disable=SC2034

# --- Prevent multiple sourcing ---
if [[ "${__CONSTANTS_LIB_LOADED:-}" == "true" ]]; then
    return 0
fi
readonly __CONSTANTS_LIB_LOADED="true"

# ==============================================================================
# BUILD STATUS CONSTANTS
# ==============================================================================

# Build status values in progression order
readonly STATUS_STARTED="started"
readonly STATUS_DATASETS_CREATED="datasets-created"
readonly STATUS_ROOT_MOUNTED="root-mounted"
readonly STATUS_OS_INSTALLED="os-installed"
readonly STATUS_VARLOG_MOUNTED="varlog-mounted"
readonly STATUS_CONTAINER_CREATED="container-created"
readonly STATUS_ANSIBLE_CONFIGURED="ansible-configured"
readonly STATUS_COMPLETED="completed"

# Valid status values that can be stored
readonly -a VALID_STATUSES=(
    "$STATUS_STARTED"
    "$STATUS_DATASETS_CREATED"
    "$STATUS_ROOT_MOUNTED"
    "$STATUS_OS_INSTALLED"
    "$STATUS_VARLOG_MOUNTED"
    "$STATUS_CONTAINER_CREATED"
    "$STATUS_ANSIBLE_CONFIGURED"
    "$STATUS_COMPLETED"
)

# Status progression map - what comes next after each status
declare -gAx STATUS_PROGRESSION=(
    ["$STATUS_STARTED"]="$STATUS_DATASETS_CREATED"
    ["$STATUS_DATASETS_CREATED"]="$STATUS_ROOT_MOUNTED"
    ["$STATUS_ROOT_MOUNTED"]="$STATUS_OS_INSTALLED"
    ["$STATUS_OS_INSTALLED"]="$STATUS_VARLOG_MOUNTED"
    ["$STATUS_VARLOG_MOUNTED"]="$STATUS_CONTAINER_CREATED"
    ["$STATUS_CONTAINER_CREATED"]="$STATUS_ANSIBLE_CONFIGURED"
    ["$STATUS_ANSIBLE_CONFIGURED"]="$STATUS_COMPLETED"
)

# ==============================================================================
# STAGE CONSTANTS
# ==============================================================================

# Stage function names in execution order
readonly STAGE_1_CREATE_DATASETS="stage_1_create_datasets"
readonly STAGE_2_MOUNT_ROOT="stage_2_mount_root"
readonly STAGE_3_INSTALL_OS="stage_3_install_os"
readonly STAGE_4_MOUNT_VARLOG="stage_4_mount_varlog"
readonly STAGE_5_CREATE_CONTAINER="stage_5_create_container"
readonly STAGE_6_CONFIGURE_ANSIBLE="stage_6_configure_ansible"
readonly STAGE_7_FINALIZE_BUILD="stage_7_finalize_build"

# All stage functions in execution order
readonly STAGE_FUNCTIONS=(
    "$STAGE_1_CREATE_DATASETS"
    "$STAGE_2_MOUNT_ROOT"
    "$STAGE_3_INSTALL_OS"
    "$STAGE_4_MOUNT_VARLOG"
    "$STAGE_5_CREATE_CONTAINER"
    "$STAGE_6_CONFIGURE_ANSIBLE"
    "$STAGE_7_FINALIZE_BUILD"
)

# Map statuses to their corresponding stage functions
declare -gAx STATUS_TO_STAGE=(
    ["$STATUS_STARTED"]="$STAGE_1_CREATE_DATASETS"
    ["$STATUS_DATASETS_CREATED"]="$STAGE_2_MOUNT_ROOT"
    ["$STATUS_ROOT_MOUNTED"]="$STAGE_3_INSTALL_OS"
    ["$STATUS_OS_INSTALLED"]="$STAGE_4_MOUNT_VARLOG"
    ["$STATUS_VARLOG_MOUNTED"]="$STAGE_5_CREATE_CONTAINER"
    ["$STATUS_CONTAINER_CREATED"]="$STAGE_6_CONFIGURE_ANSIBLE"
    ["$STATUS_ANSIBLE_CONFIGURED"]="$STAGE_7_FINALIZE_BUILD"
)

# ==============================================================================
# SNAPSHOT CONSTANTS
# ==============================================================================

readonly SNAPSHOT_PREFIX="build-stage"
readonly SNAPSHOT_TIMESTAMP_FORMAT="%Y%m%d-%H%M%S"

# Standard snapshot names for build stages
readonly SNAPSHOT_DATASETS_CREATED="1-datasets-created"
readonly SNAPSHOT_OS_INSTALLED="2-os-installed"
readonly SNAPSHOT_VARLOG_MOUNTED="3-varlog-mounted"
readonly SNAPSHOT_CONTAINER_CREATED="4-container-created"
readonly SNAPSHOT_ANSIBLE_CONFIGURED="5-ansible-configured"

# ==============================================================================
# INSTALL PROFILE CONSTANTS
# ==============================================================================

readonly INSTALL_PROFILE_MINIMAL="minimal"
readonly INSTALL_PROFILE_STANDARD="standard"
readonly INSTALL_PROFILE_FULL="full"

readonly VALID_INSTALL_PROFILES=(
    "$INSTALL_PROFILE_MINIMAL"
    "$INSTALL_PROFILE_STANDARD"
    "$INSTALL_PROFILE_FULL"
)

# Ubuntu package seeds for each profile
declare -gAx PROFILE_SEEDS=(
    ["$INSTALL_PROFILE_MINIMAL"]="server-minimal"
    ["$INSTALL_PROFILE_STANDARD"]="server-minimal ship"
    ["$INSTALL_PROFILE_FULL"]="server-minimal server"
)

# ==============================================================================
# ARCHITECTURE CONSTANTS
# ==============================================================================

readonly ARCH_AMD64="amd64"
readonly ARCH_ARM64="arm64"
readonly ARCH_I386="i386"

readonly VALID_ARCHITECTURES=(
    "$ARCH_AMD64"
    "$ARCH_ARM64"
    "$ARCH_I386"
)

# Architecture-specific package mappings
declare -gAx ARCH_KERNEL_PACKAGES=(
    ["$ARCH_AMD64"]="linux-image-amd64"
    ["$ARCH_ARM64"]="linux-image-arm64"
    ["$ARCH_I386"]="linux-image-686"
)

declare -gAx ARCH_GRUB_PACKAGES=(
    ["$ARCH_AMD64"]="grub-efi-amd64 grub-efi-amd64-bin grub-efi-amd64-signed"
    ["$ARCH_ARM64"]="grub-efi-arm64 grub-efi-arm64-bin"
    ["$ARCH_I386"]="grub-efi-ia32 grub-efi-ia32-bin"
)

# ==============================================================================
# DISTRIBUTION CONSTANTS
# ==============================================================================

readonly DISTRO_UBUNTU="ubuntu"
readonly DISTRO_DEBIAN="debian"

readonly VALID_DISTRIBUTIONS=(
    "$DISTRO_UBUNTU"
    "$DISTRO_DEBIAN"
)

# Distribution-specific configuration
declare -gAx DISTRO_DOCKER_IMAGES=(
    ["$DISTRO_UBUNTU"]="ubuntu:latest"
    ["$DISTRO_DEBIAN"]="debian:latest"
)

declare -gAx DISTRO_PACKAGE_TOOLS=(
    ["$DISTRO_UBUNTU"]="apt"
    ["$DISTRO_DEBIAN"]="apt"
)

# ==============================================================================
# PACKAGE CONSTANTS
# ==============================================================================

# Common packages to hold during installation
readonly GRUB_PACKAGES_TO_HOLD="grub-common grub2-common lilo lilo-doc mbr openipmi"

# Essential system packages
readonly ESSENTIAL_PACKAGES="ca-certificates systemd init zfsutils-linux zfs-initramfs apt curl wget"

# ==============================================================================
# URL CONSTANTS
# ==============================================================================

readonly UBUNTU_SEEDS_BASE_URL="https://ubuntu-archive-team.ubuntu.com/seeds"
readonly UBUNTU_API_BASE_URL="https://api.launchpad.net/1.0/ubuntu"

# ==============================================================================
# FILE SYSTEM CONSTANTS
# ==============================================================================

readonly STATUS_FILE_SUFFIX=".status"
readonly BUILD_LOG_SUFFIX=".log"
readonly CONTAINER_NAME_PREFIX="zfs-build"

# ==============================================================================
# VALIDATION PATTERNS
# ==============================================================================

readonly BUILD_NAME_PATTERN="^[a-zA-Z0-9._-]+$"
readonly BUILD_NAME_MAX_LENGTH=50
readonly HOSTNAME_PATTERN="^[a-z0-9.-]+$"  # Lowercase only for RFC compliance
readonly HOSTNAME_MAX_LENGTH=63

# ==============================================================================
# ERROR CODES
# ==============================================================================

readonly EXIT_SUCCESS=0
readonly EXIT_GENERAL_ERROR=1
readonly EXIT_INVALID_ARGS=2
readonly EXIT_MISSING_DEPS=3
readonly EXIT_CONFIG_ERROR=4
readonly EXIT_PERMISSION_ERROR=5
readonly EXIT_NETWORK_ERROR=6
readonly EXIT_TIMEOUT_ERROR=7

# ==============================================================================
# TIMEOUT VALUES (in seconds)
# ==============================================================================

export DEFAULT_CONTAINER_TIMEOUT=60
export DEFAULT_CONTAINER_STOP_TIMEOUT=10
export DEFAULT_NETWORK_TIMEOUT=30
export DEFAULT_ZFS_OPERATION_TIMEOUT=300

readonly DEFAULT_CONTAINER_TIMEOUT
readonly DEFAULT_CONTAINER_STOP_TIMEOUT
readonly DEFAULT_NETWORK_TIMEOUT
readonly DEFAULT_ZFS_OPERATION_TIMEOUT
