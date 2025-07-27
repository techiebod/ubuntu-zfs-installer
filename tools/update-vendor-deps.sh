#!/bin/bash
#
# Vendor Dependency Updater
#
# This script updates vendored dependencies to their latest versions.

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR_DIR="$PROJECT_ROOT/lib/vendor"

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
}

update_shflags() {
    echo "📦 Updating shflags..."
    
    # Get latest version info
    local latest_info
    latest_info=$(curl -s https://api.github.com/repos/kward/shflags/releases/latest)
    
    local latest_version
    latest_version=$(echo "$latest_info" | grep '"tag_name"' | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/' | sed 's/^v//')
    
    local tarball_url
    tarball_url=$(echo "$latest_info" | grep '"tarball_url"' | sed 's/.*"tarball_url": *"\([^"]*\)".*/\1/')
    
    if [[ -z "$latest_version" || -z "$tarball_url" ]]; then
        log_error "Could not fetch shflags release information"
        return 1
    fi
    
    log_info "Latest version: $latest_version"
    log_info "Downloading from: $tarball_url"
    
    # Create temporary directory
    local temp_dir
    temp_dir=$(mktemp -d)
    
    # Download and extract
    if ! curl -L "$tarball_url" | tar xz -C "$temp_dir" --strip-components=1; then
        log_error "Failed to download and extract shflags"
        rm -rf "$temp_dir"
        return 1
    fi
    
    # Copy the shflags script
    if [[ ! -f "$temp_dir/shflags" ]]; then
        log_error "shflags script not found in downloaded archive"
        rm -rf "$temp_dir"
        return 1
    fi
    
    # Backup existing version
    if [[ -f "$VENDOR_DIR/shflags" ]]; then
        cp "$VENDOR_DIR/shflags" "$VENDOR_DIR/shflags.backup"
        log_info "Backed up existing version to shflags.backup"
    fi
    
    # Copy new version
    cp "$temp_dir/shflags" "$VENDOR_DIR/shflags"
    
    # Update README.md
    local current_date
    current_date=$(date +%Y-%m-%d)
    
    # Update version and date in README
    sed -i "s/- \*\*Version\*\*: .*/- **Version**: $latest_version/" "$VENDOR_DIR/README.md"
    sed -i "s/- \*\*Last Updated\*\*: .*/- **Last Updated**: $current_date/" "$VENDOR_DIR/README.md"
    
    # Cleanup
    rm -rf "$temp_dir"
    
    log_info "✅ shflags updated to version $latest_version"
    log_warn "📝 Please test the update and commit the changes if everything works correctly"
}

show_usage() {
    cat << EOF
Usage: $0 [OPTIONS] [DEPENDENCY]

Update vendored dependencies to their latest versions.

ARGUMENTS:
  DEPENDENCY              Specific dependency to update (shflags)
                          If not specified, all dependencies are updated.

OPTIONS:
  --check-only           Only check versions, don't update
  -h, --help             Show this help message

EXAMPLES:
  $0                     # Update all dependencies
  $0 shflags             # Update only shflags
  $0 --check-only        # Check all versions without updating

EOF
}

# Parse arguments
CHECK_ONLY=false
SPECIFIC_DEP=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --check-only)
            CHECK_ONLY=true
            shift
            ;;
        -h|--help)
            show_usage
            exit 0
            ;;
        -*)
            log_error "Unknown option: $1"
            show_usage
            exit 1
            ;;
        *)
            if [[ -z "$SPECIFIC_DEP" ]]; then
                SPECIFIC_DEP="$1"
            else
                log_error "Only one dependency can be specified"
                exit 1
            fi
            shift
            ;;
    esac
done

# If check-only mode, run the version checker
if [[ "$CHECK_ONLY" == true ]]; then
    exec "$PROJECT_ROOT/tools/check-vendor-versions.sh"
fi

echo "📦 Updating vendor dependencies..."
echo ""

# Update specific dependency or all
if [[ -n "$SPECIFIC_DEP" ]]; then
    case "$SPECIFIC_DEP" in
        shflags)
            update_shflags
            ;;
        *)
            log_error "Unknown dependency: $SPECIFIC_DEP"
            log_error "Available dependencies: shflags"
            exit 1
            ;;
    esac
else
    # Update all dependencies
    update_shflags
fi

echo ""
log_info "✅ Vendor dependency update completed"
log_warn "📝 Remember to:"
log_warn "   1. Test the updated dependencies"
log_warn "   2. Run the test suite: ./tools/bats.sh test/unit/"
log_warn "   3. Commit the changes if everything works"
