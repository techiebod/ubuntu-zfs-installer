#!/bin/bash

# Helper script to build different machines easily
# Usage: ./build-machine.sh [blackbox|babybox|pibox] [base_image_path]

set -euo pipefail

MACHINE="$1"
BASE_IMAGE_PATH="${2:-/mnt/ubuntu-base}"

# Validate machine name
case "$MACHINE" in
    blackbox|babybox|pibox)
        echo "Building $MACHINE in $BASE_IMAGE_PATH"
        ;;
    *)
        echo "ERROR: Invalid machine name '$MACHINE'"
        echo "Valid options: blackbox, babybox, pibox"
        exit 1
        ;;
esac

# Check if we're in the right directory
if [[ ! -f "configure-system.sh" ]]; then
    echo "ERROR: Must be run from the ansible/ directory"
    exit 1
fi

# Update hostname in user.env temporarily
USER_ENV="../config/user.env"
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

# Run the configuration
echo "Configuring $MACHINE..."
./configure-system.sh --limit "$MACHINE" --tags hostname,timezone,locale,base "$BASE_IMAGE_PATH"

echo "Successfully configured $MACHINE!"
echo "Image ready at: $BASE_IMAGE_PATH"
