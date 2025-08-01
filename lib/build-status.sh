#!/bin/bash
#
# Build Status Management Library
#
# This library provides standardized build status tracking, logging, and state management
# for the Ubuntu ZFS installer. It consolidates build progression logic and persistent logging.

# --- Prevent multiple sourcing ---
if [[ "${__BUILD_STATUS_LIB_LOADED:-}" == "true" ]]; then
    return 0
fi
readonly __BUILD_STATUS_LIB_LOADED="true"

# --- Load dependencies ---
# Get the directory where this script is located
BUILD_STATUS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source required libraries
source "${BUILD_STATUS_LIB_DIR}/constants.sh"
source "${BUILD_STATUS_LIB_DIR}/execution.sh"

# ==============================================================================
# BUILD STATUS FILE OPERATIONS
# ==============================================================================

# Get the status file path for a build
# Usage: build_get_status_file "build-name"
build_get_status_file() {
    local build_name="$1"
    echo "${STATUS_DIR}/${build_name}${STATUS_FILE_SUFFIX}"
}

# Get the log file path for a build
# Usage: build_get_log_file "build-name"
build_get_log_file() {
    local build_name="$1"
    echo "${STATUS_DIR}/${build_name}${BUILD_LOG_SUFFIX}"
}

# Parse a status line from the status file
# Usage: build_parse_status_line "status_line"
build_parse_status_line() {
    local line="$1"
    # Status file format: "timestamp|status|message"
    local timestamp="${line%%|*}"
    local rest="${line#*|}"
    local status="${rest%%|*}"
    local message="${rest#*|}"
    
    echo "$timestamp" "$status" "$message"
}

# Get the last status entry from a build's status file
# Usage: build_get_last_status_entry "build-name"
build_get_last_status_entry() {
    local build_name="$1"
    local status_file
    status_file=$(build_get_status_file "$build_name")
    
    if [[ ! -f "$status_file" ]]; then
        return 1
    fi
    
    tail -n 1 "$status_file"
}

# ==============================================================================
# BUILD STATUS MANAGEMENT
# ==============================================================================

# Set the status for a build
# Usage: build_set_status "build-name" "status" [message]
build_set_status() {
    local build_name="$1"
    local status="$2"
    local message="${3:-}"
    local timestamp
    timestamp=$(date -Iseconds)
    
    echo "Setting build status: $build_name -> $status"
    
    # Validate status
    local valid=false
    for valid_status in "${VALID_STATUSES[@]}"; do
        if [[ "$status" == "$valid_status" ]]; then
            valid=true
            break
        fi
    done
    
    if [[ "$valid" != true ]]; then
        echo "Invalid status: $status" >&2
        return 1
    fi
    
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        echo "[DRY RUN] Would set status: $build_name -> $status"
        return 0
    fi
    
    local status_file
    status_file=$(build_get_status_file "$build_name")
    
    # Ensure status directory exists
    run_cmd mkdir -p "$(dirname "$status_file")"
    
    # Use new format with timestamp|status|message for better structure
    run_cmd sh -c "echo '${timestamp}|${status}|${message}' >> '$status_file'"
}

# Get the current status for a build
# Usage: build_get_status "build-name"
build_get_status() {
    local build_name="$1"
    local last_entry
    
    if ! last_entry=$(build_get_last_status_entry "$build_name"); then
        # Return success with empty output for non-existent builds
        return 0
    fi
    
    # Extract status from last entry
    local parsed
    read -ra parsed < <(build_parse_status_line "$last_entry")
    echo "${parsed[1]}"
}

# Get the timestamp for the current status
# Usage: build_get_status_timestamp "build-name"
build_get_status_timestamp() {
    local build_name="$1"
    local last_entry
    
    if ! last_entry=$(build_get_last_status_entry "$build_name"); then
        # Return success with empty output for non-existent builds
        return 0
    fi
    
    # Extract timestamp from last entry
    local parsed
    read -ra parsed < <(build_parse_status_line "$last_entry")
    echo "${parsed[0]}"
}

# Clear all status information for a build
# Usage: build_clear_status "build-name" [--force]
build_clear_status() {
    local build_name="$1"
    local force=false
    
    # Check for force flag in second position
    if [[ "${2:-}" == "--force" ]]; then
        force=true
    fi
    
    if [[ "$force" == "true" ]]; then
        log_info "Force clearing all artifacts for: $build_name"
    else
        log_info "Clearing build status: $build_name"
    fi
    
    local status_file
    local log_file
    
    status_file=$(build_get_status_file "$build_name")
    log_file=$(build_get_log_file "$build_name")
    
    # Use run_cmd to handle DRY_RUN/DEBUG output automatically
    if [[ -f "$status_file" ]] || [[ "${DRY_RUN:-false}" == "true" ]]; then
        run_cmd rm -f "$status_file"
    fi
    if [[ -f "$log_file" ]] || [[ "${DRY_RUN:-false}" == "true" ]]; then
        run_cmd rm -f "$log_file"
    fi
    
    return 0
}

# ==============================================================================
# BUILD PROGRESSION LOGIC
# ==============================================================================

# Get the next stage for a given status
# Usage: build_get_next_stage "current-status"
build_get_next_stage() {
    local current_status="$1"
    echo "${STATUS_PROGRESSION[$current_status]:-}"
}

# Check if a stage should run based on current build status
# Usage: build_should_run_stage "stage" "build-name" [force-restart]
build_should_run_stage() {
    local stage="$1"
    local build_name="$2"
    local force_restart="${3:-false}"
    
    # Force restart always runs
    if [[ "$force_restart" == true ]]; then
        log_debug "Force restart requested - stage $stage will run"
        return 0
    fi
    
    local current_status
    current_status=$(build_get_status "$build_name")
    
    # No status file = run first stage only
    if [[ -z "$current_status" ]]; then
        if [[ "$stage" == "$STATUS_DATASETS_CREATED" ]]; then
            log_debug "No previous status - first stage will run"
            return 0
        else
            log_debug "No previous status - only first stage can run"
            return 1
        fi
    fi
    
    # Completed builds don't run more stages
    if [[ "$current_status" == "$STATUS_COMPLETED" ]]; then
        log_debug "Build already completed - no stages will run"
        return 1
    fi
    
    # Check if the requested stage comes after the current status in the progression
    local current_index=-1
    local stage_index=-1
    
    for i in "${!VALID_STATUSES[@]}"; do
        [[ "${VALID_STATUSES[$i]}" == "$current_status" ]] && current_index=$i
        [[ "${VALID_STATUSES[$i]}" == "$stage" ]] && stage_index=$i
    done
    
    # Stage should run only if it's the immediate next stage in sequence
    local next_expected_index=$((current_index + 1))
    if [[ $stage_index -eq $next_expected_index ]]; then
        log_debug "Stage $stage should run (next expected stage after current: $current_status)"
        return 0
    elif [[ $stage_index -eq $current_index ]]; then
        log_debug "Stage $stage already completed"
        return 1
    elif [[ $stage_index -lt $current_index ]]; then
        log_debug "Cannot run stage $stage - stage is before current status (current: $current_status)"
        return 1
    else
        log_debug "Cannot run stage $stage - would skip stages (current: $current_status, expected next: ${VALID_STATUSES[$next_expected_index]:-'none'})"
        return 1
    fi
}

# ==============================================================================
# BUILD LISTING AND REPORTING
# ==============================================================================

# List all builds with their current status
# Usage: build_list_all_with_status
build_list_all_with_status() {
    log_info "Build Status Summary:"
    printf "%-25s %-20s %-25s %s\n" "Build Name" "Status" "Last Updated" "Message"
    printf "%-25s %-20s %-25s %s\n" "-------------------------" "--------------------" "-------------------------" "-------"
    
    local found_any=false
    
    for status_file in "${STATUS_DIR}"/*"${STATUS_FILE_SUFFIX}"; do
        if [[ ! -f "$status_file" ]]; then
            continue
        fi
        
        found_any=true
        local build_name
        build_name=$(basename "$status_file" "$STATUS_FILE_SUFFIX")
        
        local last_entry
        if last_entry=$(build_get_last_status_entry "$build_name"); then
            local parsed
            read -ra parsed < <(build_parse_status_line "$last_entry")
            local timestamp="${parsed[0]}"
            local status="${parsed[1]}"
            local message="${parsed[2]:-}"
            
            # Format timestamp for display
            local display_time
            display_time=$(date -d "$timestamp" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "$timestamp")
            
            printf "%-25s %-20s %-25s %s\n" \
                "$build_name" \
                "$status" \
                "$display_time" \
                "$message"
        fi
    done
    
    if [[ "$found_any" != true ]]; then
        echo "No builds found."
    fi
}

# Show detailed information about a specific build
# Usage: build_show_details "build-name" [pool-name]
build_show_details() {
    local build_name="$1"
    local pool_name="${2:-$DEFAULT_POOL_NAME}"
    
    log_info "Build Details for: $build_name"
    echo
    
    # Current status
    local current_status
    if current_status=$(build_get_status "$build_name"); then
        local timestamp
        timestamp=$(build_get_status_timestamp "$build_name")
        local display_time
        display_time=$(date -d "$timestamp" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "$timestamp")
        
        echo "Current Status: $current_status"
        echo "Last Updated:   $display_time"
    else
        echo "Current Status: No status information found"
    fi
    
    echo
    
    # ZFS dataset information
    local dataset
    if declare -f zfs_get_root_dataset_path >/dev/null 2>&1; then
        dataset=$(zfs_get_root_dataset_path "$pool_name" "$build_name")
        if declare -f zfs_dataset_exists >/dev/null 2>&1 && zfs_dataset_exists "$dataset"; then
        echo "ZFS Dataset Information:"
        echo "  Dataset: $dataset"
        
        local used
        if declare -f zfs_get_property >/dev/null 2>&1; then
            used=$(zfs_get_property "$dataset" "used" 2>/dev/null || echo "unknown")
        else
            used="unknown (zfs_get_property not available)"
        fi
        echo "  Used Space: $used"
        
        local mountpoint
        if declare -f zfs_get_property >/dev/null 2>&1; then
            mountpoint=$(zfs_get_property "$dataset" "mountpoint" 2>/dev/null || echo "unknown")
        else
            mountpoint="unknown (zfs_get_property not available)"
        fi
        echo "  Mountpoint: $mountpoint"
        
        local canmount
        if declare -f zfs_get_property >/dev/null 2>&1; then
            canmount=$(zfs_get_property "$dataset" "canmount" 2>/dev/null || echo "unknown")
        else
            canmount="unknown (zfs_get_property not available)"
        fi
        echo "  Can Mount: $canmount"
        
        # Check for varlog dataset
        local varlog_dataset="${dataset}/varlog"
        if declare -f zfs_dataset_exists >/dev/null 2>&1 && zfs_dataset_exists "$varlog_dataset"; then
            echo "  Varlog Dataset: exists"
        else
            echo "  Varlog Dataset: not found"
        fi
        
        # List snapshots
        local snapshots
        if declare -f zfs_list_snapshots >/dev/null 2>&1; then
            mapfile -t snapshots < <(zfs_list_snapshots "$dataset" "$SNAPSHOT_PREFIX" 2>/dev/null)
            if [[ ${#snapshots[@]} -gt 0 ]]; then
                echo "  Snapshots: ${#snapshots[@]} found"
            else
                echo "  Snapshots: none found"
            fi
        else
            echo "  Snapshots: unknown (zfs_list_snapshots not available)"
        fi
    else
        echo "ZFS Dataset: not found ($dataset)"
    fi
    else
        echo "ZFS Dataset: not available (ZFS functions not loaded)"
    fi
    
    echo
    
    # Container information
    local container_name="$build_name"
    echo "Container Status:"
    if declare -f container_get_detailed_status >/dev/null 2>&1; then
        local container_status
        container_status=$(container_get_detailed_status "$container_name")
        echo "  $container_status"
    else
        echo "  Container functions not available"
    fi
    
    echo
}

# Show build history with stage progression and timing
# Usage: build_show_history "build-name" [--tail N]
build_show_history() {
    local build_name="$1"
    local tail_count=""
    
    # Parse --tail option
    if [[ "$2" == "--tail" && -n "$3" ]]; then
        tail_count="$3"
    fi
    local status_file
    status_file=$(build_get_status_file "$build_name")
    
    if [[ ! -f "$status_file" ]]; then
        echo "No build history found for: $build_name"
        return 1
    fi
    
    log_info "Build History for: $build_name"
    
    if [[ -n "$tail_count" ]]; then
        echo
        echo "Last $tail_count entries:"
    fi
    
    echo
    echo "Stage Progression & Timings:"
    printf "%-25s %-20s %-25s %s\n" "Status" "Duration" "Timestamp" "Message"
    printf "%-25s %-20s %-25s %s\n" "-------------------------" "--------------------" "-------------------------" "-------"
    
    local prev_timestamp=""
    local first_timestamp=""
    local last_timestamp=""
    
    # Process lines (use tail if specified)
    local lines_to_process
    if [[ -n "$tail_count" ]]; then
        lines_to_process=$(run_cmd_read tail -n "$tail_count" "$status_file")
    else
        lines_to_process=$(run_cmd_read cat "$status_file")
    fi
    
    while IFS= read -r line; do
        if [[ -z "$line" ]]; then continue; fi
        
        local parsed
        read -ra parsed < <(build_parse_status_line "$line")
        local timestamp="${parsed[0]}"
        local status="${parsed[1]}"
        local message="${parsed[2]:-}"
        
        # Calculate duration from previous stage
        local duration=""
        if [[ -n "$prev_timestamp" ]]; then
            local prev_epoch
            local curr_epoch
            prev_epoch=$(date -d "$prev_timestamp" +%s 2>/dev/null || echo "0")
            curr_epoch=$(date -d "$timestamp" +%s 2>/dev/null || echo "0")
            if [[ "$curr_epoch" -gt 0 && "$prev_epoch" -gt 0 ]]; then
                local diff=$((curr_epoch - prev_epoch))
                duration=$(printf "%02d:%02d:%02d" $((diff/3600)) $(((diff%3600)/60)) $((diff%60)))
            fi
        fi
        
        # Format timestamp for display
        local display_time
        display_time=$(date -d "$timestamp" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "$timestamp")
        
        printf "%-25s %-20s %-25s %s\n" \
            "$status" \
            "${duration:-'--:--:--'}" \
            "$display_time" \
            "$message"
        
        prev_timestamp="$timestamp"
        [[ -z "$first_timestamp" ]] && first_timestamp="$timestamp"
        last_timestamp="$timestamp"
        
    done <<< "$lines_to_process"
    
    # Show total build time if we have both first and last timestamps
    if [[ -n "$first_timestamp" && -n "$last_timestamp" && "$first_timestamp" != "$last_timestamp" ]]; then
        echo
        echo "Total Build Time:"
        local first_epoch
        local last_epoch
        first_epoch=$(date -d "$first_timestamp" +%s 2>/dev/null || echo "0")
        last_epoch=$(date -d "$last_timestamp" +%s 2>/dev/null || echo "0")
        if [[ "$last_epoch" -gt 0 && "$first_epoch" -gt 0 ]]; then
            local total_diff=$((last_epoch - first_epoch))
            local total_duration
            total_duration=$(printf "%02d:%02d:%02d" $((total_diff/3600)) $(((total_diff%3600)/60)) $((total_diff%60)))
            echo "  $total_duration (from start to current status)"
        fi
    fi
}

# ==============================================================================
# BUILD CLEANUP OPERATIONS
# ==============================================================================

# Clean up artifacts for a specific build (datasets, containers, status)
# Usage: build_clean_artifacts "build-name" [pool-name]
build_clean_artifacts() {
    local build_name="$1"
    local pool_name="${2:-$DEFAULT_POOL_NAME}"
    
    log_info "Cleaning up all artifacts for build: $build_name"
    
    # Note: Docker containers are automatically removed via --rm flag in all docker run commands
    
    # Clean up systemd-nspawn container if it exists
    local container_name="$build_name"
    if declare -f container_cleanup_for_build >/dev/null 2>&1; then
        container_cleanup_for_build "$container_name"
    else
        log_debug "container_cleanup_for_build function not available"
    fi

    # Destroy ZFS dataset using the proper management script
    # Brief wait for container cleanup to fully complete
    sleep 1
    
    # Use the dedicated script that handles all ZFS operations properly
    # invoke_script_with_dry_run expects just the script name, it calculates the path
    local result=0
    invoke_script_with_dry_run "manage-root-datasets.sh" --force destroy "$build_name" || result=$?
    
    if [[ $result -eq 0 ]]; then
        log_debug "Successfully delegated ZFS cleanup to manage-root-datasets.sh"
    else
        log_debug "ZFS cleanup via manage-root-datasets.sh failed or dataset didn't exist (exit code: $result)"
    fi
    
    # Clean up mount directory if it exists
    local mount_dir="${DEFAULT_MOUNT_BASE}/${build_name}"
    if [[ -d "$mount_dir" ]] || [[ "${DRY_RUN:-false}" == "true" ]]; then
        log_info "Removing mount directory: $mount_dir"
        run_cmd rmdir "$mount_dir" || log_warn "Failed to remove mount directory: $mount_dir (may not be empty)"
    fi
    
    # Clear status files
    build_clear_status "$build_name"
    
    log_info "Cleanup completed for build: $build_name"
}

# Clean up all build artifacts in the status directory
# Usage: build_clean_all_artifacts [--force]
build_clean_all_artifacts() {
    local force_clean=false
    if [[ "$1" == "--force" ]]; then
        force_clean=true
        shift
    fi
    
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        if [[ "$force_clean" == "true" ]]; then
            echo "[DRY RUN] Would clean all artifacts in: $STATUS_DIR (including protected files)"
        else
            echo "[DRY RUN] Would clean all artifacts in: $STATUS_DIR"
        fi
        return 0
    fi
    
    if [[ "$force_clean" == "true" ]]; then
        echo "Force cleaning all artifacts (including protected files)"
        run_cmd rm -rf "${STATUS_DIR:?}"/*
        run_cmd rm -rf "${STATUS_DIR:?}"/.*
    else
        echo "Cleaning all build artifacts"
        run_cmd rm -f "${STATUS_DIR}"/*.status
        run_cmd rm -f "${STATUS_DIR}"/*.log
        run_cmd rm -rf "${STATUS_DIR}/temp"
    fi
}

# ==============================================================================
# BUILD LOGGING INTEGRATION
# ==============================================================================

# Log a build event to the persistent build log
# Usage: build_log_event "build-name" "message"
build_log_event() {
    local build_name="$1"
    local message="$2"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        echo "[DRY RUN] Would log event: $message"
        return 0
    fi
    
    echo "Logging event for $build_name: $message"
    
    local log_file
    log_file=$(build_get_log_file "$build_name")
    
    # Ensure log directory exists
    run_cmd mkdir -p "$(dirname "$log_file")"
    
    # Append to build log
    local context_prefix=""
    if [[ -n "${BUILD_LOG_CONTEXT:-}" ]]; then
        context_prefix="[$BUILD_LOG_CONTEXT] "
    fi
    run_cmd sh -c "echo '${timestamp} [INFO] ${context_prefix}${message}' >> '$log_file'"
}

# Set up build logging context for integration with main logging system
# Usage: build_set_logging_context "build-name" "context"
build_set_logging_context() {
    local build_name="$1"
    local context="${2:-}"
    
    echo "Setting logging context for $build_name: $context"
    
    # This sets the global BUILD_LOG_CONTEXT variable used by the logging system
    export BUILD_LOG_CONTEXT="$context"
}
