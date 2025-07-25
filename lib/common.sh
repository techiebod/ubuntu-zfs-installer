#!/bin/bash
#
# Common library for ZFS build scripts
#
# This library provides standardized functions for logging, command execution,
# error handling, and argument parsing. It is designed to be sourced by all
# other shell scripts in this project to ensure consistent behavior.
#
# To use, add this line at the top of your script:
# source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

# --- Prevent multiple sourcing ---
if [[ "${__COMMON_LIB_LOADED:-}" == "true" ]]; then
    return 0
fi
readonly __COMMON_LIB_LOADED="true"

# --- Script Setup ---
# Enforce strict error handling
set -o errexit
set -o nounset
set -o pipefail

# --- Load Global Configuration ---
# Determine the project root directory (parent of lib/)
readonly COMMON_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="$(dirname "$COMMON_LIB_DIR")"
readonly GLOBAL_CONFIG_FILE="$PROJECT_ROOT/config/global.conf"

# Load constants
# shellcheck source=./constants.sh
source "$COMMON_LIB_DIR/constants.sh"

# Load global configuration if it exists
if [[ -f "$GLOBAL_CONFIG_FILE" ]]; then
    # shellcheck source=../config/global.conf
    source "$GLOBAL_CONFIG_FILE"
else
    # Fallback to hardcoded defaults if config file is missing
    echo "Warning: Global config file not found at $GLOBAL_CONFIG_FILE, using fallback defaults" >&2
    DEFAULT_DISTRIBUTION="ubuntu"
    DEFAULT_POOL_NAME="zroot"
    DEFAULT_MOUNT_BASE="/var/tmp/zfs-builds"
    DEFAULT_ARCH="amd64"
    DEFAULT_VARIANT="apt"
    DEFAULT_DOCKER_IMAGE="ubuntu:latest"
    STATUS_DIR="/var/tmp/zfs-builds"
    LOG_LEVEL="INFO"
fi

# Make configuration values readonly
readonly DEFAULT_DISTRIBUTION
readonly DEFAULT_POOL_NAME
readonly DEFAULT_MOUNT_BASE
readonly DEFAULT_ARCH
readonly DEFAULT_VARIANT
readonly DEFAULT_DOCKER_IMAGE
readonly STATUS_DIR
readonly LOG_LEVEL

# --- Global State Variables ---
# These are intended to be set by the calling script via argument parsing
VERBOSE=false
DRY_RUN=false
DEBUG=false
LOG_WITH_TIMESTAMPS=true

# ==============================================================================
# INTEGRATED LOGGING FRAMEWORK
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

# Set the build context for file logging
# Usage: set_build_log_context "build-name"
set_build_log_context() {
    BUILD_LOG_CONTEXT="$1"
    log_debug "Build logging context set to: $BUILD_LOG_CONTEXT"
}

# Clear the build context
clear_build_log_context() {
    BUILD_LOG_CONTEXT=""
}

# Get the log file path for current build context
get_build_log_file() {
    local build_name="${1:-$BUILD_LOG_CONTEXT}"
    if [[ -n "$build_name" ]]; then
        echo "${STATUS_DIR}/${build_name}${BUILD_LOG_SUFFIX}"
    fi
}

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
                echo -e "${timestamp}${color}[$level]${reset} $message" >&2
            else
                echo "${timestamp}[$level] $message" >&2
            fi
        fi
        
        # Log to file if requested and build context is set
        if [[ $((destination & LOG_DEST_FILE)) -ne 0 && -n "$BUILD_LOG_CONTEXT" ]]; then
            local log_file
            log_file=$(get_build_log_file)
            if [[ -n "$log_file" ]]; then
                # Ensure directory exists
                mkdir -p "$(dirname "$log_file")"
                # Use ISO format timestamp for file logs
                echo "$(date -Iseconds) [$level] $message" >> "$log_file"
            fi
        fi
    fi
}

# Log a message with a specified level (console only - backwards compatibility)
# Usage: _log "INFO" "This is an info message"
_log() {
    _log_to "$1" "$LOG_DEST_CONSOLE" "${@:2}"
}

# --- Public Logging Functions (Console Only) ---
log_info() { _log_to "INFO" "$LOG_DEST_CONSOLE" "$@"; }
log_error() { _log_to "ERROR" "$LOG_DEST_CONSOLE" "$@"; }
log_warn() { _log_to "WARN" "$LOG_DEST_CONSOLE" "$@"; }
log_debug() {
    if [[ "${DEBUG:-false}" == true ]]; then
        _log_to "DEBUG" "$LOG_DEST_CONSOLE" "$@"
    fi
}

# --- Enhanced Logging Functions (Console + File) ---
log_build_info() { _log_to "INFO" "$LOG_DEST_BOTH" "$@"; }
log_build_error() { _log_to "ERROR" "$LOG_DEST_BOTH" "$@"; }
log_build_warn() { _log_to "WARN" "$LOG_DEST_BOTH" "$@"; }
log_build_debug() {
    if [[ "${DEBUG:-false}" == true ]]; then
        _log_to "DEBUG" "$LOG_DEST_BOTH" "$@"
    fi
}

# --- File-Only Logging Functions ---
log_file_info() { _log_to "INFO" "$LOG_DEST_FILE" "$@"; }
log_file_error() { _log_to "ERROR" "$LOG_DEST_FILE" "$@"; }
log_file_warn() { _log_to "WARN" "$LOG_DEST_FILE" "$@"; }

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

# Log with step numbers for complex operations (both console and file)
log_step() {
    local step_num="$1"
    local total_steps="$2"
    shift 2
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
    local exit_code="${3:-$EXIT_GENERAL_ERROR}"
    
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
        "$EXIT_PERMISSION_ERROR"
}

die_with_dependency_error() {
    local missing_cmd="$1"
    local install_hint="${2:-}"
    local hint_msg=""
    [[ -n "$install_hint" ]] && hint_msg="Install with: $install_hint"
    
    die_with_context \
        "Required command not found: $missing_cmd" \
        "$hint_msg" \
        "$EXIT_MISSING_DEPS"
}

# ==============================================================================
# ARGUMENT PARSING FRAMEWORK
# ==============================================================================

# Common options that appear across all scripts
declare -gA COMMON_OPTIONS_MAP=(
    ["--verbose"]="-v"
    ["--dry-run"]="-n"
    ["--debug"]="-d"
    ["--help"]="-h"
)

# Parse common arguments and separate them from script-specific ones
# Usage: parse_common_args remaining_args_array "$@"
parse_common_args() {
    local -n remaining_ref=$1
    shift
    remaining_ref=()
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            --verbose|-v)
                VERBOSE=true
                shift
                ;;
            --dry-run|-n)
                DRY_RUN=true
                shift
                ;;
            --debug|-d)
                DEBUG=true
                shift
                ;;
            --help|-h)
                # This should be handled by the calling script
                remaining_ref+=("$1")
                shift
                ;;
            *)
                remaining_ref+=("$1")
                shift
                ;;
        esac
    done
}

# Add common flags to an argument array based on current global state
# Usage: add_common_flags args_array
add_common_flags() {
    local -n args_ref=$1
    
    [[ "$VERBOSE" == true ]] && args_ref+=("--verbose")
    [[ "$DRY_RUN" == true ]] && args_ref+=("--dry-run")
    [[ "$DEBUG" == true ]] && args_ref+=("--debug")
}

# Invoke a script with common flags automatically added
# Usage: invoke_script "manage-root-datasets.sh" "--pool" "$POOL_NAME" "create" "$BUILD_NAME"
invoke_script() {
    local script_name="$1"
    shift
    
    local args=("$@")
    add_common_flags args
    
    run_cmd "$script_dir/$script_name" "${args[@]}"
}

# Show standardized help for common options
show_common_options_help() {
    cat << EOF
COMMON OPTIONS:
      --verbose           Enable verbose output.
      --dry-run           Show commands without executing them.
      --debug             Enable detailed debug logging.
  -h, --help              Show this help message.
EOF
}

# ==============================================================================
# COMMAND EXECUTION
# ==============================================================================

# Run a command, respecting VERBOSE and DRY_RUN modes.
# If VERBOSE is true, output is streamed. Otherwise, it's captured.
# On failure, it logs the command, status code, and output before exiting.
# Usage: run_cmd "ls" "-l" "/tmp"
run_cmd() {
    local cmd_str="$*"
    log_debug "Executing command: $cmd_str"

    if [[ "${DRY_RUN:-false}" == true ]]; then
        log_info "[DRY-RUN] $cmd_str"
        return 0
    fi

    # Prepare for execution
    local output_file
    output_file=$(mktemp)
    local status=0

    if [[ "${VERBOSE:-false}" == true ]]; then
        # In verbose mode, stream output directly to stderr
        log_info "[EXEC] $cmd_str"
        "$@" > >(tee "$output_file") 2>&1 || status=$?
    else
        # In normal mode, capture output
        "$@" >"$output_file" 2>&1 || status=$?
    fi

    if [[ $status -ne 0 ]]; then
        log_error "Command failed with status $status: $cmd_str"
        log_error "Output:"
        # Minimal indent for readability
        sed 's/^/  /' "$output_file" >&2
        rm -f "$output_file"
        die "Aborting due to command failure."
    fi

    rm -f "$output_file"
    return 0
}

# ==============================================================================
# VALIDATION FUNCTIONS
# ==============================================================================

# Validate build name format
validate_build_name() {
    local name="$1"
    local context="${2:-build name}"
    
    if [[ ! "$name" =~ $BUILD_NAME_PATTERN ]]; then
        die "Invalid $context format: '$name'. Must contain only letters, numbers, dots, hyphens, and underscores."
    fi
    
    if [[ ${#name} -gt $BUILD_NAME_MAX_LENGTH ]]; then
        die "Invalid $context length: '$name'. Must be $BUILD_NAME_MAX_LENGTH characters or less."
    fi
}

# Validate hostname format
validate_hostname() {
    local hostname="$1"
    
    if [[ ! "$hostname" =~ $HOSTNAME_PATTERN ]]; then
        die "Invalid hostname format: '$hostname'. Must contain only letters, numbers, dots, and hyphens."
    fi
    
    if [[ ${#hostname} -gt $HOSTNAME_MAX_LENGTH ]]; then
        die "Invalid hostname length: '$hostname'. Must be $HOSTNAME_MAX_LENGTH characters or less."
    fi
}

# Validate install profile
validate_install_profile() {
    local profile="$1"
    
    for valid_profile in "${VALID_INSTALL_PROFILES[@]}"; do
        if [[ "$profile" == "$valid_profile" ]]; then
            return 0
        fi
    done
    
    die "Invalid install profile: '$profile'. Valid profiles are: ${VALID_INSTALL_PROFILES[*]}"
}

# Validate architecture
validate_architecture() {
    local arch="$1"
    local context="${2:-architecture}"
    
    for valid_arch in "${VALID_ARCHITECTURES[@]}"; do
        if [[ "$arch" == "$valid_arch" ]]; then
            return 0
        fi
    done
    
    die "Invalid $context: '$arch'. Valid architectures are: ${VALID_ARCHITECTURES[*]}"
}

# Validate distribution
validate_distribution() {
    local distro="$1"
    local context="${2:-distribution}"
    
    for valid_distro in "${VALID_DISTRIBUTIONS[@]}"; do
        if [[ "$distro" == "$valid_distro" ]]; then
            return 0
        fi
    done
    
    die "Invalid $context: '$distro'. Valid distributions are: ${VALID_DISTRIBUTIONS[*]}"
}

# Validate configuration values on startup with comprehensive checks
validate_global_config() {
    log_operation_start "Validating global configuration"
    
    # Check required variables are set
    local required_vars=(
        "DEFAULT_POOL_NAME"
        "DEFAULT_MOUNT_BASE"
        "STATUS_DIR"
        "DEFAULT_DISTRIBUTION"
        "DEFAULT_ARCH"
    )
    
    for var_name in "${required_vars[@]}"; do
        if [[ -z "${!var_name:-}" ]]; then
            die_with_context \
                "Required configuration variable '$var_name' not set" \
                "Check your global.conf file: $GLOBAL_CONFIG_FILE" \
                "$EXIT_CONFIG_ERROR"
        fi
        log_debug "✓ Config: $var_name=${!var_name}"
    done
    
    # Validate ZFS pool exists and is healthy
    check_zfs_pool "$DEFAULT_POOL_NAME"
    
    # Validate filesystem requirements
    validate_filesystem_requirements
    
    # Validate external dependencies
    validate_external_services
    
    log_operation_end "Validating global configuration"
}

# ==============================================================================
# PREREQUISITE & VALIDATION CHECKS
# ==============================================================================

# ==============================================================================
# DEPENDENCY VALIDATION FRAMEWORK
# ==============================================================================

# Enhanced command requirement checking with installation hints
require_command() {
    local cmd="$1"
    local description="${2:-Command '$cmd' is required}"
    local install_hint="${3:-}"
    
    if ! command -v "$cmd" &>/dev/null; then
        if [[ -n "$install_hint" ]]; then
            die_with_dependency_error "$cmd" "$install_hint"
        else
            # Provide common installation hints
            case "$cmd" in
                docker)
                    die_with_dependency_error "$cmd" "sudo apt install docker.io && sudo systemctl start docker"
                    ;;
                jq)
                    die_with_dependency_error "$cmd" "sudo apt install jq"
                    ;;
                curl)
                    die_with_dependency_error "$cmd" "sudo apt install curl"
                    ;;
                zfs|zpool)
                    die_with_dependency_error "$cmd" "sudo apt install zfsutils-linux"
                    ;;
                systemd-nspawn)
                    die_with_dependency_error "$cmd" "sudo apt install systemd-container"
                    ;;
                ansible-playbook)
                    die_with_dependency_error "$cmd" "sudo apt install ansible"
                    ;;
                *)
                    die_with_dependency_error "$cmd" ""
                    ;;
            esac
        fi
    fi
    log_debug "✓ Command available: $cmd"
}

# Validate external services and their connectivity
validate_external_services() {
    log_operation_start "Validating external service dependencies"
    
    # Test Docker daemon
    if command -v docker &>/dev/null; then
        if ! docker info &>/dev/null; then
            die_with_context \
                "Docker daemon is not running or not accessible" \
                "Start Docker with: sudo systemctl start docker" \
                "$EXIT_MISSING_DEPS"
        fi
        log_debug "✓ Docker daemon is accessible"
    fi
    
    # Test internet connectivity for Ubuntu package downloads
    if ! curl -s --connect-timeout 5 "https://archive.ubuntu.com" >/dev/null 2>&1; then
        log_warn "⚠️  Cannot reach Ubuntu package servers - some operations may fail"
        log_info "💡 Check internet connectivity or configure proxy settings"
    else
        log_debug "✓ Ubuntu package servers accessible"
    fi
    
    # Test Launchpad API for version resolution
    if ! curl -s --connect-timeout 5 "https://api.launchpad.net/1.0/ubuntu" >/dev/null 2>&1; then
        log_warn "⚠️  Cannot reach Launchpad API - Ubuntu version auto-detection may fail"
    else
        log_debug "✓ Launchpad API accessible"
    fi
    
    log_operation_end "Validating external service dependencies"
}

# Validate file system permissions and space
validate_filesystem_requirements() {
    log_operation_start "Validating filesystem requirements"
    
    # Check mount base directory
    if [[ ! -d "$DEFAULT_MOUNT_BASE" ]]; then
        log_info "Creating mount base directory: $DEFAULT_MOUNT_BASE"
        if ! mkdir -p "$DEFAULT_MOUNT_BASE" 2>/dev/null; then
            die_with_permission_error "creating mount base directory: $DEFAULT_MOUNT_BASE"
        fi
    fi
    
    if [[ ! -w "$DEFAULT_MOUNT_BASE" ]]; then
        die_with_permission_error "writing to mount base directory: $DEFAULT_MOUNT_BASE"
    fi
    
    # Check available space (warn if < 10GB)
    local available_space
    available_space=$(df "$DEFAULT_MOUNT_BASE" | awk 'NR==2 {print $4}')
    local required_space=$((10 * 1024 * 1024)) # 10GB in KB
    
    if [[ $available_space -lt $required_space ]]; then
        local space_gb=$((available_space / 1024 / 1024))
        log_warn "⚠️  Low disk space: ${space_gb}GB available, recommend at least 10GB"
    else
        log_debug "✓ Sufficient disk space available"
    fi
    
    # Check status directory
    if [[ ! -d "$STATUS_DIR" ]]; then
        if ! mkdir -p "$STATUS_DIR" 2>/dev/null; then
            die_with_permission_error "creating status directory: $STATUS_DIR"
        fi
    fi
    
    log_operation_end "Validating filesystem requirements"
}

# Check if a required command is available in the system's PATH
# Legacy function - kept for compatibility
# Usage: require_command "docker" "Docker is required to build images."
# require_command() {
#     local cmd="$1"
#     local msg="${2:-Command '$cmd' is not installed or not in PATH.}"
#     if ! command -v "$cmd" &>/dev/null; then
#         die "$msg"
#     fi
# }

# Check if the specified ZFS pool exists with enhanced validation
check_zfs_pool() {
    local pool_name="${1:-$DEFAULT_POOL_NAME}"
    require_command "zpool"
    
    log_debug "Checking for ZFS pool '$pool_name'..."
    
    if ! zpool list -H -o name "$pool_name" &>/dev/null; then
        local available_pools
        available_pools=$(zpool list -H -o name 2>/dev/null | sed 's/^/    /' | tr '\n' ' ')
        
        die_with_context \
            "ZFS pool '$pool_name' not found" \
            "Available pools:${available_pools:- None}. Create a pool with: sudo zpool create $pool_name <device>" \
            "$EXIT_CONFIG_ERROR"
    fi
    
    # Check pool health
    local pool_health
    pool_health=$(zpool list -H -o health "$pool_name" 2>/dev/null)
    if [[ "$pool_health" != "ONLINE" ]]; then
        log_warn "⚠️  ZFS pool '$pool_name' status: $pool_health"
        log_info "💡 Check pool status with: sudo zpool status $pool_name"
    else
        log_debug "✓ ZFS pool '$pool_name' is healthy (ONLINE)"
    fi
}

# Check if Docker is installed and the daemon is responsive
check_docker() {
    require_command "docker"
    log_debug "Checking Docker daemon status..."
    if ! docker info &>/dev/null; then
        die_with_context \
            "Docker daemon is not running or not accessible" \
            "Start Docker with: sudo systemctl start docker" \
            "$EXIT_MISSING_DEPS"
    fi
    log_debug "✓ Docker daemon is accessible"
}

# ==============================================================================
# RECOVERY AND CLEANUP FRAMEWORK
# ==============================================================================

# Stack of cleanup functions to call on error or exit
declare -a CLEANUP_STACK=()

# Add a cleanup function to the stack
# Usage: add_cleanup "cleanup_function_name"
add_cleanup() {
    local cleanup_func="$1"
    CLEANUP_STACK+=("$cleanup_func")
    log_debug "Added cleanup function: $cleanup_func"
}

# Run all cleanup functions in reverse order
run_cleanup_stack() {
    if [[ ${#CLEANUP_STACK[@]} -gt 0 ]]; then
        log_info "🧹 Running cleanup procedures..."
        local i
        for ((i=${#CLEANUP_STACK[@]}-1; i>=0; i--)); do
            local cleanup_func="${CLEANUP_STACK[i]}"
            log_debug "Running cleanup: $cleanup_func"
            if declare -f "$cleanup_func" >/dev/null; then
                "$cleanup_func" || log_warn "Cleanup function failed: $cleanup_func"
            else
                log_warn "Cleanup function not found: $cleanup_func"
            fi
        done
        CLEANUP_STACK=()
        log_info "✅ Cleanup completed"
    fi
}

# Default cleanup function called on error
cleanup_on_error() {
    log_error "🚨 Error encountered, running emergency cleanup..."
    run_cleanup_stack
}

# Set up trap for cleanup on script exit
setup_cleanup_trap() {
    trap 'run_cleanup_stack' EXIT
    trap 'cleanup_on_error; exit 1' ERR
}

# Recovery suggestions for common error scenarios
suggest_recovery() {
    local error_type="$1"
    
    case "$error_type" in
        "permission")
            log_info "💡 Recovery suggestions for permission errors:"
            log_info "   • Run with sudo if accessing system resources"
            log_info "   • Check file/directory ownership and permissions"
            log_info "   • Ensure your user is in required groups (docker, etc.)"
            ;;
        "network")
            log_info "💡 Recovery suggestions for network errors:"
            log_info "   • Check internet connectivity"
            log_info "   • Verify proxy settings if behind corporate firewall"
            log_info "   • Try again in a few minutes if servers are temporarily unavailable"
            ;;
        "zfs")
            log_info "💡 Recovery suggestions for ZFS errors:"
            log_info "   • Check ZFS pool status: sudo zpool status"
            log_info "   • Ensure ZFS modules are loaded: sudo modprobe zfs"
            log_info "   • Verify sufficient disk space: df -h"
            ;;
        "docker")
            log_info "💡 Recovery suggestions for Docker errors:"
            log_info "   • Start Docker daemon: sudo systemctl start docker"
            log_info "   • Add user to docker group: sudo usermod -aG docker $USER"
            log_info "   • Check Docker status: sudo systemctl status docker"
            ;;
        *)
            log_info "💡 General recovery suggestions:"
            log_info "   • Check the error message above for specific details"
            log_info "   • Review logs in $STATUS_DIR for build history"
            log_info "   • Try running with --debug for more detailed output"
            ;;
    esac
}

# ==============================================================================
# DISTRIBUTION & VERSIONING
# ==============================================================================

# --- Public Variables ---
# These will be populated by resolve_dist_info
DIST_VERSION=""
DIST_CODENAME=""

# --- Internal Functions ---

# Function to get codename for a given Ubuntu version.
# Returns codename string or empty string if not found.
_get_ubuntu_codename_for_version() {
    local version="$1"
    local codename
    codename=$(curl -s "https://api.launchpad.net/1.0/ubuntu/series" 2>/dev/null | \
               jq -r ".entries[] | select(.version == \"$version\") | .name" 2>/dev/null)

    if [[ -n "$codename" && "$codename" != "null" ]]; then
        echo "$codename"
    fi
}

# Function to get version for a given Ubuntu codename.
# Returns version string or empty string if not found.
_get_ubuntu_version_for_codename() {
    local codename_in="$1"
    local version
    version=$(curl -s "https://api.launchpad.net/1.0/ubuntu/series" 2>/dev/null | \
               jq -r ".entries[] | select(.name == \"$codename_in\") | .version" 2>/dev/null)

    if [[ -n "$version" && "$version" != "null" ]]; then
        echo "$version"
    fi
}

# Function to get the latest Ubuntu version number.
# Tries several methods to find the most recent release.
_get_latest_ubuntu_version() {
    local version=""

    # Method 1: Ubuntu Cloud Images (most up-to-date for releases)
    version=$(curl -s "https://cloud-images.ubuntu.com/releases/" 2>/dev/null | \
              grep -o 'href="[0-9][0-9]\.[0-9][0-9]/' | \
              grep -o '[0-9][0-9]\.[0-9][0-9]' | \
              sort -V | tail -1)

    if [[ -n "$version" ]]; then
        echo "$version"
        return 0
    fi

    # Method 2: Launchpad API fallback (current stable release)
    version=$(curl -s "https://api.launchpad.net/1.0/ubuntu/series" 2>/dev/null | \
              jq -r '.entries[] | select(.status == "Current Stable Release") | .version' 2>/dev/null)

    if [[ -n "$version" && "$version" != "null" ]]; then
        echo "$version"
        return 0
    fi

    # Method 3: Latest supported version from Launchpad
    version=$(curl -s "https://api.launchpad.net/1.0/ubuntu/series" 2>/dev/null | \
              jq -r '.entries[] | select(.status == "Supported") | .version' 2>/dev/null | \
              sort -V | tail -1)

    if [[ -n "$version" && "$version" != "null" ]]; then
        echo "$version"
        return 0
    fi
}

# --- Public Functions ---

# Resolve distribution version and codename from user input.
# Populates global DIST_VERSION and DIST_CODENAME.
# Usage: resolve_dist_info "ubuntu" "24.04" ""
#        resolve_dist_info "ubuntu" "" "noble"
#        resolve_dist_info "debian" "12" "bookworm"
resolve_dist_info() {
    local dist="$1"
    local version_in="$2"
    local codename_in="$3"

    log_debug "Resolving dist info for: dist='$dist', version='$version_in', codename='$codename_in'"

    if [[ "$dist" != "$DISTRO_UBUNTU" ]]; then
        # For non-ubuntu distributions, we can't do lookups yet.
        # Require both version and codename.
        if [[ -z "$version_in" || -z "$codename_in" ]]; then
            die "For distribution '$dist', both --version and --codename must be provided."
        fi
        DIST_VERSION="$version_in"
        DIST_CODENAME="$codename_in"
        log_info "Using custom distribution: $dist $DIST_VERSION ($DIST_CODENAME)"
        return 0
    fi

    # It's Ubuntu, let's resolve dynamically.
    require_command "curl" "curl is required to resolve Ubuntu versions."
    require_command "jq" "jq is required to resolve Ubuntu versions."

    if [[ -z "$version_in" && -z "$codename_in" ]]; then
        # Neither provided, get the latest version and its codename
        log_info "No version or codename specified, attempting to find latest Ubuntu release..."
        DIST_VERSION=$(_get_latest_ubuntu_version)
        if [[ -z "$DIST_VERSION" ]]; then
            die "Could not determine the latest Ubuntu version."
        fi
        DIST_CODENAME=$(_get_ubuntu_codename_for_version "$DIST_VERSION")
        if [[ -z "$DIST_CODENAME" ]]; then
            die "Could not determine codename for latest Ubuntu version '$DIST_VERSION'."
        fi

    elif [[ -n "$version_in" && -z "$codename_in" ]]; then
        # Version provided, find codename
        DIST_VERSION="$version_in"
        DIST_CODENAME=$(_get_ubuntu_codename_for_version "$DIST_VERSION")
        if [[ -z "$DIST_CODENAME" ]]; then
            die "Could not find a matching codename for Ubuntu version '$DIST_VERSION'."
        fi

    elif [[ -z "$version_in" && -n "$codename_in" ]]; then
        # Codename provided, find version
        DIST_CODENAME="$codename_in"
        DIST_VERSION=$(_get_ubuntu_version_for_codename "$DIST_CODENAME")
        if [[ -z "$DIST_VERSION" ]]; then
            die "Could not find a matching version for Ubuntu codename '$DIST_CODENAME'."
        fi

    elif [[ -n "$version_in" && -n "$codename_in" ]]; then
        # Both provided, validate they match
        local validation_codename
        validation_codename=$(_get_ubuntu_codename_for_version "$version_in")
        if [[ "$validation_codename" != "$codename_in" ]]; then
            die "Mismatch for Ubuntu: Version '$version_in' does not correspond to codename '$codename_in'. Found '$validation_codename'."
        fi
        DIST_VERSION="$version_in"
        DIST_CODENAME="$codename_in"
    else
        # This case should not be reached if called from main scripts with arg parsing
        die "For Ubuntu, please provide either --version or --codename."
    fi

    # Final check
    if [[ -z "$DIST_VERSION" || -z "$DIST_CODENAME" ]]; then
        die "Could not resolve version/codename for $dist. Input: version='$version_in', codename='$codename_in'."
    fi

    log_info "Resolved to: $dist $DIST_VERSION ($DIST_CODENAME)"
}

# Get default Ubuntu codename (used by multiple scripts)
get_default_ubuntu_codename() {
    local version
    version=$(_get_latest_ubuntu_version)
    if [[ -n "$version" ]]; then
        _get_ubuntu_codename_for_version "$version"
    else
        echo "plucky"  # Fallback to current development release
    fi
}

# --- Finalization ---
log_debug "Common library initialized."
