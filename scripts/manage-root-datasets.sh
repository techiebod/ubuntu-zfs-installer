#!/bin/bash
#
# Manage ZFS Root Datasets
#
# This script handles the creation, deletion, and listing of ZFS root datasets,
# which serve as bootable environments.

# --- Script Setup ---
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
lib_dir="$script_dir/../lib"
PROJECT_ROOT="$(dirname "$script_dir")"

# Load global configuration
if [[ -f "$PROJECT_ROOT/config/global.conf" ]]; then
    source "$PROJECT_ROOT/config/global.conf"
fi

# Load only the libraries we need
source "$lib_dir/constants.sh"       # For status constants
source "$lib_dir/logging.sh"         # For logging functions
source "$lib_dir/execution.sh"       # For argument parsing and run_cmd
source "$lib_dir/validation.sh"      # For build name validation
source "$lib_dir/zfs.sh"             # For ZFS operations (primary functionality)
source "$lib_dir/build-status.sh"    # For build status integration

# --- Script-specific Default values ---
POOL_NAME="${DEFAULT_POOL_NAME}"
MOUNT_BASE="${DEFAULT_MOUNT_BASE}"
CLEANUP=false
FORCE_DESTROY=false
ACTION=""
BUILD_NAME=""

# --- Helper Functions ---
confirm() {
    local message="$1"
    local response
    
    echo -n "$message [y/N]: "
    read -r response
    case "$response" in
        [yY]|[yY][eE][sS]) return 0 ;;
        *) return 1 ;;
    esac
}

# --- Usage Information ---
show_usage() {
    cat << EOF
Usage: $0 [OPTIONS] ACTION [NAME]

Manages ZFS root datasets (bootable environments).

ACTIONS:
  create NAME             Create a new root dataset for building.
  destroy NAME            Destroy an existing root dataset and its snapshots.
  list                    List all existing root datasets in the pool.
  promote NAME            Promote a dataset to be the default boot environment.
  unmount NAME            Unmount a dataset from the temporary build area.
  mount-varlog NAME       Mount the varlog child dataset for a build.

ARGUMENTS:
  NAME                    The name for the root dataset (e.g., ubuntu-25.04).
                          Required for all actions except 'list'.

OPTIONS:
  -p, --pool POOL         The ZFS pool to operate on (default: ${DEFAULT_POOL_NAME}).
  -m, --mount-base PATH   The base directory where datasets are mounted for building
                          (default: ${DEFAULT_MOUNT_BASE}).
      --cleanup           When creating, destroy any existing dataset with the same name first.
      --force             For 'destroy', bypass the confirmation prompt.

$(show_common_options_help)

EXAMPLES:
  # List all current root datasets
  $0 list

  # Create a new root dataset named 'ubuntu-next'
  $0 create ubuntu-next

  # Promote the new build to be the default on next boot
  $0 promote ubuntu-next

  # Destroy an old or experimental build
  $0 destroy ubuntu-old --force
EOF
    exit 0
}

# --- Function to unmount a root dataset from the build area ---
unmount_root_dataset() {
    local dataset_name="$1"
    local dataset
    dataset=$(zfs_get_root_dataset_path "$POOL_NAME" "$dataset_name")
    local mount_point="${MOUNT_BASE}/${dataset_name}"

    log_info "Attempting to unmount dataset '$dataset' from '$mount_point'..."

    if ! zfs_dataset_exists "$dataset"; then
        log_warn "Dataset '$dataset' does not exist. Nothing to unmount."
        return 0
    fi

    # Check if the base mountpoint is actually a mountpoint for this dataset
    if ! mountpoint -q "$mount_point"; then
        log_info "Dataset is not mounted at '$mount_point'. No action needed."
        return 0
    fi

    # Check if the correct dataset is mounted there
    local mounted_fs
    mounted_fs=$(df --output=source "$mount_point" | tail -n 1)
    if [[ "$mounted_fs" != "$dataset" ]]; then
        log_warn "A different filesystem ('$mounted_fs') is mounted at '$mount_point'. Skipping unmount for safety."
        return 1
    fi

    log_info "Unmounting all filesystems under '$mount_point'..."
    run_cmd umount -R "$mount_point"

    log_info "Successfully unmounted '$dataset'."
}

# --- Function to mount varlog dataset ---
mount_varlog_dataset() {
    local build_name="$1"
    local dataset
    dataset=$(zfs_get_root_dataset_path "$POOL_NAME" "$build_name")
    local varlog_dataset
    varlog_dataset=$(zfs_get_varlog_dataset_path "$POOL_NAME" "$build_name")
    local mount_point="${MOUNT_BASE}/${build_name}"
    local varlog_mount_point="${mount_point}/var/log"
    
    log_info "Mounting varlog dataset for build: $build_name"
    
    # Check if main dataset exists
    if ! zfs_dataset_exists "$dataset"; then
        die "Main dataset '$dataset' does not exist."
    fi
    
    # Check if varlog dataset exists
    if ! zfs_dataset_exists "$varlog_dataset"; then
        die "Varlog dataset '$varlog_dataset' does not exist."
    fi
    
    # Check if main dataset is mounted
    if ! mountpoint -q "$mount_point"; then
        die "Main dataset is not mounted at '$mount_point'. Mount the main dataset first."
    fi
    
    # Check if varlog is already mounted
    if mountpoint -q "$varlog_mount_point"; then
        log_info "Varlog dataset is already mounted at '$varlog_mount_point'."
        return 0
    fi
    
    # Create the mount point directory
    run_cmd mkdir -p "$varlog_mount_point"
    
    # Mount the varlog dataset
    log_info "Mounting varlog dataset '$varlog_dataset' at '$varlog_mount_point'"
    run_cmd mount -t zfs "$varlog_dataset" "$varlog_mount_point"
    
    log_info "Successfully mounted varlog dataset."
}

# --- Dataset Destruction ---
destroy_dataset() {
    local build_name="$1"
    local pool_name="$2"
    local mount_base="$3"
    local dataset
    dataset=$(zfs_get_root_dataset_path "$pool_name" "$build_name")
    local mount_point="${mount_base}/${build_name}"

    log_info "Preparing to destroy root dataset: ${dataset}"

    # Check if dataset exists
    if ! zfs list -H -o name "$dataset" &>/dev/null; then
        die "Dataset '$dataset' does not exist."
    fi

    if mountpoint -q "$mount_point"; then
        # Use the dedicated unmount function which contains the necessary checks
        unmount_root_dataset "$build_name"
    else
        log_info "Dataset '${dataset}' is not currently mounted."
    fi

    # Check for running containers that might be using this dataset
    local container_name="${build_name}"
    # Use the container management script to check if container is running
    if "$script_dir/manage-root-containers.sh" list 2>/dev/null | grep -q "^${container_name}[[:space:]]"; then
        log_error "Container '$container_name' is currently running and using this dataset."
        log_info "Please stop the container first using:"
        log_info "  $script_dir/manage-root-containers.sh stop --name '$container_name' '$build_name'"
        die "Cannot destroy dataset while container is running."
    fi

    local snapshots
    snapshots=$(zfs list -H -o name -t snapshot -r "$dataset" 2>/dev/null)
    
    # Handle confirmation for non-dry-run mode
    if [[ "${DRY_RUN:-false}" != true ]]; then
        # Show warning and get confirmation before proceeding
        if [[ -n "$snapshots" ]]; then
            log_warn "This will permanently destroy '${dataset}' and all its snapshots:"
            echo "$snapshots" | sed 's/^/    /'
        else
            log_warn "This will permanently destroy '${dataset}'."
        fi

        if ! $FORCE_DESTROY && ! confirm "Are you sure you want to continue?"; then
            die "Destruction of '${dataset}' aborted by user."
        fi
    fi

    # Show what we're about to do (for both dry-run and normal mode)
    if [[ -n "$snapshots" ]]; then
        log_info "Destroying dataset '${dataset}' and all its snapshots..."
    else
        log_info "Destroying dataset '${dataset}'..."
    fi

    # Use run_cmd to respect dry-run mode
    if ! run_cmd zfs destroy -r "$dataset"; then
        log_error "Failed to destroy dataset '${dataset}'."
        log_info "This is often because the dataset is still busy. Check for processes with open files or working directories inside '${mount_point}'."
        log_info "You can use a command like 'sudo lsof +D ${mount_point}' to find them."
        die "Cannot destroy dataset."
    fi

    log_info "Successfully destroyed dataset '${dataset}'."
}

# --- Function to promote a dataset to be the next boot environment ---
promote_to_bootfs() {
    local dataset_name="$1"
    local dataset
    dataset=$(zfs_get_root_dataset_path "$POOL_NAME" "$dataset_name")

    log_info "Promoting '$dataset_name' to be the next boot environment..."

    if ! zfs_dataset_exists "$dataset"; then
        die "Dataset '$dataset' does not exist."
    fi

    # Step 1: Unmount from build area if necessary
    unmount_root_dataset "$dataset_name"

    # Step 2: Use the high-level ZFS library function
    zfs_promote_to_bootfs "$POOL_NAME" "$dataset_name"

    log_info "Successfully promoted '$dataset_name'. It will be the default on next boot."
}

# --- Function to list datasets ---
list_root_datasets() {
    # This function uses 'echo' instead of 'log_info' for cleaner, human-readable output.
    echo "listing zfs root datasets in pool '$POOL_NAME'..."
    check_zfs_pool "$POOL_NAME"

    local current_bootfs
    current_bootfs=$(zpool get -H -o value bootfs "$POOL_NAME" 2>/dev/null || echo "N/A")

    local pool_info
    pool_info=$(zpool list -H -p -o size,alloc,free "$POOL_NAME" | awk '{
        size_h = $1 / (1024^3); alloc_h = $2 / (1024^3); free_h = $3 / (1024^3);
        printf("size: %.2fG | allocated: %.2fG (%.0f%%) | free: %.2fG",
               size_h, alloc_h, (alloc_h/size_h)*100, free_h)
    }')
    echo "pool status ($POOL_NAME): $pool_info"
    echo

    # Get direct children of the ROOT dataset using centralized function
    local datasets
    datasets=$(zfs_list_root_datasets "$POOL_NAME")
    
    if [[ -z "$datasets" ]]; then
        echo "no root datasets found under '${POOL_NAME}/${DEFAULT_ROOT_DATASET}'."
        return 0
    fi

    printf "%-25s %-10s %-35s %s\n" "root dataset" "used" "mountpoint" "status"
    printf "%-25s %-10s %-35s %s\n" "-------------------------" "----------" "-----------------------------------" "------"

    echo "$datasets" | while read -r name used mountpoint_prop mounted; do
        local status=""
        local display_mountpoint="$mountpoint_prop"

        # Check for BOOTFS status
        [[ "$name" == "$current_bootfs" ]] && status+="BOOTFS "

        # Check if it's the currently mounted root filesystem
        [[ "$mountpoint_prop" == "/" ]] && status+="ACTIVE_ROOT "

        # Check if the dataset is actively mounted anywhere
        if [[ "$mounted" == "yes" ]] && [[ "$mountpoint_prop" != "/" ]]; then
            status+="MOUNTED "
            # Find the actual mount point from the system's mount table
            local actual_mount
            actual_mount=$(mount | grep "^${name} " | awk '{print $3}')
            [[ -n "$actual_mount" ]] && display_mountpoint="$actual_mount"
        fi

        # Check for the existence of a varlog child dataset
        local build_name
        build_name=$(basename "$name")
        if zfs_varlog_dataset_exists "$POOL_NAME" "$build_name"; then
            status+="+varlog "
        else
            status+="-varlog "
        fi

        printf "%-25s %-10s %-35s %s\n" \
            "$(basename "$name")" \
            "$(numfmt --to=iec-i --suffix=B --format='%.1f' "$used")" \
            "$display_mountpoint" \
            "$status"
    done
}


# --- Argument Parsing ---
parse_args() {
    local remaining_args=()
    
    # First pass: handle common arguments
    parse_common_args remaining_args "$@"
    
    # Second pass: handle script-specific arguments
    local positional_args=()
    local args=("${remaining_args[@]}")
    
    while [[ ${#args[@]} -gt 0 ]]; do
        case "${args[0]}" in
            -p|--pool) POOL_NAME="${args[1]}"; args=("${args[@]:2}") ;;
            -m|--mount-base) MOUNT_BASE="${args[1]}"; args=("${args[@]:2}") ;;
            --cleanup) CLEANUP=true; args=("${args[@]:1}") ;;
            --force) FORCE_DESTROY=true; args=("${args[@]:1}") ;;
            -h|--help) show_usage; exit 0 ;;
            -*) die "Unknown option: ${args[0]}" ;;
            *) positional_args+=("${args[0]}"); args=("${args[@]:1}") ;;
        esac
    done

    # Process positional arguments
    if [[ ${#positional_args[@]} -eq 0 ]]; then
        show_usage
        die "No action specified."
    fi

    ACTION="${positional_args[0]}"

    case "$ACTION" in
        list)
            if [[ ${#positional_args[@]} -ne 1 ]]; then
                die "Action 'list' takes no other arguments."
            fi
            ;;
        create|destroy|promote|unmount|mount-varlog)
            if [[ ${#positional_args[@]} -ne 2 ]]; then
                show_usage
                die "Action '$ACTION' requires a NAME argument."
            fi
            BUILD_NAME="${positional_args[1]}"
            ;;
        *)
            die "Unknown action: $ACTION"
            ;;
    esac
}

# --- Main Logic ---
main() {
    parse_args "$@"

    case "$ACTION" in
        list)
            # For interactive use, disable timestamps for cleaner output
            # shellcheck disable=SC2034  # Used by logging system
            LOG_WITH_TIMESTAMPS=false
            list_root_datasets
            ;;
        create)
            log_info "Starting ZFS root dataset creation for: '$BUILD_NAME'"
            check_zfs_pool "$POOL_NAME"

            local dataset
            dataset=$(zfs_get_root_dataset_path "$POOL_NAME" "$BUILD_NAME")
            local mount_point="${MOUNT_BASE}/${BUILD_NAME}"

            if zfs_root_dataset_exists "$POOL_NAME" "$BUILD_NAME"; then
                if [[ "$CLEANUP" == true ]]; then
                    log_warn "Root dataset '$BUILD_NAME' already exists. Destroying it due to --cleanup flag."
                    # Temporarily set force flag for the destroy operation
                    local original_force=$FORCE_DESTROY
                    FORCE_DESTROY=true
                    destroy_dataset "$BUILD_NAME" "$POOL_NAME" "$MOUNT_BASE"
                    FORCE_DESTROY=$original_force
                else
                    die "Root dataset '$BUILD_NAME' already exists at '$dataset'. Use --cleanup to remove it."
                fi
            fi

            log_info "Creating ZFS datasets for '$BUILD_NAME' in pool '$POOL_NAME'..."

            # Use the high-level ZFS library function
            zfs_create_root_dataset "$POOL_NAME" "$BUILD_NAME"

            log_info "Mounting the new root dataset for build..."
            zfs_mount_root_dataset "$POOL_NAME" "$BUILD_NAME" "$MOUNT_BASE"

            log_info "ZFS root dataset creation for '$BUILD_NAME' complete."
            log_info "New environment is mounted at: $mount_point"
            log_info "Note: Child datasets like 'var/log' are not mounted automatically."
            ;;
        destroy)
            destroy_dataset "$BUILD_NAME" "$POOL_NAME" "$MOUNT_BASE"
            ;;
        promote)
            promote_to_bootfs "$BUILD_NAME"
            ;;
        unmount)
            unmount_root_dataset "$BUILD_NAME"
            ;;
        mount-varlog)
            mount_varlog_dataset "$BUILD_NAME"
            ;;
    esac
}

# --- Execute Main Function ---
(
    main "$@"
)