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

# Stack of rollback functions for atomic operations  
declare -a ROLLBACK_STACK=()

# Add a cleanup function to the stack
# Usage: add_cleanup "cleanup_function_name"
add_cleanup() {
    local cleanup_func="$1"
    
    if [[ -z "$cleanup_func" ]]; then
        echo "No cleanup command provided" >&2
        return 1
    fi
    
    CLEANUP_STACK+=("$cleanup_func")
    echo "Adding cleanup: $cleanup_func"
}

# Remove a cleanup function from the stack
# Usage: remove_cleanup "cleanup_function_name"
remove_cleanup() {
    local cleanup_func="$1"
    local new_stack=()
    local found=false
    
    # Handle empty array safely with nounset
    if [[ ${#CLEANUP_STACK[@]} -gt 0 ]]; then
        for func in "${CLEANUP_STACK[@]}"; do
            if [[ "$func" != "$cleanup_func" ]]; then
                new_stack+=("$func")
            else
                found=true
            fi
        done
    fi
    
    # Handle empty new_stack array safely
    if [[ ${#new_stack[@]} -gt 0 ]]; then
        CLEANUP_STACK=("${new_stack[@]}")
    else
        CLEANUP_STACK=()
    fi
    
    if [[ "$found" == "true" ]]; then
        echo "Removing cleanup: $cleanup_func"
    else
        echo "Cleanup command not found: $cleanup_func"
    fi
}

# Run all cleanup functions in reverse order
run_cleanup_stack() {
    if [[ ${#CLEANUP_STACK[@]} -eq 0 ]]; then
        echo "No cleanup commands to run"
        return 0
    fi
    
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        echo "[DRY RUN] Would run cleanup stack"
        for ((i=${#CLEANUP_STACK[@]}-1; i>=0; i--)); do
            echo "${CLEANUP_STACK[i]}"
        done
        return 0
    fi
    
    echo "Running cleanup stack"
    local i
    local failed=false
    for ((i=${#CLEANUP_STACK[@]}-1; i>=0; i--)); do
        local cleanup_cmd="${CLEANUP_STACK[i]}"
        echo "Executing cleanup: $cleanup_cmd"
        if declare -f "$cleanup_cmd" >/dev/null; then
            # It's a function
            if ! "$cleanup_cmd"; then
                echo "Cleanup command failed: $cleanup_cmd"
                failed=true
            fi
        else
            # It's a shell command
            if ! eval "$cleanup_cmd"; then
                echo "Cleanup command failed: $cleanup_cmd"
                failed=true
            fi
        fi
    done
    CLEANUP_STACK=()
    echo "✅ Cleanup completed"
    
    # For cleanup, we always return success even if some commands failed
    # This allows the cleanup process to complete and not abort the script
    return 0
}

# Clear all cleanup functions
clear_cleanup_stack() {
    CLEANUP_STACK=()
    echo "Clearing cleanup stack"
}

# ==============================================================================
# ERROR HANDLING AND RECOVERY
# ==============================================================================

# Default cleanup function called on error
cleanup_on_error() {
    echo "Script exiting with error, running cleanup"
    run_cleanup_stack
}

# Set up trap for cleanup on script exit
setup_cleanup_trap() {
    trap 'run_cleanup_stack' EXIT
    trap 'cleanup_on_error; exit 1' ERR
    echo "Setting up cleanup trap for EXIT signal"
}

# Disable cleanup trap (useful for scripts that handle their own cleanup)
disable_cleanup_trap() {
    trap - EXIT ERR
    echo "Disabling cleanup trap"
}

# Emergency cleanup for critical errors
# Emergency cleanup with specific error context
emergency_cleanup() {
    local error_msg="${1:-Unknown error}"
    echo "🚨 EMERGENCY CLEANUP INITIATED"
    echo "EMERGENCY CLEANUP: $error_msg"
    
    # Run cleanup stack and capture output to check for failures
    local cleanup_output
    cleanup_output=$(run_cleanup_stack 2>&1)
    echo "$cleanup_output"
    
    # Check if any cleanup commands failed
    if echo "$cleanup_output" | grep -q "Cleanup command failed:"; then
        echo "Emergency cleanup completed with errors"
    else
        echo "Emergency cleanup completed"
    fi
}

# ==============================================================================
# RECOVERY SUGGESTIONS
# ==============================================================================

# Recovery suggestions for common error scenarios
suggest_recovery() {
    local error_type="$1"
    local error_message="${2:-}"
    
    # Output the error message if provided
    if [[ -n "$error_message" ]]; then
        echo "$error_message"
    fi
    
    case "$error_type" in
        "permission")
            echo "💡 Recovery suggestions for permission errors:"
            echo "   • Run with sudo if accessing system resources"
            echo "   • Check file/directory ownership and permissions"
            echo "   • Ensure your user is in required groups (docker, etc.)"
            ;;
        "network")
            echo "💡 Recovery suggestions for network errors:"
            echo "   • Check internet connectivity: ping 8.8.8.8"
            echo "   • Verify DNS resolution: nslookup google.com"
            echo "   • Check proxy settings if behind corporate firewall"
            echo "   • Try again in a few minutes if servers are temporarily unavailable"
            ;;
        "zfs")
            echo "💡 Recovery suggestions for zfs error:"
            echo "   • Check ZFS pool status: sudo zpool status"
            echo "   • Ensure ZFS modules are loaded: sudo modprobe zfs"
            echo "   • Verify sufficient disk space: df -h"
            echo "   • Check for pool errors: sudo zpool status -v"
            ;;
        "container")
            echo "💡 Recovery suggestions for container error:"
            echo "   • Start Docker daemon: sudo systemctl start docker"
            echo "   • Add user to docker group: sudo usermod -aG docker \${USER:-\$LOGNAME}"
            echo "   • Check systemd-nspawn status: sudo systemctl status systemd-nspawn@<container>"
            echo "   • Restart Docker service: sudo systemctl restart docker"
            ;;
        "dependency")
            echo "💡 Recovery suggestions for dependency errors:"
            echo "   • Update package lists: sudo apt update"
            echo "   • Install missing packages using the commands shown above"
            echo "   • Check if snap packages are available: snap find <package>"
            echo "   • Verify package sources: sudo apt-cache policy <package>"
            ;;
        "mount")
            echo "💡 Recovery suggestions for mount error:"
            echo "   • Check if device/dataset exists: ls -la /dev/..."
            echo "   • Verify mount point exists: mkdir -p <mountpoint>"
            echo "   • Check mount points and existing mounts: mount | grep <path>"
            echo "   • Force unmount if needed: sudo umount -f <path>"
            ;;
        "space")
            echo "💡 Recovery suggestions for disk space errors:"
            echo "   • Check available space: df -h"
            echo "   • Clean up temporary files: sudo rm -rf /tmp/*"
            echo "   • Clear Docker cache: docker system prune -f"
            echo "   • Check for large files: du -sh /* | sort -h"
            ;;
        *)
            echo "💡 Recovery suggestions for ${error_type} error:"
            echo "   • Check the error message above for specific details"
            echo "   • Check system logs for more information"
            echo "   • Review logs in ${STATUS_DIR:-/tmp} for build history"
            echo "   • Try running with --debug for more detailed output"
            echo "   • Check system resources: free -h && df -h"
            if [[ ${#CLEANUP_STACK[@]} -gt 0 ]]; then
                echo "   • Run manual cleanup:"
                local i
                for ((i=${#CLEANUP_STACK[@]}-1; i>=0; i--)); do
                    echo "     - ${CLEANUP_STACK[i]}"
                done
            fi
            ;;
    esac
}

# ==============================================================================
# ROLLBACK AND RESTORATION
# ==============================================================================

# Add a rollback action to the stack
# Usage: add_rollback "undo_command_or_function"
add_rollback() {
    local rollback_action="$1"
    
    if [[ -z "$rollback_action" ]]; then
        echo "No rollback command provided" >&2
        return 1
    fi
    
    ROLLBACK_STACK+=("$rollback_action")
    echo "Adding rollback: $rollback_action"
}

# Execute all rollback actions in reverse order
execute_rollback() {
    if [[ ${#ROLLBACK_STACK[@]} -eq 0 ]]; then
        echo "No rollback commands to execute"
        return 0
    fi
    
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        echo "[DRY RUN] Would execute rollback stack"
        for ((i=${#ROLLBACK_STACK[@]}-1; i>=0; i--)); do
            echo "${ROLLBACK_STACK[i]}"
        done
        return 0
    fi
    
    echo "Executing rollback stack"
    local i
    for ((i=${#ROLLBACK_STACK[@]}-1; i>=0; i--)); do
        local rollback_action="${ROLLBACK_STACK[i]}"
        echo "$rollback_action"
        
        # Check if it's a function or command
        if declare -f "$rollback_action" >/dev/null; then
            if ! "$rollback_action"; then
                echo "Rollback command failed: $rollback_action"
                echo "Rollback stopped due to failure"
                return 1  # Stop on failure for rollback
            fi
        else
            if ! eval "$rollback_action"; then
                echo "Rollback command failed: $rollback_action"
                echo "Rollback stopped due to failure"
                return 1  # Stop on failure for rollback
            fi
        fi
    done
    ROLLBACK_STACK=()
    echo "✅ Rollback completed"
}

# Clear rollback stack
clear_rollback_stack() {
    ROLLBACK_STACK=()
    echo "Clearing rollback stack"
}

# ==============================================================================
# STATE MANAGEMENT
# ==============================================================================

# Save current state for potential restoration
# Usage: save_state "build_name" "operation" [state_file]
save_state() {
    local build_name="$1"
    local operation="$2"
    local state_file="${3:-}"
    
    if [[ -z "$build_name" ]] || [[ -z "$operation" ]]; then
        echo "Build name and operation required for save_state" >&2
        return 1
    fi
    
    # Use provided state file or generate one
    if [[ -z "$state_file" ]]; then
        state_file="${TEST_RECOVERY_DIR:-${STATUS_DIR:-/tmp}}/state_${build_name}_$(date +%s).json"
    fi
    
    echo "Saving state for $build_name: $operation"
    
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        echo "[DRY RUN] Would save state: $operation -> $state_file"
        echo "$state_file"
        return 0
    fi
    
    # Create state information with timestamp in expected format
    local state_content
    state_content=$(cat << EOF
$(date '+%Y-%m-%d %H:%M:%S') - Build: $build_name
Operation: $operation
Status: completed
{
    "build_name": "$build_name",
    "operation": "$operation",
    "timestamp": "$(date -Iseconds)",
    "status": "completed"
}
EOF
)
    
    # Try to write the state file and check for errors
    local temp_file="${state_file}.tmp"
    if ! echo "$state_content" > "$temp_file" 2>/dev/null; then
        echo "Failed to save state to $state_file" >&2
        return 1
    fi
    
    # Move temp file to final location
    if ! mv "$temp_file" "$state_file" 2>/dev/null; then
        rm -f "$temp_file" 2>/dev/null || true
        echo "Failed to save state to $state_file" >&2
        return 1
    fi
    
    echo "$state_file"
}

# List available saved states
list_saved_states() {
    local state_dir="${1:-${STATUS_DIR:-/tmp}}"
    
    if [[ -d "$state_dir" ]]; then
        local states
        states=$(find "$state_dir" \( -name "state_*.json" -o -name "*.state" \) -type f 2>/dev/null | sort)
        if [[ -n "$states" ]]; then
            echo "Saved states in $state_dir:"
            echo "$states"
        else
            echo "No saved states found in $state_dir"
        fi
    else
        echo "No saved states found in $state_dir"
    fi
}

# Remove old state files (older than specified days)
cleanup_old_states() {
    local state_dir="${1:-${STATUS_DIR:-/tmp}}"
    local keep_newest="${2:-}"
    local days="${3:-7}"
    
    # Handle different calling patterns for backward compatibility
    if [[ "$1" =~ ^[0-9]+$ ]]; then
        # Old pattern: cleanup_old_states [days]
        days="$1"
        state_dir="${STATUS_DIR:-/tmp}"
        keep_newest=""
    elif [[ -n "$2" && "$2" =~ ^[0-9]+$ && -z "${3:-}" ]]; then
        # New pattern: cleanup_old_states state_dir keep_newest
        keep_newest="$2"
        days=""
    fi
    
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        echo "[DRY RUN] Would clean up old state files"
        return 0
    fi
    
    if [[ -d "$state_dir" ]]; then
        if [[ -n "$keep_newest" ]]; then
            echo "Cleaning up old state files (keeping $keep_newest newest)"
            # Keep only the newest N files
            local files_to_delete
            files_to_delete=$(find "$state_dir" -name "*.state" -o -name "state_*.json" -type f 2>/dev/null | sort -t_ -k2 -n | head -n -"$keep_newest")
            if [[ -n "$files_to_delete" ]]; then
                echo "$files_to_delete" | xargs rm -f 2>/dev/null || true
            fi
        else
            echo "Cleaning up state files older than $days days"
            find "$state_dir" -name "state_*.json" -type f -mtime +$days -delete 2>/dev/null || true
            find "$state_dir" -name "*.state" -type f -mtime +$days -delete 2>/dev/null || true
        fi
    fi
}

# ==============================================================================
# PROGRESS TRACKING
# ==============================================================================

# Track completion of major operations for recovery purposes
declare -A COMPLETED_OPERATIONS=()

# Mark an operation as completed
# Usage: mark_operation_complete "build_name" "operation_name"
mark_operation_complete() {
    local build_name="$1"
    local operation="$2"
    
    if [[ -z "$build_name" ]] || [[ -z "$operation" ]]; then
        echo "Build name and operation name required for mark_operation_complete" >&2
        return 1
    fi
    
    local key="${build_name}.${operation}"
    local recovery_dir="${TEST_RECOVERY_DIR:-${STATUS_DIR:-/tmp}}"
    local completion_file="${recovery_dir}/${key}.complete"
    
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        echo "[DRY RUN] Would mark complete: $key"
        return 0
    fi
    
    # Ensure associative array is properly initialized
    if [[ ! -v COMPLETED_OPERATIONS ]]; then
        declare -A COMPLETED_OPERATIONS=()
    fi
    
    COMPLETED_OPERATIONS["$key"]="$(date -Iseconds)"
    echo "Marking operation complete: $key"
    
    # Create completion marker file
    mkdir -p "$recovery_dir"
    echo "$(date -Iseconds)" > "$completion_file"
}

# Check if an operation was completed
# Usage: if is_operation_complete "build_name" "operation_name"; then ... fi
is_operation_complete() {
    local build_name="$1"
    local operation="$2"
    
    if [[ -z "$build_name" ]] || [[ -z "$operation" ]]; then
        return 1
    fi
    
    local key="${build_name}.${operation}"
    local recovery_dir="${TEST_RECOVERY_DIR:-${STATUS_DIR:-/tmp}}"
    local completion_file="${recovery_dir}/${key}.complete"
    
    # Check completion marker file first
    if [[ -f "$completion_file" ]]; then
        return 0
    fi
    
    # Fallback to in-memory tracking
    # Ensure associative array is properly initialized
    if [[ ! -v COMPLETED_OPERATIONS ]]; then
        declare -A COMPLETED_OPERATIONS=()
    fi
    
    [[ -n "${COMPLETED_OPERATIONS[$key]:-}" ]]
}

# List completed operations
list_completed_operations() {
    # Ensure associative array is properly initialized
    if [[ ! -v COMPLETED_OPERATIONS ]]; then
        declare -A COMPLETED_OPERATIONS=()
    fi
    
    local recovery_dir="${TEST_RECOVERY_DIR:-${STATUS_DIR:-/tmp}}"
    local found_any=false
    
    # Check for completion files
    if [[ -d "$recovery_dir" ]]; then
        local completion_files
        completion_files=$(find "$recovery_dir" -name "*.complete" -type f 2>/dev/null | sort)
        if [[ -n "$completion_files" ]]; then
            echo "Completed operations:"
            while IFS= read -r file; do
                local basename_file
                basename_file=$(basename "$file" .complete)
                local timestamp
                timestamp=$(cat "$file" 2>/dev/null || echo "unknown")
                echo "$basename_file: $timestamp"
                found_any=true
            done <<< "$completion_files"
        fi
    fi
    
    # Check in-memory operations (but don't duplicate file-based ones)
    if [[ ${#COMPLETED_OPERATIONS[@]} -gt 0 ]]; then
        if [[ "$found_any" == "false" ]]; then
            echo "Completed operations:"
        fi
        for operation in "${!COMPLETED_OPERATIONS[@]}"; do
            # Only show if not already shown from files
            local completion_file="${recovery_dir}/${operation}.complete"
            if [[ ! -f "$completion_file" ]]; then
                echo "$operation: ${COMPLETED_OPERATIONS[$operation]}"
                found_any=true
            fi
        done
    fi
    
    if [[ "$found_any" == "false" ]]; then
        echo "No completed operations found"
        return 0
    fi
}

# --- Finalization ---
log_debug "Recovery library initialized."
