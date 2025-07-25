#!/bin/bash
#
# Get Ubuntu package lists from official sources
#
# This script fetches package manifests from Ubuntu's official repositories
# and outputs a newline-delimited list of packages from specified seeds.

set -euo pipefail

# Global configuration
VERBOSE="false"

# Source common library
script_dir="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
# shellcheck source=../lib/common.sh
source "$script_dir/../lib/common.sh"

# Function to fetch Ubuntu package manifests from official sources
fetch_ubuntu_manifests() {
    local codename="$1"
    local arch="${2:-amd64}"
    shift 2
    local seeds=("$@")
    
    require_command "curl"
    
    [[ "$VERBOSE" == "true" ]] && log_info "Fetching Ubuntu $codename package manifests for $arch architecture..."
    
    # Ubuntu package seeds are hosted at ubuntu-archive-team.ubuntu.com
    local seed_base_url="https://ubuntu-archive-team.ubuntu.com/seeds/ubuntu.$codename"
    
    # Declare associative array to store package lists in memory
    declare -gA PACKAGE_LISTS
    
    local has_errors=false
    
    for seed_name in "${seeds[@]}"; do
        local url="$seed_base_url/$seed_name"
        
        [[ "$VERBOSE" == "true" ]] && log_info "Downloading from seed: $seed_name..."
        
        local seed_content
        if seed_content=$(curl -s -f "$url" 2>/dev/null); then
            [[ "$VERBOSE" == "true" ]] && log_info "Successfully downloaded $seed_name"
            PACKAGE_LISTS["$seed_name"]="$seed_content"
        else
            log_warn "Could not download seed from $url"
            log_info "Available seed files: https://ubuntu-archive-team.ubuntu.com/seeds/ubuntu.$codename/"
            has_errors=true
        fi
    done
    
    if [[ "$has_errors" == true ]]; then
        die "Failed to download one or more package seeds. Available seeds at: https://ubuntu-archive-team.ubuntu.com/seeds/ubuntu.$codename/"
    fi
    
    return 0
}

# Function to parse seed content and extract package lists
parse_seed_content() {
    [[ "$VERBOSE" == "true" ]] && log_info "Parsing seed content to extract package lists..."
    
    # Combine all packages from all seeds into one list
    local all_packages=""
    
    for seed_name in "${!PACKAGE_LISTS[@]}"; do
        local seed_content="${PACKAGE_LISTS[$seed_name]}"
        [[ -n "$seed_content" ]] || continue
        
        [[ "$VERBOSE" == "true" ]] && log_info "Processing $seed_name seed content..."
        
        # Extract packages from Ubuntu seed content with architecture filtering
        # Lines starting with ' * ' are required packages
        # Extract package lines - only lines starting with " * " are actual packages
        local seed_packages
        seed_packages=$(echo "$seed_content" | \
            grep -E '^( \* )' | \
            sed -e 's/^ \* //' \
                -e 's/ *#.*//' \
                -e 's/(.*)//g' \
                -e 's/!.*//g' | \
            while read -r line; do
                # Extract package name (first word)
                package=$(echo "$line" | awk '{print $1}')
                
                # Skip empty lines or non-package lines
                if [[ -z "$package" || "$package" =~ ^(Task-|Languages:|https:|feature:|This|Some|called|always|stay|-|\$) ]]; then
                    continue
                fi
                
                # Check for architecture qualifiers [arch1 arch2] or [!arch1 !arch2]
                if [[ "$line" =~ \[([^\]]+)\] ]]; then
                    arch_spec="${BASH_REMATCH[1]}"
                    include_package=false
                    exclude_package=false
                    has_positive_inclusion=false
                    
                    # Check each architecture in the spec
                    for arch_item in $arch_spec; do
                        if [[ "$arch_item" =~ ^! ]]; then
                            # Exclusion: !arch means exclude this arch
                            excluded_arch="${arch_item#!}"
                            if [[ "$excluded_arch" == "$arch" ]]; then
                                exclude_package=true
                                break
                            fi
                        else
                            # Inclusion: arch means include only this arch
                            has_positive_inclusion=true
                            if [[ "$arch_item" == "$arch" ]]; then
                                include_package=true
                            fi
                        fi
                    done
                    
                    # Apply filtering logic
                    if [[ "$exclude_package" == "true" ]]; then
                        continue
                    fi
                    
                    if [[ "$has_positive_inclusion" == "true" && "$include_package" == "false" ]]; then
                        continue
                    fi
                fi
                
                echo "$package"
            done | sort -u)
        
        all_packages="$all_packages$seed_packages"$'\n'
        
        local package_count=$(echo "$seed_packages" | wc -w)
        [[ "$VERBOSE" == "true" ]] && log_info "Extracted $package_count packages from $seed_name"
    done
    
    # Deduplicate and sort all packages
    declare -g FINAL_PACKAGES
    FINAL_PACKAGES=$(echo "$all_packages" | sort -u | grep -v '^[[:space:]]*$')
    
    local total_count=$(echo "$FINAL_PACKAGES" | wc -l)
    [[ "$VERBOSE" == "true" ]] && log_info "Total unique packages: $total_count"
    
    return 0
}

# Function to show usage
show_usage() {
    cat << EOF
Usage: $0 [OPTIONS] SEED [SEED...]

Fetch Ubuntu package lists from official sources and output a 
newline-delimited list of packages from the specified seeds.

OPTIONS:
    --codename CODENAME     Ubuntu release codename (e.g., noble, jammy).
                           If not provided, uses the current Ubuntu release.
    -a, --arch ARCH         Target architecture (default: from global config or amd64).
    --verbose               Enable verbose output with progress information.
    --help, -h              Show this help message.

ARGUMENTS:
    SEED [SEED...]         One or more seed names to fetch packages from.

EXAMPLES:
    # Get packages from server-minimal seed (uses current Ubuntu release)
    $0 server-minimal

    # Get packages from multiple seeds  
    $0 server-minimal server

    # Specify Ubuntu release codename
    $0 --codename noble server-minimal

    # Enable verbose output
    $0 --verbose --codename noble server-minimal

    # Generate for different architecture
    $0 --arch arm64 --codename noble server-minimal

    # Available seeds can be found at:
    # https://ubuntu-archive-team.ubuntu.com/seeds/ubuntu.CODENAME/

EXIT CODES:
    0  Success
    1  Error downloading or parsing manifests
    2  Invalid arguments
EOF
}

# Main function
main() {
    local codename=""
    local arch="${DEFAULT_ARCH:-amd64}"
    local seeds=()
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --codename) codename="$2"; shift 2 ;;
            -a|--arch) arch="$2"; shift 2 ;;
            --verbose) VERBOSE="true"; shift ;;
            -h|--help) show_usage; exit 0 ;;
            -*) die "Unknown option: $1" ;;
            *) 
                # Everything is a seed name
                seeds+=("$1")
                shift
                ;;
        esac
    done
    
    # Get default codename if not provided
    if [[ -z "$codename" ]]; then
        codename=$(get_default_ubuntu_codename 2>/dev/null || echo "plucky")
        [[ "$VERBOSE" == "true" ]] && log_info "Using default codename: $codename"
    fi
    
    # At least one seed must be specified
    if [[ ${#seeds[@]} -eq 0 ]]; then
        die "At least one seed name must be specified. Available seeds at: https://ubuntu-archive-team.ubuntu.com/seeds/ubuntu.$codename/"
    fi
    
    # Fetch manifests
    fetch_ubuntu_manifests "$codename" "$arch" "${seeds[@]}"
    
    # Parse seed content
    parse_seed_content
    
    # Output packages directly
    echo "$FINAL_PACKAGES"
}

# Run main function
main "$@"
