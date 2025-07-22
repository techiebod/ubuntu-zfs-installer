#!/bin/bash

# Common library for Ubuntu ZFS Installer scripts
# This file should be sourced by other scripts using:
# source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

#!/bin/bash

# Common library for Ubuntu ZFS Installer scripts
# This file should be sourced by other scripts using:
# source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

# Ensure this file is only sourced once
if [[ "${_COMMON_SH_LOADED:-}" == "1" ]]; then
    return 0
fi
_COMMON_SH_LOADED=1

# ==============================================================================
# GLOBAL DEFAULT VARIABLES
# ==============================================================================

# Global default variables - can be overridden by scripts
DEFAULT_DISTRIBUTION="ubuntu"
DEFAULT_ARCH="amd64"
DEFAULT_POOL_NAME="zroot"
DEFAULT_MOUNT_BASE="/var/tmp/zfs-builds"
DEFAULT_VARIANT="minbase"
DEFAULT_DOCKER_IMAGE="ubuntu:latest"

# Global flags (initialized to false, set by argument parsing)
VERBOSE=false
DRY_RUN=false

# Distribution-specific defaults
declare -A DIST_MIRRORS=(
    ["ubuntu"]="http://archive.ubuntu.com/ubuntu"
    ["debian"]="http://deb.debian.org/debian"
)

declare -A DIST_KEYRINGS=(
    ["ubuntu"]="ubuntu-archive-keyring"
    ["debian"]="debian-archive-keyring"
)

# ==============================================================================
# LOGGING FUNCTIONS
# ==============================================================================

# Standard logging function
log() {
    echo "$*" >&2
}

# Error logging with ERROR prefix
log_error() {
    echo "ERROR: $*" >&2
}

# Warning logging with WARNING prefix
log_warning() {
    echo "WARNING: $*" >&2
}

# Info logging for important messages
log_info() {
    echo "INFO: $*" >&2
}

# Debug logging (only shown if DEBUG=true)
log_debug() {
    if [[ "${DEBUG:-false}" == "true" ]]; then
        echo "DEBUG: $*" >&2
    fi
}

# ==============================================================================
# COMMAND EXECUTION FUNCTIONS
# ==============================================================================

# Execute commands with optional verbose and dry-run support
# Uses global variables: VERBOSE, DRY_RUN
run_cmd() {
    if [[ "${VERBOSE:-false}" == "true" ]]; then
        log "Running: $*"
    fi
    
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        echo "DRY-RUN: $*"
        return 0
    fi
    
    "$@"
}

# Execute commands with verbose output (always shows command)
run_cmd_verbose() {
    log "Running: $*"
    
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        echo "DRY-RUN: $*"
        return 0
    fi
    
    "$@"
}

# ==============================================================================
# ERROR HANDLING FUNCTIONS
# ==============================================================================

# Exit with error message
die() {
    log_error "$*"
    exit 1
}

# Require argument to be non-empty
require_arg() {
    local value="$1"
    local message="$2"
    
    if [[ -z "$value" ]]; then
        die "$message"
    fi
}

# Check if command exists
require_command() {
    local cmd="$1"
    local message="${2:-Command '$cmd' is not installed or not in PATH}"
    
    if ! command -v "$cmd" >/dev/null 2>&1; then
        die "$message"
    fi
}

# ==============================================================================
# DISTRIBUTION VERSION/CODENAME MAPPING
# ==============================================================================

# Global variables for derived distribution info
DERIVED_VERSION=""
DERIVED_CODENAME=""

# Validate and derive distribution information
# Sets global variables: DERIVED_VERSION, DERIVED_CODENAME
# Arguments: distribution version codename
validate_distribution_info() {
    local distribution="$1"
    local version="$2"
    local codename="$3"
    
    # Clear previous values
    DERIVED_VERSION=""
    DERIVED_CODENAME=""
    
    # Derive missing version or codename based on distribution
    case "$distribution" in
        ubuntu)
            if [[ -n "$version" ]] && [[ -z "$codename" ]]; then
                # Derive codename from version
                case "$version" in
                    25.04) DERIVED_CODENAME="plucky" ;;
                    24.10) DERIVED_CODENAME="oracular" ;;
                    24.04) DERIVED_CODENAME="noble" ;;
                    23.10) DERIVED_CODENAME="mantic" ;;
                    23.04) DERIVED_CODENAME="lunar" ;;
                    22.04) DERIVED_CODENAME="jammy" ;;
                    20.04) DERIVED_CODENAME="focal" ;;
                    *) log_warning "Unknown Ubuntu version '$version', please specify --codename manually" ;;
                esac
                DERIVED_VERSION="$version"
            elif [[ -n "$codename" ]] && [[ -z "$version" ]]; then
                # Derive version from codename
                case "$codename" in
                    plucky) DERIVED_VERSION="25.04" ;;
                    oracular) DERIVED_VERSION="24.10" ;;
                    noble) DERIVED_VERSION="24.04" ;;
                    mantic) DERIVED_VERSION="23.10" ;;
                    lunar) DERIVED_VERSION="23.04" ;;
                    jammy) DERIVED_VERSION="22.04" ;;
                    focal) DERIVED_VERSION="20.04" ;;
                    *) log_warning "Unknown Ubuntu codename '$codename', please specify --version manually" ;;
                esac
                DERIVED_CODENAME="$codename"
            else
                # Both provided or both empty
                DERIVED_VERSION="$version"
                DERIVED_CODENAME="$codename"
            fi
            ;;
        debian)
            if [[ -n "$version" ]] && [[ -z "$codename" ]]; then
                # Derive codename from version
                case "$version" in
                    13) DERIVED_CODENAME="trixie" ;;
                    12) DERIVED_CODENAME="bookworm" ;;
                    11) DERIVED_CODENAME="bullseye" ;;
                    10) DERIVED_CODENAME="buster" ;;
                    *) log_warning "Unknown Debian version '$version', please specify --codename manually" ;;
                esac
                DERIVED_VERSION="$version"
            elif [[ -n "$codename" ]] && [[ -z "$version" ]]; then
                # Derive version from codename
                case "$codename" in
                    trixie) DERIVED_VERSION="13" ;;
                    bookworm) DERIVED_VERSION="12" ;;
                    bullseye) DERIVED_VERSION="11" ;;
                    buster) DERIVED_VERSION="10" ;;
                    *) log_warning "Unknown Debian codename '$codename', please specify --version manually" ;;
                esac
                DERIVED_CODENAME="$codename"
            else
                # Both provided or both empty
                DERIVED_VERSION="$version"
                DERIVED_CODENAME="$codename"
            fi
            ;;
        *)
            # For other distributions, both must be provided explicitly
            DERIVED_VERSION="$version"
            DERIVED_CODENAME="$codename"
            ;;
    esac
    
    # Final validation that we have both
    if [[ -z "$DERIVED_VERSION" ]] || [[ -z "$DERIVED_CODENAME" ]]; then
        if [[ "$distribution" == "ubuntu" ]] || [[ "$distribution" == "debian" ]]; then
            die "Could not determine both version and codename for $distribution. Please specify both --version and --codename explicitly"
        else
            die "For distribution '$distribution', both --version and --codename must be specified"
        fi
    fi
    
    # Warn if using a very new Ubuntu release that might not have stable keys
    if [[ "$distribution" == "ubuntu" ]] && [[ "$DERIVED_VERSION" > "24.10" ]]; then
        log_warning "Using very new Ubuntu release $DERIVED_VERSION"
        log_warning "If you encounter GPG key issues, try using --version 24.04 for the latest LTS"
    fi
    
    log_info "Using $distribution $DERIVED_VERSION ($DERIVED_CODENAME)"
}

# ==============================================================================
# COMMON ARGUMENT PARSING HELPERS
# ==============================================================================

# Parse common arguments that many scripts share
# Arguments: $@ (all script arguments)
# Sets global variables: VERBOSE, DRY_RUN, HELP_REQUESTED
parse_common_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -v|--verbose)
                VERBOSE=true
                shift
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --debug)
                DEBUG=true
                shift
                ;;
            -h|--help)
                HELP_REQUESTED=true
                return 0
                ;;
            *)
                # Return remaining arguments for script-specific parsing
                return 0
                ;;
        esac
    done
}

# ==============================================================================
# ZFS HELPER FUNCTIONS
# ==============================================================================

# Check if ZFS pool exists
check_zfs_pool() {
    local pool="$1"
    
    require_command "zpool" "ZFS is not installed or not available"
    
    if ! zpool list "$pool" >/dev/null 2>&1; then
        log_error "ZFS pool '$pool' does not exist"
        log_info "Available pools:"
        zpool list -H -o name | sed 's/^/  /' >&2
        exit 1
    fi
}

# ==============================================================================
# DOCKER HELPER FUNCTIONS
# ==============================================================================

# Check if Docker is available and running
check_docker() {
    require_command "docker" "Docker is not installed or not in PATH"
    
    if ! docker info >/dev/null 2>&1; then
        die "Docker is not running or not accessible. Make sure Docker is running and you have permission to use it"
    fi
}

# ==============================================================================
# VALIDATION FUNCTIONS
# ==============================================================================

# Validate codename format (must be alphanumeric lowercase)
validate_codename_format() {
    local codename="$1"
    require_arg "$codename" "codename"
    
    if [[ ! "$codename" =~ ^[a-z][a-z0-9]*$ ]]; then
        die "Invalid codename format: '$codename'. Must be lowercase alphanumeric starting with a letter"
    fi
}

# Validate Ubuntu codename using online API
validate_ubuntu_codename() {
    local codename="$1"
    require_arg "$codename" "codename"
    
    # First check format
    validate_codename_format "$codename"
    
    # Check if get-ubuntu-version.sh exists and use it for online validation
    local script_dir="$(dirname "${BASH_SOURCE[0]}")"
    local get_ubuntu_script="$script_dir/../scripts/get-ubuntu-version.sh"
    
    if [[ -x "$get_ubuntu_script" ]]; then
        log_debug "Validating Ubuntu codename '$codename' using online API"
        
        # Strategy: Use existing validate_distribution_info to derive version from codename
        # Then validate that version online
        local orig_derived_version="$DERIVED_VERSION"
        local orig_derived_codename="$DERIVED_CODENAME"
        
        # Try to derive version from codename using existing function
        validate_distribution_info "ubuntu" "" "$codename" 2>/dev/null || true
        
        if [[ -n "$DERIVED_VERSION" ]]; then
            log_debug "Derived version '$DERIVED_VERSION' from codename '$codename'"
            if "$get_ubuntu_script" --validate "$DERIVED_VERSION" >/dev/null 2>&1; then
                log_debug "Ubuntu codename '$codename' validated via version '$DERIVED_VERSION' using online API"
                # Restore original derived values
                DERIVED_VERSION="$orig_derived_version"
                DERIVED_CODENAME="$orig_derived_codename"
                return 0
            else
                # Restore original derived values
                DERIVED_VERSION="$orig_derived_version"
                DERIVED_CODENAME="$orig_derived_codename"
                die "Ubuntu codename '$codename' maps to version '$DERIVED_VERSION', but that version is not found in official Ubuntu releases"
            fi
        else
            # Restore original derived values
            DERIVED_VERSION="$orig_derived_version"
            DERIVED_CODENAME="$orig_derived_codename"
            die "Ubuntu codename '$codename' is not recognized in our version mapping. May be too new or invalid"
        fi
    else
        log_warning "Online validation script not found at: $get_ubuntu_script"
        log_warning "Using fallback validation (format only)"
        # Fallback to basic format validation only
        validate_codename_format "$codename"
    fi
}

# Generic distribution codename validation
validate_distribution_codename() {
    local distribution="$1"
    local codename="$2"
    require_arg "$distribution" "distribution"
    require_arg "$codename" "codename"
    
    case "$distribution" in
        ubuntu)
            validate_ubuntu_codename "$codename"
            ;;
        debian)
            # For now, just validate format - could add Debian API validation later
            validate_codename_format "$codename"
            log_debug "Debian codename '$codename' validated (format only - online validation not yet implemented)"
            ;;
        *)
            # For other distributions, just validate format
            validate_codename_format "$codename"
            log_debug "Distribution '$distribution' codename '$codename' validated (format only)"
            ;;
    esac
}

# ==============================================================================
# INITIALIZATION
# ==============================================================================

# Initialize common variables if not already set
VERBOSE="${VERBOSE:-false}"
DRY_RUN="${DRY_RUN:-false}"
DEBUG="${DEBUG:-false}"
HELP_REQUESTED="${HELP_REQUESTED:-false}"

# Log that common library is loaded
log_debug "Common library loaded"
