#!/bin/bash
#
# Simple bats testing wrapper using Docker
#
# Usage:
#   ./tools/bats.sh                    # Run all tests
#   ./tools/bats.sh test/unit/*.bats   # Run specific test files
#   ./tools/bats.sh --tap test/        # TAP output format
#

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BATS_IMAGE="bats/bats:latest"

# Parse bats options vs files
BATS_ARGS=()
FILES=()

for arg in "$@"; do
    if [[ "$arg" == --* ]]; then
        BATS_ARGS+=("$arg")
    else
        FILES+=("$arg")
    fi
done

# Default to all test files if none specified
if [[ ${#FILES[@]} -eq 0 ]]; then
    if [[ -d "$PROJECT_ROOT/test" ]]; then
        mapfile -t FILES < <(find "$PROJECT_ROOT/test" -name "*.bats" -type f | sort)
    else
        echo "No test directory found. Create test/*.bats files first."
        exit 1
    fi
fi

# Convert absolute paths to relative for Docker
RELATIVE_FILES=()
for file in "${FILES[@]}"; do
    RELATIVE_FILES+=("${file#$PROJECT_ROOT/}")
done

# Run bats via Docker
exec docker run --rm \
    -v "$PROJECT_ROOT:/workspace:ro" \
    -w "/workspace" \
    "$BATS_IMAGE" \
    "${BATS_ARGS[@]}" "${RELATIVE_FILES[@]}"
