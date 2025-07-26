#!/bin/bash
#
# Ubuntu API Library
#
# This library provides functions for interacting with Ubuntu/Launchpad APIs
# to resolve distribution versions, codenames, and manage version lookups.
# It handles version/codename resolution and provides fallback mechanisms.

# --- Prevent multiple sourcing ---
if [[ "${__UBUNTU_API_LIB_LOADED:-}" == "true" ]]; then
    return 0
fi
readonly __UBUNTU_API_LIB_LOADED="true"

# Load logging library if not already loaded
if [[ "${__LOGGING_LIB_LOADED:-}" != "true" ]]; then
    # Determine library directory
    UBUNTU_API_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    source "$UBUNTU_API_LIB_DIR/logging.sh"
fi

# ==============================================================================
# DISTRIBUTION VERSION MANAGEMENT
# ==============================================================================

# --- Public Variables ---
# These will be populated by resolve_dist_info
DIST_VERSION=""
DIST_CODENAME=""

# ==============================================================================
# INTERNAL API FUNCTIONS
# ==============================================================================

# Function to get codename for a given Ubuntu version.
# Returns codename string or empty string if not found.
_get_ubuntu_codename_for_version() {
    local version="$1"
    local codename
    codename=$(curl -s "https://api.launchpad.net/1.0/ubuntu/series" 2>/dev/null | \
               jq -r ".entries[] | select(.version == \"$version\") | .name" 2>/dev/null)

    if [[ -n "$codename" && "$codename" != "null" ]]; then
        echo "$codename"
    fi
}

# Function to get version for a given Ubuntu codename.
# Returns version string or empty string if not found.
_get_ubuntu_version_for_codename() {
    local codename_in="$1"
    local version
    version=$(curl -s "https://api.launchpad.net/1.0/ubuntu/series" 2>/dev/null | \
               jq -r ".entries[] | select(.name == \"$codename_in\") | .version" 2>/dev/null)

    if [[ -n "$version" && "$version" != "null" ]]; then
        echo "$version"
    fi
}

# Function to get the latest Ubuntu version number.
# Tries several methods to find the most recent release.
_get_latest_ubuntu_version() {
    local version=""

    # Method 1: Ubuntu Cloud Images (most up-to-date for releases)
    version=$(curl -s "https://cloud-images.ubuntu.com/releases/" 2>/dev/null | \
              grep -o 'href="[0-9][0-9]\.[0-9][0-9]/' | \
              grep -o '[0-9][0-9]\.[0-9][0-9]' | \
              sort -V | tail -1)

    if [[ -n "$version" ]]; then
        echo "$version"
        return 0
    fi

    # Method 2: Launchpad API fallback (current stable release)
    version=$(curl -s "https://api.launchpad.net/1.0/ubuntu/series" 2>/dev/null | \
              jq -r '.entries[] | select(.status == "Current Stable Release") | .version' 2>/dev/null)

    if [[ -n "$version" && "$version" != "null" ]]; then
        echo "$version"
        return 0
    fi

    # Method 3: Latest supported version from Launchpad
    version=$(curl -s "https://api.launchpad.net/1.0/ubuntu/series" 2>/dev/null | \
              jq -r '.entries[] | select(.status == "Supported") | .version' 2>/dev/null | \
              sort -V | tail -1)

    if [[ -n "$version" && "$version" != "null" ]]; then
        echo "$version"
        return 0
    fi
}

# ==============================================================================
# PUBLIC API FUNCTIONS
# ==============================================================================

# Resolve distribution version and codename from user input.
# Populates global DIST_VERSION and DIST_CODENAME.
# Usage: resolve_dist_info "ubuntu" "24.04" ""
#        resolve_dist_info "ubuntu" "" "noble"
#        resolve_dist_info "debian" "12" "bookworm"
resolve_dist_info() {
    local dist="$1"
    local version_in="$2"
    local codename_in="$3"

    log_debug "Resolving dist info for: dist='$dist', version='$version_in', codename='$codename_in'"

    if [[ "$dist" != "${DISTRO_UBUNTU:-ubuntu}" ]]; then
        # For non-ubuntu distributions, we can't do lookups yet.
        # Require both version and codename.
        if [[ -z "$version_in" || -z "$codename_in" ]]; then
            die "For distribution '$dist', both --version and --codename must be provided."
        fi
        DIST_VERSION="$version_in"
        DIST_CODENAME="$codename_in"
        log_info "Using custom distribution: $dist $DIST_VERSION ($DIST_CODENAME)"
        return 0
    fi

    # It's Ubuntu, let's resolve dynamically.
    # Check for required commands (without loading dependencies.sh to avoid circular deps)
    if ! command -v curl &>/dev/null; then
        die_with_dependency_error "curl" "sudo apt install curl"
    fi
    if ! command -v jq &>/dev/null; then
        die_with_dependency_error "jq" "sudo apt install jq"
    fi

    if [[ -z "$version_in" && -z "$codename_in" ]]; then
        # Neither provided, get the latest version and its codename
        log_info "No version or codename specified, attempting to find latest Ubuntu release..."
        DIST_VERSION=$(_get_latest_ubuntu_version)
        if [[ -z "$DIST_VERSION" ]]; then
            die "Could not determine the latest Ubuntu version."
        fi
        DIST_CODENAME=$(_get_ubuntu_codename_for_version "$DIST_VERSION")
        if [[ -z "$DIST_CODENAME" ]]; then
            die "Could not determine codename for latest Ubuntu version '$DIST_VERSION'."
        fi

    elif [[ -n "$version_in" && -z "$codename_in" ]]; then
        # Version provided, find codename
        DIST_VERSION="$version_in"
        DIST_CODENAME=$(_get_ubuntu_codename_for_version "$DIST_VERSION")
        if [[ -z "$DIST_CODENAME" ]]; then
            die "Could not find a matching codename for Ubuntu version '$DIST_VERSION'."
        fi

    elif [[ -z "$version_in" && -n "$codename_in" ]]; then
        # Codename provided, find version
        DIST_CODENAME="$codename_in"
        DIST_VERSION=$(_get_ubuntu_version_for_codename "$DIST_CODENAME")
        if [[ -z "$DIST_VERSION" ]]; then
            die "Could not find a matching version for Ubuntu codename '$DIST_CODENAME'."
        fi

    elif [[ -n "$version_in" && -n "$codename_in" ]]; then
        # Both provided, validate they match
        local validation_codename
        validation_codename=$(_get_ubuntu_codename_for_version "$version_in")
        if [[ "$validation_codename" != "$codename_in" ]]; then
            die "Mismatch for Ubuntu: Version '$version_in' does not correspond to codename '$codename_in'. Found '$validation_codename'."
        fi
        DIST_VERSION="$version_in"
        DIST_CODENAME="$codename_in"
    else
        # This case should not be reached if called from main scripts with arg parsing
        die "For Ubuntu, please provide either --version or --codename."
    fi

    # Final check
    if [[ -z "$DIST_VERSION" || -z "$DIST_CODENAME" ]]; then
        die "Could not resolve version/codename for $dist. Input: version='$version_in', codename='$codename_in'."
    fi

    log_info "Resolved to: $dist $DIST_VERSION ($DIST_CODENAME)"
}

# Get default Ubuntu codename (used by multiple scripts)
get_default_ubuntu_codename() {
    local version
    version=$(_get_latest_ubuntu_version)
    if [[ -n "$version" ]]; then
        _get_ubuntu_codename_for_version "$version"
    else
        echo "plucky"  # Fallback to current development release
    fi
}

# --- Finalization ---
log_debug "Ubuntu API library initialized."
