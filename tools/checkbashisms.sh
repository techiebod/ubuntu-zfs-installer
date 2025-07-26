#!/bin/bash
#
# Simple checkbashisms wrapper using Docker
#
# Usage:
#   ./tools/checkbashisms.sh                     # Check all .sh files  
#   ./tools/checkbashisms.sh script.sh           # Check specific file
#   ./tools/checkbashisms.sh --extra script.sh   # Enable extra checks
#

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECKBASHISMS_IMAGE="manabu/checkbashisms-docker"

# Parse checkbashisms options vs files
CHECKBASHISMS_ARGS=()
FILES=()

for arg in "$@"; do
    if [[ "$arg" == --* ]]; then
        CHECKBASHISMS_ARGS+=("$arg")
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

# Run checkbashisms via Docker
exec docker run --rm \
    -v "$PROJECT_ROOT:/workspace:ro" \
    -w "/workspace" \
    "$CHECKBASHISMS_IMAGE" \
    checkbashisms "${CHECKBASHISMS_ARGS[@]}" "${RELATIVE_FILES[@]}"
