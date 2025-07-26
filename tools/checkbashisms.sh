#!/bin/bash
#
# Bashisms checker with intelligent handling
#
# Since this project intentionally targets Bash 5+ (not POSIX shell), 
# this tool serves mainly to document which features are bashisms.
# We run it but expect many "bashisms" since we use them intentionally.
#
# Usage:
#   ./tools/checkbashisms.sh                     # Check all .sh files  
#   ./tools/checkbashisms.sh script.sh           # Check specific file
#   ./tools/checkbashisms.sh --extra script.sh   # Enable extra checks
#

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

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

echo "Checking ${#FILES[@]} shell scripts for bashisms..."
echo "Note: This project intentionally uses Bash 5+ features, so bashisms are expected."

# Convert absolute paths to relative for display
RELATIVE_FILES=()
for file in "${FILES[@]}"; do
    RELATIVE_FILES+=("${file#$PROJECT_ROOT/}")
done

# Try to use native checkbashisms if available
if command -v checkbashisms >/dev/null 2>&1; then
    echo "Using native checkbashisms installation"
    # Run but don't fail on bashisms since we use them intentionally
    if checkbashisms "${CHECKBASHISMS_ARGS[@]}" "${FILES[@]}" 2>&1; then
        echo "✅ No bashisms detected (or all expected)"
    else
        echo "ℹ️  Bashisms detected (expected for Bash 5+ project)"
        echo "✅ Check completed successfully"
    fi
else
    # For CI environments without checkbashisms, skip with explanation
    echo "ℹ️  checkbashisms not available in environment"
    echo "ℹ️  This project intentionally uses Bash 5+ features (bashisms)"
    echo "ℹ️  To run locally: apt-get install devscripts"
    echo "✅ Bashisms check skipped (not critical for Bash 5+ project)"
fi

# Always exit successfully since bashisms are intentional
exit 0
