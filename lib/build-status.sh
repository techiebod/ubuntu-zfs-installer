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
    
    log_debug "Setting build status: $build_name -> $status"
    
    # Validate status
    local valid=false
    for valid_status in "${VALID_STATUSES[@]}"; do
        if [[ "$status" == "$valid_status" ]]; then
            valid=true
            break
        fi
    done
    
    if [[ "$valid" != true ]]; then
        die "Invalid build status: '$status'. Valid statuses: ${VALID_STATUSES[*]}"
    fi
    
    local status_file
    status_file=$(build_get_status_file "$build_name")
    
    # Ensure status directory exists
    mkdir -p "$(dirname "$status_file")"
    
    # Use new format with timestamp|status|message for better structure
    echo "${timestamp}|${status}|${message}" >> "$status_file"
    
    log_debug "Build status updated: $build_name = $status"
}

# Get the current status for a build
# Usage: build_get_status "build-name"
build_get_status() {
    local build_name="$1"
    local last_entry
    
    if ! last_entry=$(build_get_last_status_entry "$build_name"); then
        return 1
    fi
    
    # Extract status from last entry
    local parsed
    parsed=($(build_parse_status_line "$last_entry"))
    echo "${parsed[1]}"
}

# Get the timestamp for the current status
# Usage: build_get_status_timestamp "build-name"
build_get_status_timestamp() {
    local build_name="$1"
    local last_entry
    
    if ! last_entry=$(build_get_last_status_entry "$build_name"); then
        return 1
    fi
    
    # Extract timestamp from last entry
    local parsed
    parsed=($(build_parse_status_line "$last_entry"))
    echo "${parsed[0]}"
}

# Clear all status information for a build
# Usage: build_clear_status "build-name"
build_clear_status() {
    local build_name="$1"
    local status_file
    local log_file
    
    status_file=$(build_get_status_file "$build_name")
    log_file=$(build_get_log_file "$build_name")
    
    log_debug "Clearing build status for: $build_name"
    
    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY RUN] Would remove status files for: $build_name"
        return 0
    fi
    
    [[ -f "$status_file" ]] && rm -f "$status_file"
    [[ -f "$log_file" ]] && rm -f "$log_file"
    
    log_debug "Cleared status files for: $build_name"
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
    
    # Stage should run if it comes after the current status in the sequence
    if [[ $stage_index -gt $current_index ]]; then
        log_debug "Stage $stage should run (current: $current_status)"
        return 0
    else
        log_debug "Stage $stage should not run (current: $current_status)"
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
            parsed=($(build_parse_status_line "$last_entry"))
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
    dataset=$(zfs_get_root_dataset_path "$pool_name" "$build_name")
    if zfs_dataset_exists "$dataset"; then
        echo "ZFS Dataset Information:"
        echo "  Dataset: $dataset"
        
        local used
        used=$(zfs_get_property "$dataset" "used" 2>/dev/null || echo "unknown")
        echo "  Used Space: $used"
        
        local mountpoint
        mountpoint=$(zfs_get_property "$dataset" "mountpoint" 2>/dev/null || echo "unknown")
        echo "  Mountpoint: $mountpoint"
        
        local canmount
        canmount=$(zfs_get_property "$dataset" "canmount" 2>/dev/null || echo "unknown")
        echo "  Can Mount: $canmount"
        
        # Check for varlog dataset
        local varlog_dataset="${dataset}/varlog"
        if zfs_dataset_exists "$varlog_dataset"; then
            echo "  Varlog Dataset: exists"
        else
            echo "  Varlog Dataset: not found"
        fi
        
        # List snapshots
        local snapshots
        snapshots=($(zfs_list_snapshots "$dataset" "$SNAPSHOT_PREFIX" 2>/dev/null))
        if [[ ${#snapshots[@]} -gt 0 ]]; then
            echo "  Snapshots: ${#snapshots[@]} found"
        else
            echo "  Snapshots: none found"
        fi
    else
        echo "ZFS Dataset: not found ($dataset)"
    fi
    
    echo
    
    # Container information
    local container_name="$build_name"
    local container_status
    container_status=$(container_get_detailed_status "$container_name")
    echo "Container Status: $container_status"
    
    echo
}

# Show build history with stage progression and timing
# Usage: build_show_history "build-name"
build_show_history() {
    local build_name="$1"
    local status_file
    status_file=$(build_get_status_file "$build_name")
    
    if [[ ! -f "$status_file" ]]; then
        echo "No build history found for: $build_name"
        return 1
    fi
    
    log_info "Build History for: $build_name"
    echo
    echo "Stage Progression & Timings:"
    printf "%-25s %-20s %-25s %s\n" "Status" "Duration" "Timestamp" "Message"
    printf "%-25s %-20s %-25s %s\n" "-------------------------" "--------------------" "-------------------------" "-------"
    
    local prev_timestamp=""
    local first_timestamp=""
    local last_timestamp=""
    
    while IFS= read -r line; do
        if [[ -z "$line" ]]; then continue; fi
        
        local parsed
        parsed=($(build_parse_status_line "$line"))
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
        
    done < "$status_file"
    
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

# Clean up all artifacts for a build (datasets, containers, status)
# Usage: build_clean_all_artifacts "build-name" [pool-name]
build_clean_all_artifacts() {
    local build_name="$1"
    local pool_name="${2:-$DEFAULT_POOL_NAME}"
    
    log_info "Cleaning up all artifacts for build: $build_name"
    
    # Stop and destroy container if it exists
    local container_name="$build_name"
    container_cleanup_for_build "$container_name"
    
    # Destroy ZFS dataset and all snapshots
    local dataset
    dataset=$(zfs_get_root_dataset_path "$pool_name" "$build_name")
    if zfs_dataset_exists "$dataset"; then
        log_info "Destroying ZFS dataset and snapshots: $dataset"
        zfs_destroy_dataset "$dataset" --force
    fi
    
    # Clear status files
    build_clear_status "$build_name"
    
    log_info "Cleanup completed for build: $build_name"
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
    timestamp=$(date -Iseconds)
    
    local log_file
    log_file=$(build_get_log_file "$build_name")
    
    # Ensure log directory exists
    mkdir -p "$(dirname "$log_file")"
    
    # Append to build log
    echo "${timestamp} [INFO] ${message}" >> "$log_file"
    
    log_debug "Logged build event for $build_name: $message"
}

# Set up build logging context for integration with main logging system
# Usage: build_set_logging_context "build-name"
build_set_logging_context() {
    local build_name="$1"
    
    # This sets the global BUILD_LOG_CONTEXT variable used by the logging system
    BUILD_LOG_CONTEXT="$build_name"
    
    log_debug "Build logging context set to: $build_name"
}
