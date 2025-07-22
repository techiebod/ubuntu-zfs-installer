#!/bin/bash

# Script to get Ubuntu release version and codename information
# Usage: ./get-ubuntu-version.sh [OPTIONS] [VERSION]
# 
# This script can:
# - Get the latest Ubuntu version (default)
# - Get the codename for the latest version (--codename)
# - Get the codename for a specific version (--codename VERSION)
# - Validate a version exists (--validate VERSION)

set -euo pipefail

# Source common library
script_dir="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
source "$script_dir/../lib/common.sh"

# Function to get codename for a given version
get_codename() {
    local version="$1"
    
    # Use Launchpad API with jq to get codename
    local codename
    codename=$(curl -s "https://api.launchpad.net/1.0/ubuntu/series" 2>/dev/null | \
               jq -r ".entries[] | select(.version == \"$version\") | .name" 2>/dev/null)
    
    if [[ -n "$codename" && "$codename" != "null" ]]; then
        echo "$codename"
        return 0
    fi
    
    # If codename lookup fails, return empty
    echo ""
    return 1
}

# Function to get latest Ubuntu version
get_latest_ubuntu() {
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
    
    # If all methods fail
    echo "Error: Could not determine latest Ubuntu version" >&2
    return 1
}

# Function to validate if a version exists
validate_version() {
    local version="$1"
    local codename
    codename=$(get_codename "$version")
    
    if [[ -n "$codename" ]]; then
        return 0
    else
        return 1
    fi
}

# Function to show usage
show_usage() {
    cat << EOF
Usage: $0 [OPTIONS] [VERSION]

Get Ubuntu release version and codename information.

OPTIONS:
    --codename, -c          Show codename instead of version number
    --validate, -v          Validate that a version exists (use with VERSION)
    --help, -h              Show this help message

VERSION:
    Specific Ubuntu version (e.g., 24.04, 25.04)
    If not provided, returns information about the latest release

EXAMPLES:
    # Get latest Ubuntu version
    $0

    # Get latest Ubuntu codename
    $0 --codename

    # Get codename for specific version
    $0 --codename 24.04

    # Validate a version exists
    $0 --validate 24.04

    # Check if specific version exists (exit code 0=exists, 1=not found)
    if $0 --validate 24.04; then
        echo "Ubuntu 24.04 exists"
    fi

EXIT CODES:
    0  Success
    1  Version not found or network error
    2  Invalid arguments

DEPENDENCIES:
    - curl (for API access)
    - jq (for JSON parsing) - install with: apt install jq
EOF
}

# Main script logic
main() {
    local show_codename=false
    local validate_mode=false
    local target_version=""
    
    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --codename|-c)
                show_codename=true
                shift
                ;;
            --validate|-v)
                validate_mode=true
                shift
                ;;
            --help|-h)
                show_usage
                exit 0
                ;;
            -*)
                echo "Error: Unknown option '$1'" >&2
                echo "Use --help for usage information" >&2
                exit 2
                ;;
            *)
                if [[ -z "$target_version" ]]; then
                    target_version="$1"
                else
                    echo "Error: Multiple versions specified" >&2
                    exit 2
                fi
                shift
                ;;
        esac
    done
    
    # Check for required dependencies
    if ! command -v curl >/dev/null 2>&1; then
        echo "Error: curl is required but not installed" >&2
        exit 1
    fi
    
    if ! command -v jq >/dev/null 2>&1; then
        echo "Error: jq is required but not installed" >&2
        echo "Install with: apt install jq" >&2
        exit 1
    fi
    
    # Determine target version
    if [[ -z "$target_version" ]]; then
        # No version specified, get latest
        target_version=$(get_latest_ubuntu)
        if [[ $? -ne 0 ]]; then
            exit 1
        fi
    fi
    
    # Handle validation mode
    if [[ "$validate_mode" == true ]]; then
        if validate_version "$target_version"; then
            exit 0
        else
            echo "Error: Ubuntu version $target_version not found" >&2
            exit 1
        fi
    fi
    
    # Handle output based on mode
    if [[ "$show_codename" == true ]]; then
        local codename
        codename=$(get_codename "$target_version")
        if [[ -n "$codename" ]]; then
            echo "$codename"
        else
            echo "Error: Could not get codename for Ubuntu $target_version" >&2
            exit 1
        fi
    else
        echo "$target_version"
    fi
}

# Run main function with all arguments
main "$@"
