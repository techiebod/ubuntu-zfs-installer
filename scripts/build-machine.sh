#!/bin/bash

# Helper script to build different machines easily
# Usage: ./build-machine.sh MACHINE [base_image_path]

set -euo pipefail

# Show usage if no arguments or help requested
if [[ $# -eq 0 ]] || [[ "$1" == "--help" ]] || [[ "$1" == "-h" ]]; then
    # Get script directory and find available machines from host_vars
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    host_vars_dir="$script_dir/../config/host_vars"
    
    # Get available machines from host_vars files
    available_machines=()
    if [[ -d "$host_vars_dir" ]]; then
        for host_file in "$host_vars_dir"/*.yml; do
            if [[ -f "$host_file" ]]; then
                machine=$(basename "$host_file" .yml)
                available_machines+=("$machine")
            fi
        done
    fi
    
    # Build dynamic examples
    machine_list=""
    example_basic=""
    example_custom1=""
    example_custom2=""
    
    for machine in "${available_machines[@]}"; do
        machine_list+="    $machine"$'\n'
        if [[ -z "$example_basic" ]]; then
            example_basic="$machine"
        elif [[ -z "$example_custom1" ]]; then
            example_custom1="$machine"
        elif [[ -z "$example_custom2" ]]; then
            example_custom2="$machine"
        fi
    done
    
    cat << EOF
Usage: $0 MACHINE [BASE_IMAGE_PATH]

Build and configure a specific machine with the correct hostname and packages.

AVAILABLE MACHINES:
$machine_list
ARGUMENTS:
    MACHINE           Machine to build (required)
    BASE_IMAGE_PATH   Where to create the image (default: /mnt/ubuntu-base)

EXAMPLES:
    $0 $example_basic                           # Build $example_basic in /mnt/ubuntu-base
    $0 $example_custom1 /mnt/$example_custom1-base   # Build $example_custom1 in custom location
    $0 $example_custom2 /mnt/$example_custom2-base   # Build $example_custom2 in custom location

This script:
1. Temporarily updates config/user.env with the correct hostname
2. Runs Ansible configuration in chroot context  
3. Restores original config/user.env
EOF
    exit 0
fi

MACHINE="$1"
BASE_IMAGE_PATH="${2:-/mnt/ubuntu-base}"

# Get script directory and check available machines
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
host_vars_dir="$script_dir/../config/host_vars"

# Build list of valid machines from host_vars
valid_machines=()
if [[ -d "$host_vars_dir" ]]; then
    for host_file in "$host_vars_dir"/*.yml; do
        if [[ -f "$host_file" ]]; then
            machine=$(basename "$host_file" .yml)
            valid_machines+=("$machine")
        fi
    done
fi

# Validate machine name against available host_vars
if [[ ! " ${valid_machines[*]} " =~ " $MACHINE " ]]; then
    echo "ERROR: Invalid machine name '$MACHINE'"
    echo "Available machines: ${valid_machines[*]}"
    echo "Use --help for more information"
    exit 1
fi

echo "Building $MACHINE in $BASE_IMAGE_PATH"

# Check if configure-system.sh exists
if [[ ! -f "$script_dir/configure-system.sh" ]]; then
    echo "ERROR: configure-system.sh not found in scripts directory"
    exit 1
fi

# Update hostname in user.env temporarily
USER_ENV="$script_dir/../config/user.env"
if [[ ! -f "$USER_ENV" ]]; then
    echo "ERROR: $USER_ENV not found"
    echo "Copy config/user.env.example to config/user.env and customize it"
    exit 1
fi

# Backup original user.env
cp "$USER_ENV" "$USER_ENV.backup"

# Update hostname for this machine
sed -i "s/^HOSTNAME=.*/HOSTNAME=$MACHINE/" "$USER_ENV"

echo "Updated hostname to $MACHINE in $USER_ENV"

# Function to restore on exit
cleanup() {
    echo "Restoring original user.env..."
    mv "$USER_ENV.backup" "$USER_ENV"
}
trap cleanup EXIT

# Run the configuration (essential setup by default)
echo "Configuring $MACHINE..."
"$script_dir/configure-system.sh" --limit "$MACHINE" "$BASE_IMAGE_PATH"

echo "Successfully configured $MACHINE!"
echo "Image ready at: $BASE_IMAGE_PATH"
