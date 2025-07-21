#!/bin/bash

# Script to get the latest Ubuntu release version and optionally the codename
# Usage: ./ubuntu_latest.sh [--codename]

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

# Main script logic
main() {
    local show_codename=false
    
    # Parse command line arguments
    case "${1:-}" in
        --codename|-c)
            show_codename=true
            ;;
        --help|-h)
            echo "Usage: $0 [--codename]"
            echo "  --codename, -c    Show codename instead of version number"
            echo "  --help, -h        Show this help message"
            exit 0
            ;;
        "")
            # No arguments, show version
            ;;
        *)
            echo "Error: Unknown option '$1'" >&2
            echo "Use --help for usage information" >&2
            exit 1
            ;;
    esac
    
    # Get the latest version
    local latest_version
    latest_version=$(get_latest_ubuntu)
    
    if [[ $? -ne 0 ]]; then
        exit 1
    fi
    
    # Output result
    if [[ "$show_codename" == true ]]; then
        local codename
        codename=$(get_codename "$latest_version")
        if [[ -n "$codename" ]]; then
            echo "$codename"
        else
            echo "$latest_version (codename unknown)"
        fi
    else
        echo "$latest_version"
    fi
}

# Run main function with all arguments
main "$@"
