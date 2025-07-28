#!/bin/bash
#
# Common Flag Definitions Library
#
# This library provides standardized flag definitions and processing
# functions to eliminate duplication across scripts.

# --- Prevent multiple sourcing ---
if [[ "${__FLAG_HELPERS_LIB_LOADED:-}" == "true" ]]; then
    return 0
fi
readonly __FLAG_HELPERS_LIB_LOADED="true"

# ==============================================================================
# COMMON FLAG DEFINITIONS
# ==============================================================================

# Define the standard dry-run and debug flags that all scripts use
# Usage: define_common_flags
define_common_flags() {
    DEFINE_boolean 'dry-run' false 'Show all commands that would be run without executing them'
    DEFINE_boolean 'debug' false 'Enable detailed debug logging'
}

# ==============================================================================
# COMMON FLAG PROCESSING
# ==============================================================================

# Convert shflags boolean values to bash boolean strings and export them
# This handles the shflags convention (0=true, 1=false) conversion
# Usage: process_common_flags
process_common_flags() {
    # Update global environment variables (exported by lib/core.sh)
    # shellcheck disable=SC2154  # FLAGS_dry_run and FLAGS_debug are set by shflags
    # shellcheck disable=SC2034  # DRY_RUN and DEBUG are exported in core.sh
    DRY_RUN=$([ "${FLAGS_dry_run}" -eq 0 ] && echo "true" || echo "false")
    # shellcheck disable=SC2034  # DRY_RUN and DEBUG are exported in core.sh
    DEBUG=$([ "${FLAGS_debug}" -eq 0 ] && echo "true" || echo "false")
    
    # Override LOG_LEVEL to DEBUG when debug flag is enabled
    if [[ "$DEBUG" == "true" ]]; then
        # shellcheck disable=SC2034  # LOG_LEVEL is used by logging system
        LOG_LEVEL="DEBUG"
    fi
}

# ==============================================================================
# HELPER FUNCTIONS
# ==============================================================================

# Show help for common flags
# Usage: show_common_flags_help
show_common_flags_help() {
    cat << EOF
Common Options:
  --dry-run         Show all commands that would be run without executing them
  --debug           Enable detailed debug logging
EOF
}

log_debug "Flag helpers library initialized."
