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

update_zfsbootmenu() {
    echo "📦 Building ZFSBootMenu checksum database..."
    
    local repo="zbm-dev/zfsbootmenu"
    local temp_dir
    temp_dir=$(mktemp -d)
    local zbm_vendor_dir="$VENDOR_DIR/zfsbootmenu"
    local db_file="$zbm_vendor_dir/checksums.txt"
    
    # Create ZFSBootMenu vendor directory
    mkdir -p "$zbm_vendor_dir"
    
    log_info "Creating checksum database for version detection..."
    
    # Create checksum database header
    cat > "$db_file" << EOF
# ZFSBootMenu SHA256 -> version index
# Generated on: $(date +%Y-%m-%d)
# Format: <sha256> <version> <filename>
# This database allows determination of installed ZFSBootMenu version by checksum matching
EOF
    
    # Get list of all release tags (limit to recent releases for initial build)
    log_info "Fetching release list from GitHub..."
    local releases
    if ! releases=$(curl -s "https://api.github.com/repos/$repo/releases?per_page=15" | grep '"tag_name"' | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/'); then
        log_error "Failed to fetch release list"
        rm -rf "$temp_dir"
        return 1
    fi
    
    local processed=0
    local total
    total=$(echo "$releases" | wc -l)
    
    log_info "Processing $total releases..."
    
    for version in $releases; do
        processed=$((processed + 1))
        echo -n "[$processed/$total] Processing $version... "
        
        local sha_url="https://github.com/$repo/releases/download/$version/sha256.txt"
        local sha_file="$temp_dir/$version.sha256.txt"
        
        if curl -fsL "$sha_url" -o "$sha_file" 2>/dev/null; then
            # Parse the sha256.txt file and add to database
            if [[ -s "$sha_file" ]]; then
                # Format in GitHub releases: SHA256 (filename) = hash
                # Convert to: hash version filename
                sed -n 's/^SHA256 (\([^)]*\)) = \([a-f0-9]*\)/\2 '"$version"' \1/p' "$sha_file" >> "$db_file"
                echo "✓"
            else
                echo "empty"
                echo "# Empty checksum file for $version" >> "$db_file"
            fi
        else
            echo "no checksums"
            echo "# No checksum file for $version" >> "$db_file"
        fi
    done
    
    # Get latest version for metadata
    local latest_version
    latest_version=$(echo "$releases" | head -1 | sed 's/^v//')
    
    # Create version file with latest version
    echo "$latest_version" > "$zbm_vendor_dir/VERSION"
    
    # Create README explaining the checksum database
    cat > "$zbm_vendor_dir/README.md" << EOF
# ZFSBootMenu Checksum Database

This directory contains a checksum database for ZFSBootMenu version detection.

- **Latest Version**: $latest_version
- **Source**: https://github.com/zbm-dev/zfsbootmenu
- **Database Generated**: $(date +%Y-%m-%d)

## Purpose

The checksum database (\`checksums.txt\`) allows reliable detection of installed 
ZFSBootMenu versions by matching SHA256 checksums of EFI files against known 
release checksums.

## Database Format

\`\`\`
# Comments start with #
<sha256> <version> <filename>
\`\`\`

Example:
\`\`\`
a1b2c3d4... v3.0.1 vmlinuz-bootmenu
e5f6g7h8... v3.0.1 initramfs-bootmenu.img
\`\`\`

## Usage in Scripts

\`\`\`bash
# Check installed version by checksum
if installed_version=\$(zfsbootmenu_get_version_by_checksum); then
    echo "Installed version: \$installed_version"
else
    echo "Version unknown"
fi
\`\`\`

## Updating the Database

To update with newer releases:

1. Run \`tools/update-vendor-deps.sh zfsbootmenu\`
2. The script will fetch checksums from all GitHub releases
3. Commit the updated checksums.txt file

## Files

- \`checksums.txt\` - Main checksum database
- \`VERSION\` - Latest available version
- \`README.md\` - This documentation
EOF
    
    # Update vendor README.md
    local current_date
    current_date=$(date +%Y-%m-%d)
    local checksum_count
    checksum_count=$(grep -c '^[a-f0-9]' "$db_file" 2>/dev/null || echo "0")
    
    # Check if ZFSBootMenu section exists in main vendor README
    if ! grep -q "## ZFSBootMenu" "$VENDOR_DIR/README.md"; then
        # Add ZFSBootMenu section
        cat >> "$VENDOR_DIR/README.md" << EOF

## ZFSBootMenu

- **Latest Version**: $latest_version
- **Source**: https://github.com/zbm-dev/zfsbootmenu
- **License**: MIT License
- **Purpose**: ZFSBootMenu version detection via checksum database
- **Last Updated**: $current_date
- **Checksum Entries**: $checksum_count

### Purpose

This contains a checksum database for reliable detection of installed ZFSBootMenu 
versions by matching EFI file checksums against known release checksums.

### Usage in Scripts

\`\`\`bash
# Load ZFSBootMenu library
source "\${PROJECT_ROOT}/lib/zfsbootmenu.sh"

# Check installed version
if installed_version=\$(zfsbootmenu_get_installed_version); then
    echo "Installed: \$installed_version"
fi
\`\`\`

### Updating

Run \`tools/update-vendor-deps.sh zfsbootmenu\` to update the checksum database.
EOF
    else
        # Update existing ZFSBootMenu section - use simpler approach to avoid sed issues
        local temp_readme
        temp_readme=$(mktemp)
        awk -v latest="$latest_version" -v date="$current_date" -v count="$checksum_count" '
        /^## ZFSBootMenu/ { in_section = 1 }
        /^## [A-Za-z]/ && !/^## ZFSBootMenu/ && in_section { in_section = 0 }
        in_section && /- \*\*Latest Version\*\*:/ { print "- **Latest Version**: " latest; next }
        in_section && /- \*\*Last Updated\*\*:/ { print "- **Last Updated**: " date; next }
        in_section && /- \*\*Checksum Entries\*\*:/ { print "- **Checksum Entries**: " count; next }
        { print }
        ' "$VENDOR_DIR/README.md" > "$temp_readme"
        mv "$temp_readme" "$VENDOR_DIR/README.md"
    fi
    
    # Cleanup
    rm -rf "$temp_dir"
    
    log_info "✅ ZFSBootMenu checksum database created with $checksum_count entries"
    log_info "Database: $db_file"
    log_warn "📝 Please test the checksum database and commit the changes if everything works correctly"
}

show_usage() {
    cat << EOF
Usage: $0 [OPTIONS] [DEPENDENCY]

Update vendored dependencies to their latest versions.

ARGUMENTS:
  DEPENDENCY              Specific dependency to update (shflags, zfsbootmenu)
                          If not specified, all dependencies are updated.

OPTIONS:
  --check-only           Only check versions, don't update
  -h, --help             Show this help message

EXAMPLES:
  $0                     # Update all dependencies
  $0 shflags             # Update only shflags
  $0 zfsbootmenu         # Update only ZFSBootMenu tools
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
        zfsbootmenu)
            update_zfsbootmenu
            ;;
        *)
            log_error "Unknown dependency: $SPECIFIC_DEP"
            log_error "Available dependencies: shflags, zfsbootmenu"
            exit 1
            ;;
    esac
else
    # Update all dependencies
    update_shflags
    update_zfsbootmenu
fi

echo ""
log_info "✅ Vendor dependency update completed"
log_warn "📝 Remember to:"
log_warn "   1. Test the updated dependencies"
log_warn "   2. Run the test suite: ./tools/bats.sh test/unit/"
log_warn "   3. Commit the changes if everything works"
