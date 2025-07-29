#!/usr/bin/env bash

# ==============================================================================
# ZFSBOOTMENU INTEGRATION LIBRARY
# ==============================================================================
# ZFSBootMenu integration and management for Ubuntu ZFS Installer
#
# This library provides essential functions for ZFSBootMenu EFI file discovery,
# version detection using checksums, and boot detection functionality.
#
# Author: Ubuntu ZFS Installer Team
# License: MIT
# ==============================================================================

# Ensure dependencies are available
if [[ -z "${ZFSBOOTMENU_LIB_DIR:-}" ]]; then
    if [[ -n "${BASH_SOURCE[0]}" ]]; then
        ZFSBOOTMENU_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    elif [[ -n "${ZFS_INSTALLER_LIB_DIR:-}" ]]; then
        ZFSBOOTMENU_LIB_DIR="$ZFS_INSTALLER_LIB_DIR"
    else
        # Fallback
        ZFSBOOTMENU_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    fi
fi

# Import dependencies
for lib in constants logging core; do
    if [[ -f "$ZFSBOOTMENU_LIB_DIR/$lib.sh" ]]; then
        source "$ZFSBOOTMENU_LIB_DIR/$lib.sh"
    fi
done

# ==============================================================================
# CORE FUNCTIONS
# ==============================================================================

# Get ZFSBootMenu search directories helper function  
# Usage: zfsbootmenu_get_search_dirs <output_array_name>
zfsbootmenu_get_search_dirs() {
    local -n dirs_ref=$1
    
    # Use configured directories with fallback to defaults
    local search_dirs_array
    if [[ -n "${ZBM_EFI_SEARCH_DIRS:-}" ]]; then
        search_dirs_array=("${ZBM_EFI_SEARCH_DIRS[@]}")
    else
        search_dirs_array=("${ZBM_DEFAULT_EFI_SEARCH_DIRS[@]}")
    fi
    
    # Initialize output array and add existing directories
    dirs_ref=()
    for dir in "${search_dirs_array[@]}"; do
        if [[ -d "$dir" ]]; then
            dirs_ref+=("$dir")
        fi
    done
}

# Get all configured search directories (including missing ones)
# Usage: zfsbootmenu_get_all_search_dirs <output_array_name>
zfsbootmenu_get_all_search_dirs() {
    # shellcheck disable=SC2034  # out_array is a nameref for output
    local -n out_array=$1

    if [[ -n "${ZBM_EFI_SEARCH_DIRS[*]:-}" ]]; then
        # shellcheck disable=SC2034  # out_array is a nameref for output
        out_array=("${ZBM_EFI_SEARCH_DIRS[@]}")
    else
        # shellcheck disable=SC2034  # out_array is a nameref for output
        out_array=("${ZBM_DEFAULT_EFI_SEARCH_DIRS[@]}")
    fi
}

# Discover all ZFSBootMenu EFI files in configured directories
# Usage: zfsbootmenu_discover_all_efi_files
zfsbootmenu_discover_all_efi_files() {
    local search_dirs
    zfsbootmenu_get_search_dirs search_dirs
    
    log_debug "Searching for ZFSBootMenu EFI files in: ${search_dirs[*]}"
    
    # Simple arrays to store file information
    local efi_files=()
    local file_versions=()
    local file_partitions=()
    local file_directories=()
    local file_purposes=()
    local file_sizes=()
    
    # Find all ZFSBootMenu EFI files
    for search_dir in "${search_dirs[@]}"; do
        if [[ -d "$search_dir" ]]; then
            while IFS= read -r -d '' efi_file; do
                if [[ -f "$efi_file" ]]; then
                    local version
                    version=$(zfsbootmenu_get_version_by_checksum "$efi_file")
                    
                    if [[ "$version" != "unknown" ]]; then
                        local filename
                        filename=$(basename "$efi_file")
                        
                        # Determine partition
                        local partition=""
                        if [[ "$efi_file" =~ /boot/efi2/ ]]; then
                            partition="efi2"
                        elif [[ "$efi_file" =~ /boot/efi/ ]]; then
                            partition="efi"
                        else
                            partition="unknown"
                        fi
                        
                        # Get directory relative to EFI root
                        local dir_name=""
                        if [[ "$efi_file" =~ /EFI/([^/]+) ]]; then
                            dir_name="${BASH_REMATCH[1]}"
                        else
                            dir_name="unknown"
                        fi
                        
                        # Determine file purpose/usage
                        local usage="Unknown"
                        case "$filename" in
                            "BOOTX64.EFI"|"bootx64.efi")
                                usage="Default UEFI boot loader"
                                ;;
                            "VMLINUZ.EFI"|"vmlinuz.efi")
                                usage="ZFSBootMenu primary image"
                                ;;
                            "VMLINUZ-BACKUP.EFI"|"vmlinuz-backup.efi")
                                usage="ZFSBootMenu backup image"
                                ;;
                            *"zfsbootmenu"*|*"zbm"*)
                                usage="ZFSBootMenu image"
                                ;;
                            *)
                                usage="ZFSBootMenu image (generic)"
                                ;;
                        esac
                        
                        # Get file size
                        local file_size
                        if file_size=$(stat -c%s "$efi_file" 2>/dev/null); then
                            file_size=$(numfmt --to=iec --suffix=B "$file_size" 2>/dev/null || echo "${file_size} bytes")
                        else
                            file_size="unknown"
                        fi
                        
                        # Store in arrays
                        efi_files+=("$filename")
                        file_versions+=("$version")
                        file_partitions+=("$partition")
                        file_directories+=("$dir_name")
                        file_purposes+=("$usage")
                        file_sizes+=("$file_size")
                    fi
                fi
            done < <(find "$search_dir" -iname '*.efi' -print0 2>/dev/null || true)
        fi
    done
    
    if [[ ${#efi_files[@]} -eq 0 ]]; then
        echo "No ZFSBootMenu EFI files found"
        return 1
    fi
    
    # Print header
    echo "Found ${#efi_files[@]} EFI file(s) in the following directories:"
    for search_dir in "${search_dirs[@]}"; do
        echo "  $search_dir"
    done
    echo ""
    
    # Show EFI partitions found
    echo "EFI Partitions Found:"
    local all_search_dirs
    zfsbootmenu_get_all_search_dirs all_search_dirs
    
    for search_dir in "${all_search_dirs[@]}"; do
        # Extract mount point and determine partition name
        local mount_point
        mount_point=$(echo "$search_dir" | sed 's|/EFI$||')
        
        local partition_name=""
        if [[ "$mount_point" =~ /boot/efi2$ ]]; then
            partition_name="efi2"
        elif [[ "$mount_point" =~ /boot/efi$ ]]; then
            partition_name="efi"
        else
            partition_name="unknown"
        fi
        
        # Check if directory exists and get device info
        local status=""
        local device_info=""
        local gpt_uuid=""
        if [[ -d "$search_dir" ]]; then
            status="✓"
            if device_info=$(findmnt -n -o SOURCE "$mount_point" 2>/dev/null); then
                # Get GPT UUID for this device
                gpt_uuid=$(blkid -s PARTUUID -o value "$device_info" 2>/dev/null || true)
                if [[ -n "$gpt_uuid" ]]; then
                    device_info=" (device: $device_info, GPT: $gpt_uuid)"
                else
                    device_info=" (device: $device_info)"
                fi
            fi
        else
            status="✗"
            device_info=" (not mounted/missing)"
        fi
        
        printf "  %s %-8s %s%s\n" "$status" "$partition_name" "$mount_point" "$device_info"
    done
    echo ""
    
    # Detect which EFI file was used to boot
    local last_boot_efi=""
    last_boot_efi=$(zfsbootmenu_detect_last_boot_efi 2>/dev/null || true)
    log_debug "Detected last boot EFI file: ${last_boot_efi:-"not detected"}"
    
    # Get version and checksum from first file
    local first_version="${file_versions[0]}"
    local first_size="${file_sizes[0]}"
    local first_checksum=""
    if [[ ${#efi_files[@]} -gt 0 ]]; then
        # Find the first file to get checksum
        for search_dir in "${search_dirs[@]}"; do
            if [[ -d "$search_dir" ]]; then
                local first_file
                first_file=$(find "$search_dir" -name "${efi_files[0]}" -type f 2>/dev/null | head -1)
                if [[ -n "$first_file" ]]; then
                    first_checksum=$(sha256sum "$first_file" 2>/dev/null | cut -d' ' -f1)
                    break
                fi
            fi
        done
        
        # Get latest version for comparison
        local latest_version=""
        local update_status=""
        if latest_version=$(zfsbootmenu_get_latest_version 2>/dev/null); then
            if [[ "$first_version" == "$latest_version" ]]; then
                update_status=" (latest)"
            else
                update_status=" ($(printf '\033[1;33mUPDATE AVAILABLE: %s\033[0m' "$latest_version"))"
            fi
        else
            update_status=" (latest version check failed)"
        fi
        
        echo -e "Version: $first_version (pre-built image)$update_status"
        echo "Size: $first_size | SHA256: $first_checksum"
        echo "$(printf '=%.0s' $(seq 1 90))"
        echo ""
    fi
    
    # Print table header
    printf "%-10s %-20s %-30s %-30s %-15s\n" "Partition" "Directory" "Filename" "Purpose" "Status"
    printf "%-10s %-20s %-30s %-30s %-15s\n" "----------" "--------------------" "------------------------------" "------------------------------" "---------------"
    
    # Group files and show unique combinations
    local shown_combinations=()
    
    for ((i=0; i<${#efi_files[@]}; i++)); do
        local filename="${efi_files[i]}"
        local partition="${file_partitions[i]}"
        local directory="${file_directories[i]}"
        local purpose="${file_purposes[i]}"
        local file_size="${file_sizes[i]}"
        
        # Create combination key
        local combo_key="${filename}|${directory}|${purpose}"
        
        # Check if we've already shown this combination
        local already_shown=false
        for shown in "${shown_combinations[@]}"; do
            if [[ "$shown" == "$combo_key" ]]; then
                already_shown=true
                break
            fi
        done
        
        if [[ "$already_shown" == "false" ]]; then
            # Find all partitions that have this file combination
            local partitions_with_file=()
            for ((j=0; j<${#efi_files[@]}; j++)); do
                if [[ "${efi_files[j]}|${file_directories[j]}|${file_purposes[j]}" == "$combo_key" ]]; then
                    partitions_with_file+=("${file_partitions[j]}")
                fi
            done
            
            # Determine partition display
            local partition_display=""
            if [[ ${#partitions_with_file[@]} -gt 1 ]]; then
                partition_display="both"
            else
                partition_display="${partitions_with_file[0]}"
            fi
            
            # Determine boot status
            local boot_status=""
            if [[ -n "$last_boot_efi" ]]; then
                # Check if this file was used to boot
                local file_found=false
                for ((j=0; j<${#efi_files[@]}; j++)); do
                    if [[ "${efi_files[j]}|${file_directories[j]}|${file_purposes[j]}" == "$combo_key" ]]; then
                        # Find the actual file path to compare
                        for search_dir in "${search_dirs[@]}"; do
                            if [[ -d "$search_dir" ]]; then
                                local full_path="$search_dir/${file_directories[j]}/${efi_files[j]}"
                                if [[ -f "$full_path" && "$full_path" == "$last_boot_efi" ]]; then
                                    boot_status="$(printf '\033[1;32mLAST BOOT\033[0m')"
                                    file_found=true
                                    break
                                fi
                            fi
                        done
                        if [[ "$file_found" == "true" ]]; then
                            break
                        fi
                    fi
                done
                
                if [[ "$boot_status" == "" ]]; then
                    boot_status="Available"
                fi
            else
                boot_status="Available"
            fi
            
            # Display the main row
            printf "%-10s %-20s %-30s %-30s " "$partition_display" "$directory" "$filename" "$purpose"
            printf "%s\n" "$boot_status"
            
            # Mark this combination as shown
            shown_combinations+=("$combo_key")
        fi
    done
    
    # Show configuration information
    echo ""
    echo "Config file: $ZBM_CONFIG_FILE $(if [[ -f "$ZBM_CONFIG_FILE" ]]; then echo "✓"; else echo "✗ not found"; fi)"
    
    return 0
}

# Detect which EFI file was used for the last boot using multiple methods
# Usage: zfsbootmenu_detect_last_boot_efi
zfsbootmenu_detect_last_boot_efi() {
    local boot_efi=""
    
    # Get search directories from config or use defaults
    local search_dirs
    zfsbootmenu_get_search_dirs search_dirs
    
    # Method 1: Check UEFI boot manager for last boot entry
    if command -v efibootmgr >/dev/null 2>&1; then
        local boot_current
        boot_current=$(efibootmgr | grep "BootCurrent:" | awk '{print $2}' 2>/dev/null || true)
        
        if [[ -n "$boot_current" ]]; then
            local boot_entry
            boot_entry=$(efibootmgr -v | grep "Boot${boot_current}" | head -1 2>/dev/null || true)
            
            local gpt_uuid=""
            local efi_subdir=""
            local efi_filename=""
            
            # Extract GPT UUID
            if [[ "$boot_entry" =~ HD\([^,]+,GPT,([^,]+), ]]; then
                gpt_uuid="${BASH_REMATCH[1]}"
            fi
            
            # Extract EFI path
            if [[ "$boot_entry" =~ \\EFI\\([^\\]+)\\([^\\]+\.EFI) ]]; then
                efi_subdir="${BASH_REMATCH[1]}"
                efi_filename="${BASH_REMATCH[2]}"
            fi
            
            if [[ -n "$gpt_uuid" && -n "$efi_subdir" && -n "$efi_filename" ]]; then
                log_debug "Boot entry GPT UUID: $gpt_uuid, subdir: $efi_subdir, filename: $efi_filename"
                
                # Find device with this GPT UUID
                local boot_device
                boot_device=$(blkid | grep -i "$gpt_uuid" | cut -d: -f1 | head -1)
                
                log_debug "Found boot device: ${boot_device:-"not found"}"
                
                if [[ -n "$boot_device" ]]; then
                    # Find where this device is mounted
                    local mount_point
                    mount_point=$(findmnt -n -o TARGET "$boot_device" 2>/dev/null || true)
                    
                    log_debug "Device mount point: ${mount_point:-"not mounted"}"
                    
                    if [[ -n "$mount_point" ]]; then
                        # Check if this mount point corresponds to one of our search directories
                        for search_dir in "${search_dirs[@]}"; do
                            # Extract the base mount point from search dir (remove /EFI suffix)
                            local base_mount
                            base_mount=$(echo "$search_dir" | sed 's|/EFI$||')
                            
                            if [[ "$mount_point" == "$base_mount" ]]; then
                                local potential_path="$search_dir/$efi_subdir/$efi_filename"
                                if [[ -f "$potential_path" ]]; then
                                    boot_efi="$potential_path"
                                    log_debug "Found boot EFI file: $boot_efi"
                                    break
                                fi
                            fi
                        done
                    fi
                fi
            fi
        fi
    fi
    
    # Method 2: Check systemd-boot if available
    if [[ -z "$boot_efi" ]] && command -v bootctl >/dev/null 2>&1; then
        local boot_info
        if boot_info=$(bootctl status 2>/dev/null); then
            # Look for current boot entry file
            local current_entry
            current_entry=$(echo "$boot_info" | grep -E "Selected|Current" | head -1 | awk '{print $NF}' 2>/dev/null || true)
            
            if [[ -n "$current_entry" && "$current_entry" =~ \.efi$ ]]; then
                # Try to find this EFI file in our search directories
                for search_dir in "${search_dirs[@]}"; do
                    if [[ -d "$search_dir" ]]; then
                        local found_file
                        found_file=$(find "$search_dir" -name "$current_entry" -type f 2>/dev/null | head -1)
                        if [[ -n "$found_file" ]]; then
                            boot_efi="$found_file"
                            break
                        fi
                    fi
                done
            fi
        fi
    fi
    
    # Method 3: Check for most recently accessed EFI file (heuristic)
    if [[ -z "$boot_efi" ]]; then
        local newest_file=""
        local newest_time=0
        
        for search_dir in "${search_dirs[@]}"; do
            if [[ -d "$search_dir" ]]; then
                while IFS= read -r -d '' efi_file; do
                    if [[ -f "$efi_file" ]]; then
                        # Check if it's a ZFSBootMenu file
                        local version
                        version=$(zfsbootmenu_get_version_by_checksum "$efi_file")
                        
                        if [[ "$version" != "unknown" ]]; then
                            # Get access time
                            local access_time
                            access_time=$(stat -c%X "$efi_file" 2>/dev/null || echo "0")
                            
                            if [[ $access_time -gt $newest_time ]]; then
                                newest_time=$access_time
                                newest_file="$efi_file"
                            fi
                        fi
                    fi
                done < <(find "$search_dir" \( -name '*.EFI' -o -name '*.efi' \) -print0 2>/dev/null || true)
            fi
        done
        
        if [[ -n "$newest_file" ]]; then
            boot_efi="$newest_file"
        fi
    fi
    
    if [[ -n "$boot_efi" ]]; then
        echo "$boot_efi"
    else
        log_debug "Could not determine last boot EFI file"
        return 1
    fi
}

# Get ZFSBootMenu version by checking SHA256 checksums
# Usage: zfsbootmenu_get_version_by_checksum [file_path]
zfsbootmenu_get_version_by_checksum() {
    local target_file="$1"
    local checksum_db="$ZBM_VENDOR_DIR/checksums.txt"
    
    # Check if checksum database exists
    if [[ ! -f "$checksum_db" ]]; then
        log_debug "ZFSBootMenu checksum database not found: $checksum_db"
        echo "unknown"
        return 0
    fi
    
    # If a specific file is provided, check only that file
    if [[ -n "$target_file" && -f "$target_file" ]]; then
        local file_checksum
        if file_checksum=$(sha256sum "$target_file" 2>/dev/null | cut -d' ' -f1); then
            local version
            if version=$(grep "^$file_checksum " "$checksum_db" | head -1 | awk '{print $2}'); then
                if [[ -n "$version" ]]; then
                    echo "$version"
                    return 0
                fi
            fi
        fi
        echo "unknown"
        return 0
    fi
    
    # If no specific file, search all EFI files in configured directories
    log_debug "Searching for ZFSBootMenu EFI files in configured directories..."
    
    local search_dirs
    zfsbootmenu_get_search_dirs search_dirs
    
    local efi_files=()
    for search_dir in "${search_dirs[@]}"; do
        if [[ -d "$search_dir" ]]; then
            log_debug "Scanning directory: $search_dir"
            # Find all .EFI files recursively
            while IFS= read -r -d '' file; do
                efi_files+=("$file")
                log_debug "Found EFI file: $file"
            done < <(find "$search_dir" -type f -iname "*.efi" -print0 2>/dev/null)
        else
            log_debug "Directory not found: $search_dir"
        fi
    done
    
    if [[ ${#efi_files[@]} -eq 0 ]]; then
        log_debug "No EFI files found in any search directory"
        echo "unknown"
        return 0
    fi
    
    log_debug "Found ${#efi_files[@]} EFI files to check"
    
    # Check each EFI file against the checksum database
    for efi_file in "${efi_files[@]}"; do
        log_debug "Computing checksum for: $efi_file"
        
        # Compute SHA256 of the EFI file
        local file_checksum
        if ! file_checksum=$(sha256sum "$efi_file" 2>/dev/null | cut -d' ' -f1); then
            log_debug "Failed to compute checksum for: $efi_file"
            continue
        fi
        
        log_debug "Checksum: $file_checksum"
        
        # Look up the checksum in the database
        local version
        if version=$(grep "^$file_checksum " "$checksum_db" | head -1 | awk '{print $2}'); then
            if [[ -n "$version" ]]; then
                log_debug "Found matching version for $efi_file: $version"
                echo "$version"
                return 0
            fi
        fi
    done
    
    log_debug "No matching checksums found in database"
    echo "unknown"
    return 0
}

# Get the latest ZFSBootMenu version from GitHub
# Usage: zfsbootmenu_get_latest_version
zfsbootmenu_get_latest_version() {
    log_debug "Checking latest ZFSBootMenu version from GitHub"
    
    local api_response
    local latest_version
    
    # Use timeout to prevent hanging
    if api_response=$(curl -s --connect-timeout "${ZBM_VERSION_CHECK_TIMEOUT:-10}" \
        --max-time "${ZBM_VERSION_CHECK_TIMEOUT:-10}" \
        "${ZBM_GITHUB_LATEST_URL:-https://api.github.com/repos/zbm-dev/zfsbootmenu/releases/latest}" 2>/dev/null); then
        
        # Extract tag name from JSON response
        latest_version=$(echo "$api_response" | grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' | \
            sed 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
        
        if [[ -n "$latest_version" && "$latest_version" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+ ]]; then
            # Remove 'v' prefix if present
            echo "$latest_version" | sed 's/^v//'
        else
            log_warn "Failed to parse version from GitHub API response"
            return 1
        fi
    else
        log_warn "Failed to fetch latest version from GitHub API"
        return 1
    fi
}
