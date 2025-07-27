# Vendor Library Documentation

This directory contains third-party libraries vendored into the project.

## shflags

- **Version**: 1.3.0
- **Source**: https://github.com/kward/shflags
- **License**: Apache License 2.0
- **Purpose**: Advanced command-line flag library for Unix shell scripts
- **Last Updated**: 2025-07-27
- **Documentation**: See [SHFLAGS_STANDARDS.md](SHFLAGS_STANDARDS.md) for project-specific flag conventions and usage patterns

### Usage in Scripts

```bash
# Source shflags
. "${LIB_DIR}/vendor/shflags"

# Define flags
DEFINE_string 'version' '' 'Distribution version' 'v'
DEFINE_boolean 'verbose' false 'Enable verbose output' ''

# Parse arguments
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"

# Use parsed flags
echo "Version: $FLAGS_version"
echo "Verbose: $FLAGS_verbose"
```

### Updating shflags

To update to a newer version:

1. Download the latest release from https://github.com/kward/shflags/releases
2. Extract and copy the `shflags` script to this directory
3. Update the version and date information above
4. Test all scripts that use shflags
5. Update any integration tests if needed

### License Compliance

The shflags library is included under the Apache License 2.0.
Copyright 2008-2023 Kate Ward. All Rights Reserved.
See the original license header in the shflags file and the project's NOTICE file for full attribution.
