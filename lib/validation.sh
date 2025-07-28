#!/bin/bash
#
# Validation Library
#
# This library provides comprehensive validation functions for build names,
# hostnames, configurations, and system requirements. It includes input
# validation, system checks, and configuration validation functionality.

# --- Prevent multiple sourcing ---
if [[ "${__VALIDATION_LIB_LOADED:-}" == "true" ]]; then
    return 0
fi
readonly __VALIDATION_LIB_LOADED="true"

# Load logging library if not already loaded
if [[ "${__LOGGING_LIB_LOADED:-}" != "true" ]]; then
    # Determine library directory
    VALIDATION_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    source "$VALIDATION_LIB_DIR/logging.sh"
fi

# ==============================================================================
# VALIDATION PATTERNS AND CONSTANTS
# ==============================================================================

# Patterns for input validation (only define if not already defined)
if [[ -z "${BUILD_NAME_PATTERN:-}" ]]; then
    readonly BUILD_NAME_PATTERN='^[a-zA-Z0-9._-]+$'
fi
if [[ -z "${BUILD_NAME_MAX_LENGTH:-}" ]]; then
    readonly BUILD_NAME_MAX_LENGTH=63
fi
if [[ -z "${HOSTNAME_PATTERN:-}" ]]; then
    readonly HOSTNAME_PATTERN='^[a-z0-9.-]+$'  # Lowercase only for RFC compliance
fi
if [[ -z "${HOSTNAME_MAX_LENGTH:-}" ]]; then
    readonly HOSTNAME_MAX_LENGTH=253
fi

# Valid options arrays (only define if not already defined)
if [[ -z "${VALID_INSTALL_PROFILES:-}" ]]; then
    readonly VALID_INSTALL_PROFILES=("minimal" "server" "desktop" "developer")
fi
if [[ -z "${VALID_ARCHITECTURES:-}" ]]; then
    readonly VALID_ARCHITECTURES=("amd64" "arm64")
fi
if [[ -z "${VALID_DISTRIBUTIONS:-}" ]]; then
    readonly VALID_DISTRIBUTIONS=("ubuntu" "debian")
fi

# ==============================================================================
# VALIDATION HELPER FUNCTIONS
# ==============================================================================

# Generic function to validate a value against an array of valid options
# Usage: validate_in_array "value" "context" "${VALID_ARRAY[@]}"
validate_in_array() {
    local value="$1"
    local context="$2"
    shift 2
    local valid_options=("$@")
    
    for valid_option in "${valid_options[@]}"; do
        if [[ "$value" == "$valid_option" ]]; then
            return 0
        fi
    done
    
    die "Invalid $context: '$value'. Valid options are: ${valid_options[*]}"
}

# ==============================================================================
# INPUT VALIDATION FUNCTIONS
# ==============================================================================

# Validate build name format
validate_build_name() {
    local name="$1"
    local context="${2:-build name}"
    
    if [[ ! "$name" =~ $BUILD_NAME_PATTERN ]]; then
        die "Invalid $context format: '$name'. Must contain only letters, numbers, dots, hyphens, and underscores."
    fi
    
    if [[ ${#name} -gt $BUILD_NAME_MAX_LENGTH ]]; then
        die "Invalid $context length: '$name'. Must be $BUILD_NAME_MAX_LENGTH characters or less."
    fi
}

# Validate hostname format
validate_hostname() {
    local hostname="$1"
    
    if [[ ! "$hostname" =~ $HOSTNAME_PATTERN ]]; then
        die "Invalid hostname format: '$hostname'. Must contain only letters, numbers, dots, and hyphens."
    fi
    
    if [[ ${#hostname} -gt $HOSTNAME_MAX_LENGTH ]]; then
        die "Invalid hostname length: '$hostname'. Must be $HOSTNAME_MAX_LENGTH characters or less."
    fi
}

# Validate install profile
validate_install_profile() {
    local profile="$1"
    validate_in_array "$profile" "install profile" "${VALID_INSTALL_PROFILES[@]}"
}

# Validate architecture
validate_architecture() {
    local arch="$1"
    local context="${2:-architecture}"
    validate_in_array "$arch" "$context" "${VALID_ARCHITECTURES[@]}"
}

# Validate distribution
validate_distribution() {
    local distro="$1"
    local context="${2:-distribution}"
    validate_in_array "$distro" "$context" "${VALID_DISTRIBUTIONS[@]}"
}

# ==============================================================================
# SYSTEM VALIDATION FUNCTIONS
# ==============================================================================

# Check if the specified ZFS pool exists with enhanced validation
check_zfs_pool() {
    local pool_name="${1:-$DEFAULT_POOL_NAME}"
    
    # Note: require_command will be handled by dependencies.sh when extracted
    if ! command -v zpool &>/dev/null; then
        die_with_dependency_error "zpool" "sudo apt install zfsutils-linux"
    fi
    
    log_debug "Checking for ZFS pool '$pool_name'..."
    
    if ! zpool list -H -o name "$pool_name" &>/dev/null; then
        local available_pools
        available_pools=$(run_cmd_read zpool list -H -o name 2>/dev/null | sed 's/^/    /' | tr '\n' ' ')
        
        die_with_context \
            "ZFS pool '$pool_name' not found" \
            "Available pools:${available_pools:- None}. Create a pool with: sudo zpool create $pool_name <device>" \
            "$EXIT_CONFIG_ERROR"
    fi
    
    # Check pool health
    local pool_health
    pool_health=$(run_cmd_read zpool list -H -o health "$pool_name" 2>/dev/null)
    if [[ "$pool_health" != "ONLINE" ]]; then
        log_warn "⚠️  ZFS pool '$pool_name' status: $pool_health"
        log_info "💡 Check pool status with: sudo zpool status $pool_name"
    else
        log_debug "✓ ZFS pool '$pool_name' is healthy (ONLINE)"
    fi
}

# Check if Docker is installed and the daemon is responsive
check_docker() {
    # Note: require_command will be handled by dependencies.sh when extracted
    if ! command -v docker &>/dev/null; then
        die_with_dependency_error "docker" "sudo apt install docker.io && sudo systemctl start docker"
    fi
    
    log_debug "Checking Docker daemon status..."
    if ! docker info &>/dev/null; then
        die_with_context \
            "Docker daemon is not running or not accessible" \
            "Start Docker with: sudo systemctl start docker" \
            "$EXIT_MISSING_DEPS"
    fi
    log_debug "✓ Docker daemon is accessible"
}

# Validate external services and their connectivity
# Validate external service dependencies (network and critical commands)
validate_external_dependencies() {
    log_validation_start "external service dependencies"
    
    # Test Docker daemon
    if command -v docker &>/dev/null; then
        if ! docker info &>/dev/null; then
            die_with_context \
                "Docker daemon is not running or not accessible" \
                "Start Docker with: sudo systemctl start docker" \
                "$EXIT_MISSING_DEPS"
        fi
        log_debug "✓ Docker daemon is accessible"
    fi
    
    # Test internet connectivity for Ubuntu package downloads
    if ! run_cmd_read curl -s --connect-timeout 5 "https://archive.ubuntu.com" >/dev/null 2>&1; then
        log_warn "⚠️  Cannot reach Ubuntu package servers - some operations may fail"
        log_info "💡 Check internet connectivity or configure proxy settings"
    else
        log_debug "✓ Ubuntu package servers accessible"
    fi
    
    # Test Launchpad API for version resolution
    if ! run_cmd_read curl -s --connect-timeout 5 "https://api.launchpad.net/1.0/ubuntu" >/dev/null 2>&1; then
        log_warn "⚠️  Cannot reach Launchpad API - Ubuntu version auto-detection may fail"
    else
        log_debug "✓ Launchpad API accessible"
    fi
    
    log_validation_end "external service dependencies"
}

# Validate file system permissions and space
validate_filesystem_requirements() {
    log_validation_start "filesystem requirements"
    
    # Check mount base directory
    if [[ ! -d "$DEFAULT_MOUNT_BASE" ]]; then
        log_info "Creating mount base directory: $DEFAULT_MOUNT_BASE"
        if ! mkdir -p "$DEFAULT_MOUNT_BASE" 2>/dev/null; then
            die_with_permission_error "creating mount base directory: $DEFAULT_MOUNT_BASE"
        fi
    fi
    
    if [[ ! -w "$DEFAULT_MOUNT_BASE" ]]; then
        die_with_permission_error "writing to mount base directory: $DEFAULT_MOUNT_BASE"
    fi

    # Check status directory
    if [[ ! -d "$STATUS_DIR" ]]; then
        if ! mkdir -p "$STATUS_DIR" 2>/dev/null; then
            die_with_permission_error "creating status directory: $STATUS_DIR"
        fi
    fi
    
    log_validation_end "filesystem requirements"
}

# ==============================================================================
# CONFIGURATION VALIDATION
# ==============================================================================

# Validate configuration values on startup with comprehensive checks
validate_global_config() {
    log_validation_start "global configuration"
    
    # Check required variables are set
    local required_vars=(
        "DEFAULT_POOL_NAME"
        "DEFAULT_ROOT_DATASET"
        "DEFAULT_MOUNT_BASE"
        "STATUS_DIR"
        "DEFAULT_DISTRIBUTION"
        "DEFAULT_ARCH"
    )
    
    for var_name in "${required_vars[@]}"; do
        if [[ -z "${!var_name:-}" ]]; then
            die_with_context \
                "Required configuration variable '$var_name' not set" \
                "Check your global.conf file: $GLOBAL_CONFIG_FILE" \
                "$EXIT_CONFIG_ERROR"
        fi
        log_debug "✓ Config: $var_name=${!var_name}"
    done
    
    # Validate ZFS pool exists and is healthy
    check_zfs_pool "$DEFAULT_POOL_NAME"
    
    # Validate filesystem requirements
    validate_filesystem_requirements
    
    # Validate external dependencies
    validate_external_dependencies
    
    log_validation_end "global configuration"
}

# --- Finalization ---
log_debug "Validation library initialized."
