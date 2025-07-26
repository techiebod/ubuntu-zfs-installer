#!/bin/bash
#
# Simple shellcheck wrapper using Docker
#
# Usage:
#   ./tools/shellcheck.sh                    # Check all .sh files
#   ./tools/shellcheck.sh script.sh          # Check specific file
#   ./tools/shellcheck.sh --severity=error   # Only show errors
#

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SHELLCHECK_IMAGE="koalaman/shellcheck:stable"

# Parse shellcheck options vs files
SHELLCHECK_ARGS=()
FILES=()

for arg in "$@"; do
    if [[ "$arg" == --* ]]; then
        SHELLCHECK_ARGS+=("$arg")
    else
        FILES+=("$arg")
    fi
done

# Default to all .sh files if none specified
if [[ ${#FILES[@]} -eq 0 ]]; then
    mapfile -t FILES < <(find "$PROJECT_ROOT" -name "*.sh" -type f | sort)
fi

# Convert absolute paths to relative for Docker
RELATIVE_FILES=()
for file in "${FILES[@]}"; do
    RELATIVE_FILES+=("${file#$PROJECT_ROOT/}")
done

# Default shellcheck options
DEFAULT_ARGS=(
    "--severity=warning"
    "--format=gcc"
    "--exclude=SC1090,SC1091"
)

# Run shellcheck via Docker
exec docker run --rm \
    -v "$PROJECT_ROOT:/workspace:ro" \
    -w "/workspace" \
    "$SHELLCHECK_IMAGE" \
    "${DEFAULT_ARGS[@]}" \
    "${SHELLCHECK_ARGS[@]}" \
    "${RELATIVE_FILES[@]}"
