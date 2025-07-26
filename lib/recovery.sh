#!/bin/bash
#
# Recovery Library
#
# This library provides cleanup management, error recovery, and trap handling
# functionality. It manages cleanup stacks, emergency procedures, and
# provides recovery suggestions for common error scenarios.

# --- Prevent multiple sourcing ---
if [[ "${__RECOVERY_LIB_LOADED:-}" == "true" ]]; then
    return 0
fi
readonly __RECOVERY_LIB_LOADED="true"

# Load logging library if not already loaded
if [[ "${__LOGGING_LIB_LOADED:-}" != "true" ]]; then
    # Determine library directory
    RECOVERY_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    source "$RECOVERY_LIB_DIR/logging.sh"
fi

# ==============================================================================
# CLEANUP STACK MANAGEMENT
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

# Remove a cleanup function from the stack
# Usage: remove_cleanup "cleanup_function_name"
remove_cleanup() {
    local cleanup_func="$1"
    local new_stack=()
    
    for func in "${CLEANUP_STACK[@]}"; do
        if [[ "$func" != "$cleanup_func" ]]; then
            new_stack+=("$func")
        fi
    done
    
    CLEANUP_STACK=("${new_stack[@]}")
    log_debug "Removed cleanup function: $cleanup_func"
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
                if ! "$cleanup_func"; then
                    log_warn "Cleanup function failed: $cleanup_func"
                fi
            else
                log_warn "Cleanup function not found: $cleanup_func"
            fi
        done
        CLEANUP_STACK=()
        log_info "✅ Cleanup completed"
    fi
}

# Clear all cleanup functions
clear_cleanup_stack() {
    CLEANUP_STACK=()
    log_debug "Cleared cleanup stack"
}

# ==============================================================================
# ERROR HANDLING AND RECOVERY
# ==============================================================================

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

# Disable cleanup trap (useful for scripts that handle their own cleanup)
disable_cleanup_trap() {
    trap - EXIT ERR
    log_debug "Disabled cleanup traps"
}

# Emergency cleanup for critical errors
emergency_cleanup() {
    log_error "🚨 EMERGENCY CLEANUP INITIATED"
    
    # Force cleanup even if functions fail
    if [[ ${#CLEANUP_STACK[@]} -gt 0 ]]; then
        local i
        for ((i=${#CLEANUP_STACK[@]}-1; i>=0; i--)); do
            local cleanup_func="${CLEANUP_STACK[i]}"
            log_debug "Emergency cleanup: $cleanup_func"
            if declare -f "$cleanup_func" >/dev/null; then
                "$cleanup_func" 2>/dev/null || true
            fi
        done
    fi
    
    log_error "Emergency cleanup completed"
}

# ==============================================================================
# RECOVERY SUGGESTIONS
# ==============================================================================

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
            log_info "   • Check internet connectivity: ping 8.8.8.8"
            log_info "   • Verify DNS resolution: nslookup google.com"
            log_info "   • Check proxy settings if behind corporate firewall"
            log_info "   • Try again in a few minutes if servers are temporarily unavailable"
            ;;
        "zfs")
            log_info "💡 Recovery suggestions for ZFS errors:"
            log_info "   • Check ZFS pool status: sudo zpool status"
            log_info "   • Ensure ZFS modules are loaded: sudo modprobe zfs"
            log_info "   • Verify sufficient disk space: df -h"
            log_info "   • Check for pool errors: sudo zpool status -v"
            ;;
        "docker")
            log_info "💡 Recovery suggestions for Docker errors:"
            log_info "   • Start Docker daemon: sudo systemctl start docker"
            log_info "   • Add user to docker group: sudo usermod -aG docker $USER"
            log_info "   • Check Docker status: sudo systemctl status docker"
            log_info "   • Restart Docker service: sudo systemctl restart docker"
            ;;
        "dependency")
            log_info "💡 Recovery suggestions for dependency errors:"
            log_info "   • Update package lists: sudo apt update"
            log_info "   • Install missing packages using the commands shown above"
            log_info "   • Check if snap packages are available: snap find <package>"
            log_info "   • Verify package sources: sudo apt-cache policy <package>"
            ;;
        "mount")
            log_info "💡 Recovery suggestions for mount errors:"
            log_info "   • Check if device/dataset exists: ls -la /dev/..."
            log_info "   • Verify mount point exists: mkdir -p <mountpoint>"
            log_info "   • Check for existing mounts: mount | grep <path>"
            log_info "   • Force unmount if needed: sudo umount -f <path>"
            ;;
        "space")
            log_info "💡 Recovery suggestions for disk space errors:"
            log_info "   • Check available space: df -h"
            log_info "   • Clean up temporary files: sudo rm -rf /tmp/*"
            log_info "   • Clear Docker cache: docker system prune -f"
            log_info "   • Check for large files: du -sh /* | sort -h"
            ;;
        *)
            log_info "💡 General recovery suggestions:"
            log_info "   • Check the error message above for specific details"
            log_info "   • Review logs in ${STATUS_DIR:-/tmp} for build history"
            log_info "   • Try running with --debug for more detailed output"
            log_info "   • Check system resources: free -h && df -h"
            ;;
    esac
}

# ==============================================================================
# ROLLBACK AND RESTORATION
# ==============================================================================

# Stack for storing rollback actions
declare -a ROLLBACK_STACK=()

# Add a rollback action to the stack
# Usage: add_rollback "undo_command_or_function"
add_rollback() {
    local rollback_action="$1"
    ROLLBACK_STACK+=("$rollback_action")
    log_debug "Added rollback action: $rollback_action"
}

# Execute all rollback actions in reverse order
execute_rollback() {
    if [[ ${#ROLLBACK_STACK[@]} -gt 0 ]]; then
        log_info "⏪ Executing rollback procedures..."
        local i
        for ((i=${#ROLLBACK_STACK[@]}-1; i>=0; i--)); do
            local rollback_action="${ROLLBACK_STACK[i]}"
            log_debug "Executing rollback: $rollback_action"
            
            # Check if it's a function or command
            if declare -f "$rollback_action" >/dev/null; then
                "$rollback_action" || log_warn "Rollback function failed: $rollback_action"
            else
                eval "$rollback_action" || log_warn "Rollback command failed: $rollback_action"
            fi
        done
        ROLLBACK_STACK=()
        log_info "✅ Rollback completed"
    fi
}

# Clear rollback stack
clear_rollback_stack() {
    ROLLBACK_STACK=()
    log_debug "Cleared rollback stack"
}

# ==============================================================================
# STATE MANAGEMENT
# ==============================================================================

# Save current state for potential restoration
# Usage: save_state "state_name" "description"
save_state() {
    local state_name="$1"
    local description="${2:-Saved state: $state_name}"
    local state_file="${STATUS_DIR:-/tmp}/state_${state_name}_$(date +%s).json"
    
    log_debug "Saving state: $description"
    
    # Create state information
    cat > "$state_file" << EOF
{
    "state_name": "$state_name",
    "description": "$description",
    "timestamp": "$(date -Iseconds)",
    "pwd": "$(pwd)",
    "user": "$(whoami)",
    "environment": {
        "VERBOSE": "${VERBOSE:-false}",
        "DRY_RUN": "${DRY_RUN:-false}",
        "DEBUG": "${DEBUG:-false}"
    }
}
EOF
    
    log_debug "State saved to: $state_file"
    echo "$state_file"
}

# List available saved states
list_saved_states() {
    local state_dir="${STATUS_DIR:-/tmp}"
    
    if [[ -d "$state_dir" ]]; then
        find "$state_dir" -name "state_*.json" -type f 2>/dev/null | sort
    fi
}

# Remove old state files (older than specified days)
cleanup_old_states() {
    local days="${1:-7}"
    local state_dir="${STATUS_DIR:-/tmp}"
    
    if [[ -d "$state_dir" ]]; then
        log_debug "Cleaning up state files older than $days days"
        find "$state_dir" -name "state_*.json" -type f -mtime +$days -delete 2>/dev/null || true
    fi
}

# ==============================================================================
# PROGRESS TRACKING
# ==============================================================================

# Track completion of major operations for recovery purposes
declare -A COMPLETED_OPERATIONS=()

# Mark an operation as completed
# Usage: mark_operation_complete "operation_name"
mark_operation_complete() {
    local operation="$1"
    COMPLETED_OPERATIONS["$operation"]="$(date -Iseconds)"
    log_debug "Marked operation complete: $operation"
}

# Check if an operation was completed
# Usage: if is_operation_complete "operation_name"; then ... fi
is_operation_complete() {
    local operation="$1"
    [[ -n "${COMPLETED_OPERATIONS[$operation]:-}" ]]
}

# List completed operations
list_completed_operations() {
    for operation in "${!COMPLETED_OPERATIONS[@]}"; do
        echo "$operation: ${COMPLETED_OPERATIONS[$operation]}"
    done
}

# --- Finalization ---
log_debug "Recovery library initialized."
