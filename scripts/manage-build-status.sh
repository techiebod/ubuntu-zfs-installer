#!/bin/bash
#
# Build status management for ZFS build system
#

# --- Script Setup ---
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(dirname "$script_dir")"
# shellcheck source=../lib/common.sh
source "$project_dir/lib/common.sh"

# --- Constants ---
# STATUS_DIR is now loaded from global configuration
STATUS_FILE_SUFFIX=".status"
BUILD_LOG_SUFFIX=".log"

# Status values
STATUS_STARTED="started"
STATUS_DATASETS_CREATED="datasets-created"
STATUS_OS_INSTALLED="os-installed"
STATUS_VARLOG_MOUNTED="varlog-mounted"
STATUS_CONTAINER_CREATED="container-created"
STATUS_ANSIBLE_CONFIGURED="ansible-configured"
STATUS_COMPLETED="completed"
STATUS_FAILED="failed"

# All valid statuses in order
VALID_STATUSES=(
    "$STATUS_STARTED"
    "$STATUS_DATASETS_CREATED"
    "$STATUS_OS_INSTALLED"
    "$STATUS_VARLOG_MOUNTED"
    "$STATUS_CONTAINER_CREATED"
    "$STATUS_ANSIBLE_CONFIGURED"
    "$STATUS_COMPLETED"
)

# Status progression map - what comes next after each status
declare -A NEXT_STATUS=(
    ["$STATUS_STARTED"]="$STATUS_DATASETS_CREATED"
    ["$STATUS_DATASETS_CREATED"]="$STATUS_OS_INSTALLED"
    ["$STATUS_OS_INSTALLED"]="$STATUS_VARLOG_MOUNTED"
    ["$STATUS_VARLOG_MOUNTED"]="$STATUS_CONTAINER_CREATED"
    ["$STATUS_CONTAINER_CREATED"]="$STATUS_ANSIBLE_CONFIGURED"
    ["$STATUS_ANSIBLE_CONFIGURED"]="$STATUS_COMPLETED"
    ["$STATUS_FAILED"]="$STATUS_DATASETS_CREATED"
)

# --- Functions ---

get_status_file() {
    local build_name="$1"
    echo "${STATUS_DIR}/${build_name}${STATUS_FILE_SUFFIX}"
}

get_log_file() {
    local build_name="$1"
    echo "${STATUS_DIR}/${build_name}${BUILD_LOG_SUFFIX}"
}

# Parse status file line: "TIMESTAMP STATUS=value"
# Returns: "timestamp status" (space-separated)
parse_status_line() {
    local line="$1"
    local timestamp=$(echo "$line" | awk '{print $1}')
    local status=$(echo "$line" | sed -n 's/.*STATUS=\([^ ]*\).*/\1/p')
    echo "$timestamp $status"
}

# Get the last status entry from a status file
# Returns: "timestamp status" (space-separated)
get_last_status_entry() {
    local status_file="$1"
    if [[ ! -f "$status_file" ]]; then
        return 1
    fi
    local last_line=$(tail -n 1 "$status_file")
    parse_status_line "$last_line"
}

# Format duration in seconds to human-readable string
format_duration() {
    local duration="$1"
    local duration_str=""
    
    if [[ $duration -le 0 ]]; then
        echo "0s"
        return
    fi
    
    if [[ $duration -ge 3600 ]]; then
        duration_str="${duration_str}$((duration / 3600))h "
        duration=$((duration % 3600))
    fi
    if [[ $duration -ge 60 ]]; then
        duration_str="${duration_str}$((duration / 60))m "
        duration=$((duration % 60))
    fi
    duration_str="${duration_str}${duration}s"
    echo "$duration_str"
}

# Calculate duration between two timestamps
calculate_duration() {
    local start_timestamp="$1"
    local end_timestamp="$2"
    local start_epoch=$(date -d "$start_timestamp" +%s 2>/dev/null || echo "0")
    local end_epoch=$(date -d "$end_timestamp" +%s 2>/dev/null || echo "0")
    echo $((end_epoch - start_epoch))
}

# Get path to manage script in same directory
get_manage_script_path() {
    local script_name="$1"
    echo "$script_dir/manage-${script_name}.sh"
}

log_build_event() {
    local build_name="$1"
    local message="$2"
    local log_file
    log_file=$(get_log_file "$build_name")
    
    # Ensure status directory exists
    mkdir -p "$STATUS_DIR"
    
    # Append to build log with timestamp
    echo "$(date -Iseconds) $message" >> "$log_file"
}

set_status() {
    local status="$1"
    local build_name="$2"
    local status_file
    status_file=$(get_status_file "$build_name")
    
    # Ensure status directory exists
    mkdir -p "$STATUS_DIR"
    
    # Append status with timestamp (append-only format)
    # Format: TIMESTAMP STATUS=value (build name is in filename)
    local timestamp=$(date -Iseconds)
    echo "$timestamp STATUS=$status" >> "$status_file"
    
    # Log the status change
    log_build_event "$build_name" "Status changed to: $status"
    
    log_debug "Status appended to: $status_file"
}

get_status() {
    local build_name="$1"
    local status_file
    status_file=$(get_status_file "$build_name")
    
    local entry
    entry=$(get_last_status_entry "$status_file") || return 1
    
    # Extract just the status part (second field)
    echo "$entry" | awk '{print $2}'
}

get_status_timestamp() {
    local build_name="$1"
    local status_file
    status_file=$(get_status_file "$build_name")
    
    local entry
    entry=$(get_last_status_entry "$status_file") || return 1
    
    # Extract just the timestamp part (first field)
    echo "$entry" | awk '{print $1}'
}

clear_status() {
    local build_name="$1"
    local status_file log_file
    status_file=$(get_status_file "$build_name")
    log_file=$(get_log_file "$build_name")
    
    # Use modern bash - remove files if they exist (no error if they don't)
    [[ -f "$status_file" ]] && { log_debug "Clearing build status for '$build_name'"; rm -f "$status_file"; }
    [[ -f "$log_file" ]] && { log_debug "Clearing build log for '$build_name'"; rm -f "$log_file"; }
}

clean_build() {
    local build_name="$1"
    local pool_name="${2:-$DEFAULT_POOL_NAME}"
    
    log_info "Starting complete cleanup for build: $build_name"
    
    # Step 1: Stop any running containers
    log_info "Stopping containers..."
    local container_output
    container_output=$("$script_dir/manage-root-containers.sh" stop --name "$build_name" "$build_name" 2>&1)
    local container_status=$?
    if [[ $container_status -eq 0 ]]; then
        log_info "Container stopped successfully"
    else
        log_debug "No container to stop or already stopped (exit code: $container_status)"
        if [[ -n "$container_output" ]]; then
            log_debug "Container stop output: $container_output"
        fi
    fi
    
    log_debug "Starting dataset destruction section..."
    # Step 2: Destroy ZFS datasets (this handles unmounting automatically)
    log_info "Destroying ZFS datasets..."
    log_info "About to call manage-root-datasets.sh destroy..."
    local dataset_output dataset_status
    # Use a temporary file to avoid subprocess exit issues
    local temp_output=$(mktemp)
    set +e  # Temporarily disable exit on error
    "$script_dir/manage-root-datasets.sh" destroy "$build_name" --force > "$temp_output" 2>&1
    dataset_status=$?
    set -e  # Re-enable exit on error
    dataset_output=$(cat "$temp_output")
    rm -f "$temp_output"
    log_info "Dataset destruction completed with status: $dataset_status"
    if [[ $dataset_status -eq 0 ]]; then
        log_info "ZFS datasets destroyed successfully"
    else
        log_warn "Failed to destroy ZFS datasets (exit code: $dataset_status)"
        if [[ -n "$dataset_output" ]]; then
            # Clean up the output by removing excessive indentation and showing key error info
            local clean_output
            clean_output=$(echo "$dataset_output" | sed 's/^[ \t]*//' | head -5)
            log_warn "Dataset destruction error:"
            # Print each line cleanly without excessive indentation
            while IFS= read -r line; do
                [[ -n "$line" ]] && log_warn "  $line"
            done <<< "$clean_output"
            # Check for common permission issues and fail the cleanup
            if echo "$dataset_output" | grep -q "must be superuser"; then
                log_error "Permission denied - cleanup requires sudo privileges"
                die "Run with sudo: sudo $0 clean $build_name"
            fi
        fi
        # If dataset destruction failed for other reasons, warn but continue
        log_warn "Dataset destruction failed - datasets may still exist"
    fi
    
    # Step 3: Clear status and logs (internal operation)
    log_info "Clearing build status and logs..."
    clear_status "$build_name"
    
    log_info "Complete cleanup finished for build: $build_name"
}

list_builds_with_status() {
    echo "Build Status Summary:"
    echo "===================="
    
    # Early return if no status directory
    [[ ! -d "$STATUS_DIR" ]] && { echo "No builds found."; return 0; }
    
    local found_any=false
    for status_file in "$STATUS_DIR"/*"$STATUS_FILE_SUFFIX"; do
        [[ ! -f "$status_file" ]] && continue
        
        found_any=true
        local build_name entry timestamp status
        build_name=$(basename "$status_file" "$STATUS_FILE_SUFFIX")
        entry=$(get_last_status_entry "$status_file")
        timestamp=$(echo "$entry" | awk '{print $1}')
        status=$(echo "$entry" | awk '{print $2}')
        
        printf "%-20s %-20s %s\n" "$build_name" "$status" "$timestamp"
    done
    
    [[ "$found_any" == false ]] && echo "No builds found."
}

show_build_details() {
    local build_name="$1"
    local pool_name="${2:-$DEFAULT_POOL_NAME}"  # Default to configured pool if not specified
    
    echo "Build Details for: $build_name"
    echo "================================="
    echo
    
    # --- Current Status ---
    local status_file
    status_file=$(get_status_file "$build_name")
    
    if [[ -f "$status_file" ]]; then
        local current_status
        current_status=$(get_status "$build_name")
        local current_timestamp
        current_timestamp=$(get_status_timestamp "$build_name")
        
        echo "📊 Current Status:"
        echo "   Status: $current_status"
        echo "   Last Updated: $current_timestamp"
        echo
        
        # --- Build Stage History ---
        echo "📈 Build Stage History:"
        local prev_timestamp=""
        local prev_status=""
        local stage_num=1
        
        while IFS= read -r line; do
            # Parse status line using helper
            local entry
            entry=$(parse_status_line "$line")
            local timestamp=$(echo "$entry" | awk '{print $1}')
            local status=$(echo "$entry" | awk '{print $2}')
            
            if [[ -n "$prev_timestamp" && -n "$prev_status" ]]; then
                # Calculate and format duration using helpers
                local duration
                duration=$(calculate_duration "$prev_timestamp" "$timestamp")
                
                if [[ $duration -gt 0 ]]; then
                    local duration_str
                    duration_str=$(format_duration "$duration")
                    echo "   $((stage_num-1)). $prev_status → $status (${duration_str})"
                else
                    echo "   $((stage_num-1)). $prev_status → $status"
                fi
            else
                echo "   $stage_num. $status (started: $timestamp)"
            fi
            
            prev_timestamp="$timestamp"
            prev_status="$status"
            ((stage_num++))
        done < "$status_file"
        echo
    else
        echo "📊 Current Status: No status file found"
        echo
    fi
    
    # --- ZFS Dataset Information ---
    echo "💾 ZFS Datasets:"
    local datasets_script
    datasets_script=$(get_manage_script_path "root-datasets")
    local dataset_info
    dataset_info=$(command -v "$datasets_script" >/dev/null && 
        "$datasets_script" --pool "$pool_name" list 2>/dev/null | grep "${build_name}" || 
        echo "Dataset: ${pool_name}/ROOT/${build_name} (not found)")
    echo "   $dataset_info"
    echo
    
    # --- Snapshots ---
    echo "📸 ZFS Snapshots:"
    local snapshots_script
    snapshots_script=$(get_manage_script_path "root-snapshots")
    local snapshot_info
    snapshot_info=$(command -v "$snapshots_script" >/dev/null && 
        "$snapshots_script" --pool "$pool_name" list "$build_name" 2>/dev/null || 
        echo "No snapshots found for ${build_name}")
    # Indent output if we got multi-line results
    [[ "$snapshot_info" == *$'\n'* ]] && 
        echo "$snapshot_info" | sed 's/^/   /' || echo "   $snapshot_info"
    echo
    
    # --- Container Status ---
    echo "🐳 Container Status:"
    local container_name="${build_name}"
    local containers_script
    containers_script=$(get_manage_script_path "root-containers")
    local container_info
    container_info=$(command -v "$containers_script" >/dev/null && 
        "$containers_script" list 2>/dev/null | grep "$container_name" || 
        echo "Container: $container_name (not found or not running)")
    echo "   $container_info"
    echo
    
    # --- Mount Points ---
    echo "🗂️  Mount Points:"
    local base_mount="$DEFAULT_MOUNT_BASE/${build_name}"
    local varlog_mount="${base_mount}/var/log"
    
    local datasets_script
    datasets_script=$(get_manage_script_path "root-datasets")
    if command -v "$datasets_script" >/dev/null; then
        # Try to get mount information from the dataset script
        # Check if the base mount directory exists and has content
        if [[ -d "$base_mount" ]] && [[ "$(ls -A "$base_mount" 2>/dev/null)" ]]; then
            echo "   Root: $base_mount (mounted and populated)"
            # Check disk usage if mounted
            if mountpoint -q "$base_mount" 2>/dev/null; then
                local df_info
                df_info=$(df -h "$base_mount" 2>/dev/null | tail -1 | awk '{print $3 "/" $2 " (" $5 " used)"}')
                echo "     Space: $df_info"
            fi
        else
            echo "   Root: $base_mount (not mounted or empty)"
        fi
        
        if [[ -d "$varlog_mount" ]]; then
            echo "   Varlog: $varlog_mount (directory exists)"
        else
            echo "   Varlog: $varlog_mount (not mounted)"
        fi
    else
        echo "   Root: $base_mount (expected)"
        echo "   Varlog: $varlog_mount (expected)"
    fi
    echo
    
    # --- Build Log (Recent Activity) ---
    echo "📜 Recent Build Log (last 10 lines):"
    local log_file
    log_file=$(get_log_file "$build_name")
    
    [[ -f "$log_file" ]] && tail -10 "$log_file" | sed 's/^/   /' || echo "   No build log found"
}

show_build_history() {
    local build_name="$1"
    local status_file
    status_file=$(get_status_file "$build_name")
    
    # Early return if no history
    [[ ! -f "$status_file" ]] && { echo "No build history found for: $build_name"; return 1; }
    
    echo "Build History for: $build_name"
    echo "=============================="
    echo
    
    local prev_timestamp=""
    local prev_status=""
    local stage_num=1
    local total_duration=0
    
    echo "Stage Progression & Timings:"
    echo "----------------------------"
    
    while IFS= read -r line; do
        # Parse status line using helper
        local entry
        entry=$(parse_status_line "$line")
        local timestamp=$(echo "$entry" | awk '{print $1}')
        local status=$(echo "$entry" | awk '{print $2}')
        
        if [[ -n "$prev_timestamp" && -n "$prev_status" ]]; then
            # Calculate and format duration using helpers
            local duration
            duration=$(calculate_duration "$prev_timestamp" "$timestamp")
            total_duration=$((total_duration + duration))
            
            if [[ $duration -gt 0 ]]; then
                local duration_str
                duration_str=$(format_duration "$duration")
                printf "  %2d. %-18s → %-18s (%s)\n" $((stage_num-1)) "$prev_status" "$status" "$duration_str"
            else
                printf "  %2d. %-18s → %-18s\n" $((stage_num-1)) "$prev_status" "$status"
            fi
        else
            printf "  %2d. %-18s (started: %s)\n" "$stage_num" "$status" "$timestamp"
        fi
        
        prev_timestamp="$timestamp"
        prev_status="$status"
        ((stage_num++))
    done < "$status_file"
    
    # Show total time if we have multiple stages
    if [[ $stage_num -gt 2 && $total_duration -gt 0 ]]; then
        echo
        echo "Total Build Time:"
        echo "-----------------"
        local total_str
        total_str=$(format_duration "$total_duration")
        echo "  Total: $total_str"
    fi
}

get_next_stage() {
    local current_status="$1"
    echo "${NEXT_STATUS[$current_status]:-}"
}

should_run_stage() {
    local stage="$1"
    local build_name="$2"
    local force_restart="${3:-false}"
    
    # Force restart always runs
    [[ "$force_restart" == true ]] && return 0
    
    local current_status
    current_status=$(get_status "$build_name")
    
    # No status file = run first stage only
    [[ -z "$current_status" ]] && [[ "$stage" == "$STATUS_DATASETS_CREATED" ]] && return 0
    [[ -z "$current_status" ]] && return 1
    
    # Completed builds don't run more stages
    [[ "$current_status" == "$STATUS_COMPLETED" ]] && return 1
    
    # Check if the requested stage comes after the current status in the progression
    # Find the index of current status and requested stage in VALID_STATUSES array
    local current_index=-1
    local stage_index=-1
    
    for i in "${!VALID_STATUSES[@]}"; do
        [[ "${VALID_STATUSES[$i]}" == "$current_status" ]] && current_index=$i
        [[ "${VALID_STATUSES[$i]}" == "$stage" ]] && stage_index=$i
    done
    
    # Stage should run if it comes after the current status in the sequence
    [[ $stage_index -gt $current_index ]]
}

# --- Usage Information ---
show_usage() {
    cat << EOF
Usage: $0 ACTION [OPTIONS] BUILD_NAME

Manages build status and logs for ZFS build system.
This script focuses on status tracking and integrates information from other manage-* scripts.

ACTIONS:
  set STATUS BUILD_NAME       Set status for a build
  get BUILD_NAME              Get current status for a build
  clean BUILD_NAME [POOL]     Complete cleanup - stop container, destroy datasets, clear status
  list                        List all builds with their status
  show BUILD_NAME [POOL]      Show comprehensive build information (integrates data from other scripts)
  history BUILD_NAME          Show build stage progression and timing history
  log BUILD_NAME MESSAGE      Add a log entry for a build
  next BUILD_NAME             Get next stage that should be run
  should-run STAGE BUILD_NAME Check if a stage should be run

RELATED COMMANDS:
  For direct infrastructure management, use:
  - scripts/manage-root-datasets.sh    (ZFS dataset operations)
  - scripts/manage-root-snapshots.sh   (ZFS snapshot operations) 
  - scripts/manage-root-containers.sh  (Container lifecycle management)

VALID STATUSES:
$(printf "  %s\n" "${VALID_STATUSES[@]}")
  failed

EXAMPLES:
  # Set status
  $0 set datasets-created ubuntu-noble

  # Get current status
  $0 get ubuntu-noble

  # Complete cleanup of a build
  $0 clean ubuntu-noble
  $0 clean ubuntu-noble tank

  # Show detailed build information
  $0 show ubuntu-noble
  $0 show ubuntu-noble tank

  # Show build stage history and timings
  $0 history ubuntu-noble

  # Add log entry
  $0 log ubuntu-noble "Starting custom configuration"

  # Check if stage should run
  $0 should-run os-installed ubuntu-noble

  # List all builds
  $0 list
EOF
    exit 0
}

# --- Main Logic ---
main() {
    if [[ $# -eq 0 ]]; then
        show_usage
    fi

    local action="$1"
    shift

    case "$action" in
        set)
            if [[ $# -ne 2 ]]; then
                die "Usage: $0 set STATUS BUILD_NAME"
            fi
            set_status "$1" "$2"
            ;;
        get)
            if [[ $# -ne 1 ]]; then
                die "Usage: $0 get BUILD_NAME"
            fi
            get_status "$1"
            ;;
        clean)
            if [[ $# -lt 1 ]]; then
                die "Usage: $0 clean BUILD_NAME [POOL]"
            fi
            local pool_name="${2:-$DEFAULT_POOL_NAME}"
            clean_build "$1" "$pool_name"
            ;;
        clear)
            # Internal command - not documented in usage
            if [[ $# -ne 1 ]]; then
                die "Usage: $0 clear BUILD_NAME"
            fi
            clear_status "$1"
            ;;
        list)
            list_builds_with_status
            ;;
        show)
            if [[ $# -lt 1 ]]; then
                die "Usage: $0 show BUILD_NAME [POOL]"
            fi
            local pool_name="${2:-$DEFAULT_POOL_NAME}"
            show_build_details "$1" "$pool_name"
            ;;
        history)
            if [[ $# -ne 1 ]]; then
                die "Usage: $0 history BUILD_NAME"
            fi
            show_build_history "$1"
            ;;
        log)
            if [[ $# -ne 2 ]]; then
                die "Usage: $0 log BUILD_NAME MESSAGE"
            fi
            log_build_event "$1" "$2"
            ;;
        next)
            if [[ $# -ne 1 ]]; then
                die "Usage: $0 next BUILD_NAME"
            fi
            local current_status
            current_status=$(get_status "$1")
            if [[ -n "$current_status" ]]; then
                get_next_stage "$current_status"
            fi
            ;;
        should-run)
            if [[ $# -lt 2 ]]; then
                die "Usage: $0 should-run STAGE BUILD_NAME [force]"
            fi
            local force="${3:-false}"
            if should_run_stage "$1" "$2" "$force"; then
                echo "yes"
                exit 0
            else
                echo "no"
                exit 1
            fi
            ;;
        --help|-h)
            show_usage
            ;;
        *)
            die "Unknown action: $action. Use --help for usage information."
            ;;
    esac
}

# --- Execute Main Function ---
main "$@"
