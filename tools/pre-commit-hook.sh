#!/bin/bash
#
# Pre-commit Git Hook Example
#
# Copy this file to .git/hooks/pre-commit and make it executable to automatically
# run quality checks before each commit.
#
# Installation:
#   cp tools/pre-commit-hook.sh .git/hooks/pre-commit
#   chmod +x .git/hooks/pre-commit

set -euo pipefail

# Configuration
readonly PROJECT_ROOT
PROJECT_ROOT="$(git rev-parse --show-toplevel)"
readonly CI_SCRIPT="$PROJECT_ROOT/tools/ci-local.sh"

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m' # No Color

echo -e "${YELLOW}Running pre-commit checks...${NC}"

# Check if CI script exists
if [[ ! -x "$CI_SCRIPT" ]]; then
    echo -e "${RED}Error: CI script not found or not executable: $CI_SCRIPT${NC}"
    echo "Pre-commit hook installation may be incomplete."
    exit 1
fi

# Run CI checks (extracts commands from GitHub Actions workflow)
if "$CI_SCRIPT"; then
    echo -e "${GREEN}✓ All pre-commit checks passed!${NC}"
    exit 0
else
    echo -e "${RED}✗ Pre-commit checks failed!${NC}"
    echo
    echo "To commit anyway, use: git commit --no-verify"
    echo "To fix issues and try again, run: $CI_SCRIPT"
    exit 1
fi
