#!/bin/bash
#
# Logging Framework Library
#
# This library provides a comprehensive logging framework with multiple levels,
# destinations (console/file), build-specific logging, and enhanced error handling.
# It supports colored output, timestamps, and contextual logging.

# --- Prevent multiple sourcing ---
if [[ "${__LOGGING_LIB_LOADED:-}" == "true" ]]; then
    return 0
fi
readonly __LOGGING_LIB_LOADED="true"

# ==============================================================================
# LOGGING CONSTANTS & CONFIGURATION
# ==============================================================================

# Log levels for filtering
readonly LOG_LEVEL_DEBUG=0
readonly LOG_LEVEL_INFO=1
readonly LOG_LEVEL_WARN=2
readonly LOG_LEVEL_ERROR=3

# Log destinations
readonly LOG_DEST_CONSOLE=1
readonly LOG_DEST_FILE=2
readonly LOG_DEST_BOTH=3

# Global logging context for build-specific logging
BUILD_LOG_CONTEXT=""

# Global logging configuration (can be set by calling scripts)
LOG_WITH_TIMESTAMPS="${LOG_WITH_TIMESTAMPS:-true}"
DEBUG="${DEBUG:-false}"

# ==============================================================================
# LOGGING CONTEXT MANAGEMENT
# ==============================================================================

# Set the build context for file logging
# Usage: set_build_log_context "build-name"
set_build_log_context() {
    BUILD_LOG_CONTEXT="$1"
    log_debug "Build logging context set to: $BUILD_LOG_CONTEXT"
    
    # Log a notification about file logging to the log file
    if [[ -n "$BUILD_LOG_CONTEXT" ]]; then
        local log_file
        log_file=$(get_build_log_file)
        if [[ -n "$log_file" ]]; then
            # Ensure directory exists
            mkdir -p "$(dirname "$log_file")"
            # Add informational message about debug logging
            echo "$(date -Iseconds) [DEBUG] File logging enabled, with full DEBUG information" >> "$log_file"
        fi
    fi
}

# Clear the build context
clear_build_log_context() {
    BUILD_LOG_CONTEXT=""
}

# Get the log file path for current build context
# shellcheck disable=SC2120  # Optional parameter usage is intentional
get_build_log_file() {
    local build_name="${1:-$BUILD_LOG_CONTEXT}"
    if [[ -n "$build_name" ]]; then
        echo "${STATUS_DIR:-/var/tmp/zfs-builds}/${build_name}${BUILD_LOG_SUFFIX:-.log}"
    fi
}

# ==============================================================================
# CORE LOGGING FUNCTIONS
# ==============================================================================

# Get numeric log level from string
get_log_level_number() {
    case "${LOG_LEVEL:-INFO}" in
        DEBUG) echo $LOG_LEVEL_DEBUG ;;
        INFO) echo $LOG_LEVEL_INFO ;;
        WARN) echo $LOG_LEVEL_WARN ;;
        ERROR) echo $LOG_LEVEL_ERROR ;;
        *) echo $LOG_LEVEL_INFO ;;
    esac
}

# Core logging function with destination control
# Usage: _log_to "INFO" "LOG_DEST_BOTH" "message"
_log_to() {
    local level="$1"
    local destination="$2"
    shift 2
    local message="$*"
    
    # Check if we should log this level
    local level_num
    case "$level" in
        DEBUG) level_num=$LOG_LEVEL_DEBUG ;;
        INFO) level_num=$LOG_LEVEL_INFO ;;
        WARN) level_num=$LOG_LEVEL_WARN ;;
        ERROR) level_num=$LOG_LEVEL_ERROR ;;
        *) level_num=$LOG_LEVEL_INFO ;;
    esac
    
    local min_level
    min_level=$(get_log_level_number)
    
    if [[ $level_num -ge $min_level ]]; then
        local timestamp=""
        if [[ "${LOG_WITH_TIMESTAMPS:-true}" == "true" ]]; then
            timestamp="$(date +'%Y-%m-%d %H:%M:%S') "
        fi
        
        # Auto-detect calling script name for context
        local script_name=""
        if [[ "${LOG_SHOW_SCRIPT:-true}" == "true" ]]; then
            # Get the script name from the call stack, skipping logging functions
            local caller_info
            for ((i=1; i<10; i++)); do
                caller_info=$(caller $i 2>/dev/null) || break
                local caller_file
                caller_file=$(echo "$caller_info" | cut -d' ' -f3)
                local caller_basename
                caller_basename=$(basename "$caller_file" .sh)
                
                # Skip logging-related files and functions
                if [[ "$caller_basename" != "logging" && "$caller_basename" != "core" ]]; then
                    script_name="[$caller_basename] "
                    break
                fi
            done
        fi
        
        # Log to console if requested
        if [[ $((destination & LOG_DEST_CONSOLE)) -ne 0 ]]; then
            # Color codes for different log levels
            local color=""
            local reset="\033[0m"
            case "$level" in
                DEBUG) color="\033[0;36m" ;;  # Cyan
                INFO) color="\033[0;32m" ;;   # Green
                WARN) color="\033[0;33m" ;;   # Yellow
                ERROR) color="\033[0;31m" ;;  # Red
            esac
            
            # Output with color if terminal supports it
            if [[ -t 2 ]]; then
                echo -e "${timestamp}${script_name}${color}[$level]${reset} $message" >&2
            else
                echo "${timestamp}${script_name}[$level] $message" >&2
            fi
        fi
        
        # Log to file if requested and build context is set
        # For debug level, always log to file (even in dry-run mode) for troubleshooting
        if [[ $((destination & LOG_DEST_FILE)) -ne 0 && -n "$BUILD_LOG_CONTEXT" ]]; then
            # Skip file logging in dry-run mode except for debug messages
            if [[ "${DRY_RUN:-false}" != "true" || "$level" == "DEBUG" ]]; then
                local log_file
                log_file=$(get_build_log_file)
                if [[ -n "$log_file" ]]; then
                    # Ensure directory exists
                    mkdir -p "$(dirname "$log_file")"
                    # Use ISO format timestamp for file logs
                    echo "$(date -Iseconds) ${script_name}[$level] $message" >> "$log_file"
                fi
            elif [[ "${DRY_RUN:-false}" == "true" && "$level" != "DEBUG" ]]; then
                # In dry-run mode, show what would be logged to file (except debug)
                log_debug "[DRY RUN] Would log to file: $message"
            fi
        fi
    fi
}

# Log a message with a specified level (console only - backwards compatibility)
# Usage: _log "INFO" "This is an info message"
_log() {
    _log_to "$1" "$LOG_DEST_CONSOLE" "${@:2}"
}

# ==============================================================================
# PUBLIC LOGGING FUNCTIONS (Console Only)
# ==============================================================================

log_info() { _log_to "INFO" "$LOG_DEST_CONSOLE" "$@"; }
log_error() { _log_to "ERROR" "$LOG_DEST_CONSOLE" "$@"; }
log_warn() { _log_to "WARN" "$LOG_DEST_CONSOLE" "$@"; }
log_debug() {
    if [[ "${DEBUG:-false}" == "true" ]]; then
        _log_to "DEBUG" "$LOG_DEST_CONSOLE" "$@"
    fi
}

# ==============================================================================
# ENHANCED LOGGING FUNCTIONS (Console + File)
# ==============================================================================

log_build_info() { _log_to "INFO" "$LOG_DEST_BOTH" "$@"; }
log_build_error() { _log_to "ERROR" "$LOG_DEST_BOTH" "$@"; }
log_build_warn() { _log_to "WARN" "$LOG_DEST_BOTH" "$@"; }
log_build_debug() {
    # Always log debug info to file for troubleshooting (bypass level filtering)
    if [[ -n "$BUILD_LOG_CONTEXT" ]]; then
        local log_file
        log_file=$(get_build_log_file)
        if [[ -n "$log_file" ]]; then
            # Ensure directory exists
            mkdir -p "$(dirname "$log_file")"
            # Use ISO format timestamp for file logs
            echo "$(date -Iseconds) [DEBUG] $*" >> "$log_file"
        fi
    fi
    
    # Show on console only if debug mode is enabled
    if [[ "${DEBUG:-false}" == "true" ]]; then
        _log_to "DEBUG" "$LOG_DEST_CONSOLE" "$@"
    fi
}

# ==============================================================================
# FILE-ONLY LOGGING FUNCTIONS
# ==============================================================================

log_file_info() { _log_to "INFO" "$LOG_DEST_FILE" "$@"; }
log_file_error() { _log_to "ERROR" "$LOG_DEST_FILE" "$@"; }
log_file_warn() { _log_to "WARN" "$LOG_DEST_FILE" "$@"; }
log_file_debug() { _log_to "DEBUG" "$LOG_DEST_FILE" "$@"; }

# ==============================================================================
# SPECIALIZED LOGGING FUNCTIONS
# ==============================================================================

# Log with context information
log_with_context() {
    local level="$1"
    local context="$2"
    shift 2
    _log_to "$level" "$LOG_DEST_CONSOLE" "[$context] $*"
}

# Log operation start/end for tracking (both console and file)
log_operation_start() {
    local operation="$1"
    log_build_info "🚀 Starting: $operation"
}

log_operation_end() {
    local operation="$1"
    local status="${2:-success}"
    if [[ "$status" == "success" ]]; then
        log_build_info "✅ Completed: $operation"
    else
        log_build_error "❌ Failed: $operation"
    fi
}

# Log validation operations quietly (debug level only)
log_validation_start() {
    local operation="$1"
    log_debug "🔍 Validating: $operation"
}

log_validation_end() {
    local operation="$1"
    local status="${2:-success}"
    if [[ "$status" == "success" ]]; then
        log_debug "✓ Validation passed: $operation"
    else
        log_debug "✗ Validation failed: $operation"
    fi
}

# Log with step numbers for complex operations (both console and file)
log_step() {
    local step_num="$1"
    shift 1
    
    # Derive total steps from the STAGE_FUNCTIONS array
    local total_steps="${#STAGE_FUNCTIONS[@]}"
    
    log_build_info "📋 Step $step_num/$total_steps: $*"
}

# Build event logging (replaces the old log_build_event function)
# This is the primary function for logging significant build events
log_build_event() {
    local message="$*"
    
    # Default to INFO level, but could be enhanced to detect level from message
    log_build_info "$message"
}

# Status change logging (always goes to file, optionally to console)
log_status_change() {
    local build_name="$1"
    local old_status="$2"
    local new_status="$3"
    local show_console="${4:-true}"
    
    local old_context="$BUILD_LOG_CONTEXT"
    set_build_log_context "$build_name"
    
    local message="Status changed: $old_status → $new_status"
    if [[ "$show_console" == "true" ]]; then
        log_build_info "$message"
    else
        log_file_info "$message"
    fi
    
    # Restore context
    BUILD_LOG_CONTEXT="$old_context"
}

# ==============================================================================
# ERROR HANDLING WITH LOGGING
# ==============================================================================

# Log an error and exit with a status of 1
# Usage: die "Something went terribly wrong"
die() {
    log_error "$@"
    exit 1
}

# Enhanced die function with context and recovery suggestions
# Usage: die_with_context "Error message" "Recovery suggestion" exit_code
die_with_context() {
    local error_msg="$1"
    local recovery_hint="${2:-}"
    local exit_code="${3:-${EXIT_GENERAL_ERROR:-1}}"
    
    log_error "$error_msg"
    
    if [[ -n "$recovery_hint" ]]; then
        log_info "💡 Recovery suggestion: $recovery_hint"
    fi
    
    # Call cleanup function if it exists
    if declare -f cleanup_on_error >/dev/null; then
        log_debug "Running cleanup on error..."
        cleanup_on_error || true  # Don't fail if cleanup fails
    fi
    
    exit "$exit_code"
}

# Enhanced error handling for common scenarios
die_with_permission_error() {
    local operation="$1"
    die_with_context \
        "Permission denied: $operation" \
        "Try running with sudo or check file/directory permissions" \
        "${EXIT_PERMISSION_ERROR:-13}"
}

die_with_dependency_error() {
    local missing_cmd="$1"
    local install_hint="${2:-}"
    local hint_msg=""
    [[ -n "$install_hint" ]] && hint_msg="Install with: $install_hint"
    
    die_with_context \
        "Required command not found: $missing_cmd" \
        "$hint_msg" \
        "${EXIT_MISSING_DEPS:-127}"
}

# --- Finalization ---
log_debug "Logging library initialized."
