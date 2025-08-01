#!/bin/bash
#
# Command-line wrapper to get Ubuntu release information.
#
# This script acts as a CLI for the distribution resolution functions
# in the modular libraries. It allows for standalone querying of Ubuntu
# version and codename information.

set -euo pipefail

# Source only the libraries we actually need (modular approach)
script_dir="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
lib_dir="$script_dir/../lib"

# Load the core library which sets up essential project structure and variables
source "$lib_dir/core.sh"

# Load only what we need - no heavy validation or ZFS libraries
source "$lib_dir/logging.sh"
source "$lib_dir/dependencies.sh"
source "$lib_dir/ubuntu-api.sh"

# Load shflags library
source "$lib_dir/vendor/shflags"

# --- Flag definitions ---
DEFINE_boolean 'codename' false 'Show codename instead of version number' 'c'
DEFINE_boolean 'version' false 'Show version number instead of codename' 'v'
DEFINE_boolean 'validate' false 'Validate that a version or codename exists'
DEFINE_boolean 'list_all' false 'List all available Ubuntu versions and codenames' 'l'

# This script defines functions that are not part of the core libraries
# as they are specific to the CLI wrapper (e.g. listing all versions).

# Function to list all Ubuntu versions from the Launchpad API
# This is kept separate from the common library as it's a specific
# feature of this CLI tool for user-facing output.
list_all_versions() {
    require_command "curl"
    require_command "jq"

    log_info "Fetching all available Ubuntu versions from Launchpad API..."

    # Get all versions from Launchpad API
    local versions
    versions=$(curl -s "https://api.launchpad.net/1.0/ubuntu/series" 2>/dev/null | \
               jq -r '.entries[] | "\(.version):\(.name):\(.status)"' 2>/dev/null | \
               sort -V)

    if [[ -z "$versions" ]]; then
        die "Could not retrieve Ubuntu versions from API."
    fi

    printf "%-10s %-15s %s\n" "VERSION" "CODENAME" "STATUS"
    printf "%-10s %-15s %s\n" "----------" "---------------" "------"

    while IFS=: read -r version codename status; do
        [[ -n "$version" ]] && printf "%-10s %-15s %s\n" "$version" "$codename" "$status"
    done <<< "$versions"

    echo
    log_info "Common statuses:"
    log_info "  Current Stable Release - Latest released version"
    log_info "  Supported              - Officially supported"
    log_info "  Active Development     - Under development"
    log_info "  Obsolete               - No longer supported"
}

# Function to show usage
show_usage() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS] [VERSION]

Command-line wrapper to get Ubuntu release information using the project's
common library.

[VERSION]:
    An optional specific Ubuntu version (e.g., 24.04) or codename (e.g., noble).
    If not provided, the script defaults to the latest stable release.

EOF
    flags_help
    cat << EOF

EXAMPLES:
    # Get latest Ubuntu version number
    $(basename "$0")
    $(basename "$0") --version

    # Get latest Ubuntu codename
    $(basename "$0") --codename

    # Get codename for a specific version
    $(basename "$0") --codename 24.04

    # Get version for a specific codename
    $(basename "$0") --version noble

    # Validate a version exists (returns exit code 0 if found)
    $(basename "$0") --validate 24.04

    # Validate a codename exists
    $(basename "$0") --validate noble

    # List all available versions
    $(basename "$0") --list-all

EXIT CODES:
    0  Success
    1  Not found, or network/dependency error
    2  Invalid arguments
EOF
}

# Main script logic
main() {
    # Override default logging to be quieter for CLI use
    _log() { echo "$2"; }
    log_info() { echo "$*"; }
    log_error() { echo "Error: $*" >&2; }
    log_warn() { echo "Warning: $*" >&2; }
    log_debug() { return 0; } # Disable debug logging for CLI

    # Parse flags
    FLAGS "$@" || exit 1
    eval set -- "${FLAGS_ARGV}"
    
    # Get target input (optional positional argument)
    local target_input=""
    if [[ $# -gt 0 ]]; then
        target_input="$1"
        shift
    fi
    
    if [[ $# -gt 0 ]]; then
        log_error "Multiple versions/codenames specified."
        exit 2
    fi

    # Convert shflags boolean values
    local mode="version" # Default mode
    local validate_mode
    local list_all
    local show_codename
    local show_version
    validate_mode=$([ "${FLAGS_validate}" -eq 0 ] && echo "true" || echo "false")
    list_all=$([ "${FLAGS_list_all}" -eq 0 ] && echo "true" || echo "false")
    show_codename=$([ "${FLAGS_codename}" -eq 0 ] && echo "true" || echo "false")
    show_version=$([ "${FLAGS_version}" -eq 0 ] && echo "true" || echo "false")
    
    # Determine mode
    if [[ "$show_codename" == "true" ]]; then
        mode="codename"
    elif [[ "$show_version" == "true" ]]; then
        mode="version"
    fi

    # Ensure curl and jq are available if we need them
    if [[ "$list_all" == "true" || "$validate_mode" == "true" || -n "$target_input" ]]; then
        require_command "curl"
        require_command "jq"
    fi

    # Handle --list-all mode
    if [[ "$list_all" == "true" ]]; then
        list_all_versions
        exit $?
    fi

    local result=""
    if [[ -z "$target_input" ]]; then
        # No target specified, get the latest
        result=$(_get_latest_ubuntu_version)
        if [[ -z "$result" ]]; then
            log_error "Could not determine the latest Ubuntu version."
            exit 1
        fi
        if [[ "$mode" == "codename" ]]; then
            result=$(_get_ubuntu_codename_for_version "$result")
        fi
    else
        # Target was specified, determine if it's a version or codename
        # We can cheat by checking if it contains a dot.
        if [[ "$target_input" == *.* ]]; then # Looks like a version
            if [[ "$validate_mode" == "true" ]]; then
                _get_ubuntu_codename_for_version "$target_input" >/dev/null || exit 1
                exit 0
            fi
            if [[ "$mode" == "version" ]]; then
                result="$target_input"
            else
                result=$(_get_ubuntu_codename_for_version "$target_input")
            fi
        else # Looks like a codename
            if [[ "$validate_mode" == "true" ]]; then
                _get_ubuntu_version_for_codename "$target_input" >/dev/null || exit 1
                exit 0
            fi
            if [[ "$mode" == "codename" ]]; then
                result="$target_input"
            else
                result=$(_get_ubuntu_version_for_codename "$target_input")
            fi
        fi
    fi

    if [[ -z "$result" ]]; then
        log_error "Could not resolve '$target_input'."
        exit 1
    fi

    echo "$result"
    exit 0
}

# Run main function with all arguments, but disable errexit for the main
# function to allow for more graceful error handling and custom exit codes.
set +o errexit
main "$@"
