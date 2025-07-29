# ZFSBootMenu Checksum Database

This directory contains a checksum database for ZFSBootMenu version detection.

- **Latest Version**: 3.0.1
- **Source**: https://github.com/zbm-dev/zfsbootmenu
- **Database Generated**: 2025-07-29

## Purpose

The checksum database (`checksums.txt`) allows reliable detection of installed 
ZFSBootMenu versions by matching SHA256 checksums of EFI files against known 
release checksums.

## Database Format

```
# Comments start with #
<sha256> <version> <filename>
```

Example:
```
a1b2c3d4... v3.0.1 vmlinuz-bootmenu
e5f6g7h8... v3.0.1 initramfs-bootmenu.img
```

## Usage in Scripts

```bash
# Check installed version by checksum
if installed_version=$(zfsbootmenu_get_version_by_checksum); then
    echo "Installed version: $installed_version"
else
    echo "Version unknown"
fi
```

## Updating the Database

To update with newer releases:

1. Run `tools/update-vendor-deps.sh zfsbootmenu`
2. The script will fetch checksums from all GitHub releases
3. Commit the updated checksums.txt file

## Files

- `checksums.txt` - Main checksum database
- `VERSION` - Latest available version
- `README.md` - This documentation
