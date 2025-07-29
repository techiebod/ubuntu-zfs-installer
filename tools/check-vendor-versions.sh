#!/bin/bash
#
# Vendor Dependency Version Checker
#
# This script checks if our vendored dependencies are up-to-date
# with their upstream repositories.

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR_DIR="$PROJECT_ROOT/lib/vendor"
EXIT_CODE=0

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}ℹ️  $1${NC}"
}

log_warn() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

log_error() {
    echo -e "${RED}❌ $1${NC}"
    EXIT_CODE=1
}

check_shflags_version() {
    echo "🔍 Checking shflags version..."
    
    # Extract current version from vendor README
    local current_version
    current_version=$(grep "Version.*:" "$VENDOR_DIR/README.md" | head -1 | sed 's/.*Version.*: *\([^*]*\).*/\1/' | tr -d ' ')
    
    if [[ -z "$current_version" ]]; then
        log_error "Could not determine current shflags version from $VENDOR_DIR/README.md"
        return 1
    fi
    
    log_info "Current vendored version: $current_version"
    
    # Get latest version from GitHub API
    local latest_version
    latest_version=$(curl -s https://api.github.com/repos/kward/shflags/releases/latest | grep '"tag_name"' | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/' | sed 's/^v//')
    
    if [[ -z "$latest_version" ]]; then
        log_error "Could not fetch latest shflags version from GitHub API"
        return 1
    fi
    
    log_info "Latest upstream version: $latest_version"
    
    # Compare versions (simple string comparison for now)
    if [[ "$current_version" == "$latest_version" ]]; then
        log_info "✅ shflags is up-to-date"
        return 0
    else
        log_warn "📦 shflags version mismatch:"
        log_warn "   Current: $current_version"
        log_warn "   Latest:  $latest_version"
        log_warn "   Consider updating with: ./tools/update-vendor-deps.sh"
        # This is a warning, not an error - we don't force immediate updates
        return 0
    fi
}

check_zfsbootmenu_version() {
    echo "🔍 Checking ZFSBootMenu version..."
    
    # Check if ZFSBootMenu vendor directory exists
    local zbm_vendor_dir="$VENDOR_DIR/zfsbootmenu"
    if [[ ! -d "$zbm_vendor_dir" ]]; then
        log_warn "ZFSBootMenu not found in vendor directory - run: ./tools/update-vendor-deps.sh zfsbootmenu"
        return 0
    fi
    
    # Extract current version from VERSION file or README
    local current_version
    if [[ -f "$zbm_vendor_dir/VERSION" ]]; then
        current_version=$(cat "$zbm_vendor_dir/VERSION" | tr -d ' \n')
    else
        # Try to extract from vendor README
        current_version=$(grep -A 10 "## ZFSBootMenu" "$VENDOR_DIR/README.md" | grep "Version.*:" | head -1 | sed 's/.*Version.*: *\([^*]*\).*/\1/' | tr -d ' ')
    fi
    
    if [[ -z "$current_version" ]]; then
        log_error "Could not determine current ZFSBootMenu version"
        return 1
    fi
    
    log_info "Current vendored version: $current_version"
    
    # Get latest version from GitHub API
    local latest_version
    latest_version=$(curl -s https://api.github.com/repos/zbm-dev/zfsbootmenu/releases/latest | grep '"tag_name"' | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/' | sed 's/^v//')
    
    if [[ -z "$latest_version" ]]; then
        log_error "Could not fetch latest ZFSBootMenu version from GitHub API"
        return 1
    fi
    
    log_info "Latest upstream version: $latest_version"
    
    # Compare versions (simple string comparison for now)
    if [[ "$current_version" == "$latest_version" ]]; then
        log_info "✅ ZFSBootMenu tools are up-to-date"
        return 0
    else
        log_warn "📦 ZFSBootMenu version mismatch:"
        log_warn "   Current: $current_version"
        log_warn "   Latest:  $latest_version"
        log_warn "   Consider updating with: ./tools/update-vendor-deps.sh zfsbootmenu"
        # This is a warning, not an error - we don't force immediate updates
        return 0
    fi
}

# Check that vendor directory exists
if [[ ! -d "$VENDOR_DIR" ]]; then
    log_error "Vendor directory not found: $VENDOR_DIR"
    exit 1
fi

# Check that shflags exists
if [[ ! -f "$VENDOR_DIR/shflags" ]]; then
    log_error "shflags not found: $VENDOR_DIR/shflags"
    exit 1
fi

echo "🔍 Checking vendor dependency versions..."
echo ""

# Check each vendored dependency
check_shflags_version
check_zfsbootmenu_version

echo ""
if [[ $EXIT_CODE -eq 0 ]]; then
    log_info "✅ All vendor dependency checks passed"
else
    log_error "❌ Some vendor dependency checks failed"
fi

exit $EXIT_CODE
