#!/bin/bash
#
# BATS test runner script using Docker
#

set -euo pipefail

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Docker image for bats
BATS_IMAGE="bats/bats:latest"

# Export PROJECT_ROOT for use in tests
export PROJECT_ROOT

# Run bats via Docker
exec docker run --rm \
    -v "$PROJECT_ROOT:/workspace:ro" \
    -w "/workspace" \
    -e PROJECT_ROOT="/workspace" \
    "$BATS_IMAGE" \
    "$@"
