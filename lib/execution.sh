#!/bin/bash
#
# Execution Library
#
# This library provides command execution, argument parsing, and script
# invocation functionality. It handles verbose/dry-run modes, command
# output management, and common argument processing.

# --- Prevent multiple sourcing ---
if [[ "${__EXECUTION_LIB_LOADED:-}" == "true" ]]; then
    return 0
fi
readonly __EXECUTION_LIB_LOADED="true"

# Load logging library if not already loaded
if [[ "${__LOGGING_LIB_LOADED:-}" != "true" ]]; then
    # Determine library directory
    EXECUTION_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    source "$EXECUTION_LIB_DIR/logging.sh"
fi

# ==============================================================================
# COMMAND EXECUTION FRAMEWORK
# ==============================================================================

# Internal command execution function - shared by run_cmd and run_cmd_read
# Usage: _run_cmd_internal "cmd_str" respect_dry_run die_on_failure "$@"
_run_cmd_internal() {
    local cmd_str="$1"
    local respect_dry_run="$2"
    local die_on_failure="$3"
    shift 3
    
    # Handle dry-run mode
    if [[ "$respect_dry_run" == "true" && "${DRY_RUN:-false}" == "true" ]]; then
        log_info "[DRY RUN] Would execute: $cmd_str"
        return 0
    elif [[ "$respect_dry_run" == "false" && "${DRY_RUN:-false}" == "true" ]]; then
        if [[ "${DEBUG:-false}" == "true" ]]; then
            log_debug "[DRY RUN] Read operation (executing): $cmd_str"
        fi
    fi

    # Show verbose information about command execution
    if [[ "${VERBOSE:-false}" == "true" ]]; then
        log_info "[VERBOSE] Executing: $cmd_str"
    fi

    # Prepare for execution
    local output_file
    output_file=$(mktemp)
    local status=0

    # Execute the command and capture output
    "$@" >"$output_file" 2>&1 || status=$?

    # Show debug information (return status and raw output)
    if [[ "${DEBUG:-false}" == "true" ]]; then
        log_debug "Command: $cmd_str"
        log_debug "Return status: $status"
        if [[ -s "$output_file" ]]; then
            log_debug "Raw output:"
            while IFS= read -r line; do
                log_debug "  $line"
            done < "$output_file"
        else
            log_debug "No output"
        fi
    fi

    # In verbose mode, show output if we're not in debug mode (to avoid duplication)
    if [[ "${VERBOSE:-false}" == "true" && "${DEBUG:-false}" != "true" ]]; then
        if [[ -s "$output_file" ]]; then
            log_info "[VERBOSE] Output:"
            while IFS= read -r line; do
                log_info "[VERBOSE]   $line"
            done < "$output_file"
        fi
    fi

    # For read operations, always show output (unless we're in debug mode)
    if [[ "$respect_dry_run" == "false" && "${DEBUG:-false}" != "true" ]]; then
        cat "$output_file"
    fi

    # Handle command execution results
    if [[ $status -ne 0 ]]; then
        if [[ "${DEBUG:-false}" != "true" ]]; then
            # Only show error details if not already shown in debug mode
            if [[ "$respect_dry_run" == "false" ]]; then
                log_error "Read command failed with status $status: $cmd_str"
            else
                log_error "Command failed with status $status: $cmd_str"
            fi
            log_error "Output:"
            sed 's/^/  /' "$output_file" >&2
        fi
        rm -f "$output_file"
        
        if [[ "$die_on_failure" == "true" ]]; then
            die "Aborting due to command failure."
        else
            return $status
        fi
    fi

    rm -f "$output_file"
    return 0
}

# Run a command, respecting VERBOSE and DRY_RUN modes.
# If VERBOSE is true, output is streamed. Otherwise, it's captured.
# On failure, it logs the command, status code, and output before exiting.
# Usage: run_cmd "ls" "-l" "/tmp"
run_cmd() {
    local cmd_str="$*"
    _run_cmd_internal "$cmd_str" "true" "true" "$@"
}

# Run a read-only command (always executes, even in DRY_RUN mode)
# Use for commands that only query/display information without modifying state
# Usage: run_cmd_read machinectl list
run_cmd_read() {
    local cmd_str="$*"
    _run_cmd_internal "$cmd_str" "false" "false" "$@"
}

# Run a command silently (capture output, don't fail on error)
# Returns the exit code and stores output in global RUN_QUIET_OUTPUT
# Usage: if run_quiet "command"; then ... fi
run_quiet() {
    local output_file
    output_file=$(mktemp)
    local status=0
    
    "$@" >"$output_file" 2>&1 || status=$?
    export RUN_QUIET_OUTPUT
    RUN_QUIET_OUTPUT=$(cat "$output_file")
    rm -f "$output_file"
    
    return $status
}

# Run a command and capture its output
# Usage: output=$(run_capture "command" "args")
run_capture() {
    local cmd_str="$*"
    log_debug "Capturing output from: $cmd_str"
    
    if [[ "${DRY_RUN:-false}" == true ]]; then
        log_info "[DRY RUN] Would execute: $cmd_str"
        echo "[dry-run-output]"
        return 0
    fi
    
    local output
    local status=0
    output=$("$@" 2>&1) || status=$?
    
    if [[ $status -ne 0 ]]; then
        log_error "Command failed with status $status: $cmd_str"
        log_error "Output: $output"
        die "Aborting due to command failure."
    fi
    
    echo "$output"
}

# ==============================================================================
# ARGUMENT PARSING FRAMEWORK
# ==============================================================================

# Parse common arguments and populate remaining arguments array
# Usage: parse_common_args remaining_args "$@"
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
# SCRIPT INVOCATION HELPERS
# ==============================================================================

# Execute a script in the scripts directory with error handling
# Usage: execute_script "build-new-root.sh" "--pool" "$POOL" "$BUILD_NAME"
execute_script() {
    local script_name="$1"
    shift
    
    # Determine script directory relative to current script
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)"
    if [[ -d "$script_dir/../scripts" ]]; then
        script_dir="$script_dir/../scripts"
    elif [[ -d "$script_dir/scripts" ]]; then
        script_dir="$script_dir/scripts"
    else
        die "Cannot find scripts directory from $script_dir"
    fi
    
    local script_path="$script_dir/$script_name"
    if [[ ! -f "$script_path" ]]; then
        die "Script not found: $script_path"
    fi
    
    if [[ ! -x "$script_path" ]]; then
        die "Script not executable: $script_path"
    fi
    
    log_debug "Executing script: $script_path $*"
    run_cmd "$script_path" "$@"
}

# Execute a command with timeout
# Usage: execute_with_timeout 30 "slow_command" "args"
execute_with_timeout() {
    local timeout_seconds="$1"
    shift
    
    log_debug "Executing with ${timeout_seconds}s timeout: $*"
    
    if [[ "${DRY_RUN:-false}" == true ]]; then
        log_info "[DRY RUN] timeout ${timeout_seconds}s $*"
        return 0
    fi
    
    if ! timeout "$timeout_seconds" "$@"; then
        local status=$?
        if [[ $status -eq 124 ]]; then
            die "Command timed out after ${timeout_seconds}s: $*"
        else
            die "Command failed with status $status: $*"
        fi
    fi
}

# Execute a command with retries
# Usage: execute_with_retry 3 5 "unreliable_command" "args"
execute_with_retry() {
    local max_attempts="$1"
    local delay_seconds="$2"
    shift 2
    
    local attempt=1
    local status=0
    
    while [[ $attempt -le $max_attempts ]]; do
        log_debug "Attempt $attempt/$max_attempts: $*"
        
        if run_quiet "$@"; then
            log_debug "Command succeeded on attempt $attempt"
            return 0
        fi
        
        status=$?
        
        if [[ $attempt -lt $max_attempts ]]; then
            log_warn "Command failed (attempt $attempt/$max_attempts), retrying in ${delay_seconds}s..."
            sleep "$delay_seconds"
        fi
        
        ((attempt++))
    done
    
    log_error "Command failed after $max_attempts attempts: $*"
    die "Aborting due to repeated command failures."
}

# ==============================================================================
# BACKGROUND PROCESS MANAGEMENT
# ==============================================================================

# Execute a command in the background and store PID
# Usage: execute_background "long_running_command" "args"
execute_background() {
    log_debug "Starting background process: $*"
    
    if [[ "${DRY_RUN:-false}" == true ]]; then
        log_info "[DRY RUN] background: $*"
        return 0
    fi
    
    "$@" &
    local pid=$!
    
    log_debug "Background process started with PID: $pid"
    echo "$pid"
}

# Wait for a background process to complete
# Usage: wait_for_background "$pid" "process description"
wait_for_background() {
    local pid="$1"
    local description="${2:-background process}"
    
    log_debug "Waiting for $description (PID: $pid)..."
    
    if wait "$pid"; then
        log_debug "$description completed successfully"
        return 0
    else
        local status=$?
        log_error "$description failed with status $status"
        die "Background process failure: $description"
    fi
}

# --- Finalization ---
log_debug "Execution library initialized."
