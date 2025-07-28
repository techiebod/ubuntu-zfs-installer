#!/bin/bash
#
# Configure Ubuntu ZFS base image with Ansible
#
# This script executes Ansible playbooks against a ZFS build environment.
# It expects a systemd-nspawn container to already be created and running.
#

# --- Script Setup ---
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
lib_dir="$script_dir/../lib"

# Load the core library which sets up essential project structure and variables
source "$lib_dir/core.sh"

# Load libraries we need
source "$lib_dir/core.sh"
source "$lib_dir/logging.sh"
source "$lib_dir/execution.sh"
source "$lib_dir/validation.sh" 
source "$lib_dir/dependencies.sh"
source "$lib_dir/flag-helpers.sh"
source "$lib_dir/zfs.sh"             # For ZFS dataset paths
source "$lib_dir/containers.sh"      # For container operations
source "$lib_dir/build-status.sh"    # For build status integration

# Load shflags library for standardized argument parsing
source "$lib_dir/vendor/shflags"

# --- Flag Definitions ---
# Define all command-line flags with defaults and descriptions
DEFINE_string 'pool' "${DEFAULT_POOL_NAME}" 'ZFS pool where the build dataset resides' 'p'
DEFINE_string 'tags' '' 'Comma-separated list of Ansible tags to run' 't'
DEFINE_string 'limit' '' 'Ansible limit pattern (default: HOSTNAME)' 'l'
DEFINE_string 'playbook' 'site.yml' 'Ansible playbook to run'
DEFINE_string 'inventory' 'inventory' 'Ansible inventory file to use'
define_common_flags  # Add standard dry-run and debug flags

# --- Script-specific Variables ---
BUILD_NAME=""
HOSTNAME=""

# --- Usage Information ---
show_usage() {
    cat << EOF
Usage: $0 [OPTIONS] BUILD_NAME HOSTNAME

Configures a ZFS root filesystem using Ansible. Expects a systemd-nspawn container
to already be created and running for the specified build.

ARGUMENTS:
  BUILD_NAME              The name of the build/dataset to configure (e.g., ubuntu-noble).
  HOSTNAME                The target hostname for configuration. An Ansible host_vars file
                          (config/host_vars/HOSTNAME.yml) must exist.

PREREQUISITES:
  - Container named BUILD_NAME must be created and running
  - Ansible must be installed in the container
  - Ansible configuration must be staged in /opt/ansible-config

EOF
    echo "OPTIONS:"
    flags_help
    cat << EOF

EXAMPLES:
  # Configure the 'ubuntu-noble' build for host 'blackbox'
  $0 ubuntu-noble blackbox

  # Configure with specific Ansible tags
  $0 --tags base,docker ubuntu-noble blackbox
EOF
}

# --- Argument Parsing ---
parse_args() {
    # Parse flags and return non-flag arguments
    FLAGS "$@" || exit 1
    eval set -- "${FLAGS_ARGV}"
    
    # Process positional arguments
    if [[ $# -ne 2 ]]; then
        log_error "Expected exactly BUILD_NAME and HOSTNAME arguments"
        echo ""
        show_usage
        exit 1
    fi
    
    BUILD_NAME="$1"
    HOSTNAME="$2"
    
    # Set global variables from flags for compatibility with existing code
    POOL_NAME="${FLAGS_pool}"
    ANSIBLE_TAGS="${FLAGS_tags}"
    ANSIBLE_LIMIT="${FLAGS_limit}"
    PLAYBOOK="${FLAGS_playbook}"
    INVENTORY="${FLAGS_inventory}"
    # Process common flags (dry-run and debug)
    process_common_flags
}

# --- Prerequisite Checks ---
check_prerequisites() {
    log_info "Performing prerequisite checks for configuration..."

    # Check for required project structure
    local ansible_dir
    ansible_dir="$PROJECT_ROOT/ansible"
    if [[ ! -d "$ansible_dir" ]]; then
        die "Ansible directory not found at '$ansible_dir'."
    fi
    if [[ ! -f "$ansible_dir/$PLAYBOOK" ]]; then
        die "Playbook '$PLAYBOOK' not found in '$ansible_dir'."
    fi
    if [[ ! -f "$ansible_dir/$INVENTORY" ]]; then
        die "Inventory file '$INVENTORY' not found in '$ansible_dir'."
    fi
    local host_vars_file
    host_vars_file="$PROJECT_ROOT/config/host_vars/${HOSTNAME}.yml"
    if [[ ! -f "$host_vars_file" ]]; then
        die "Ansible host_vars file not found for '$HOSTNAME' at '$host_vars_file'."
    fi

    # Check that the target dataset exists using the dataset management script
    if ! "$script_dir/manage-root-datasets.sh" --pool "$POOL_NAME" list | grep -q "^${BUILD_NAME}[[:space:]]"; then
        local dataset
        dataset=$(zfs_get_root_dataset_path "$POOL_NAME" "$BUILD_NAME")
        die "Target dataset '$dataset' does not exist. Use manage-root-datasets.sh to create it first."
    fi

    log_info "All prerequisite checks passed."
}

# --- Main Logic ---
main() {
    parse_args "$@"
    
    # Disable timestamps for cleaner output in interactive mode
    if is_interactive_mode; then
        # shellcheck disable=SC2034  # Used by logging system
        LOG_WITH_TIMESTAMPS=false
    fi
    
    check_prerequisites

    # Determine the mountpoint for the build
    local mount_point="${DEFAULT_MOUNT_BASE}/${BUILD_NAME}"
    log_debug "Target mountpoint: $mount_point"
    if [[ ! -d "$mount_point" ]]; then
        die "Target mountpoint '$mount_point' does not exist or is not mounted. Use manage-root-datasets.sh to mount the dataset first."
    fi

    # Set Ansible limit if not provided
    if [[ -z "$ANSIBLE_LIMIT" ]]; then
        ANSIBLE_LIMIT="$HOSTNAME"
    fi

    log_info "Starting system configuration for build '$BUILD_NAME'..."
    log_info "  Target Host:    $HOSTNAME"
    log_info "  Ansible Tags:   ${ANSIBLE_TAGS:-'(none)'}"
    log_info "  Ansible Limit:  $ANSIBLE_LIMIT"

    # --- STAGE 1: Prepare configuration inside the container ---
    log_info "Preparing configuration for systemd-nspawn container..."

    # Create a temporary staging directory on the host for safer preparation.
    local staging_dir
    staging_dir=$(mktemp -d -t ansible-config-staging-XXXXXX)
    log_debug "Created temporary staging directory: $staging_dir"

    # Ensure the staging directory is cleaned up on script exit.
    trap 'log_debug "Cleaning up staging directory: $staging_dir"; rm -rf "$staging_dir"' EXIT

    # Copy the necessary directories into the staging area.
    log_debug "Copying ansible and config directories to staging area..."
    run_cmd cp -rT "$PROJECT_ROOT/ansible" "$staging_dir/"
    run_cmd cp -rT "$PROJECT_ROOT/config" "$staging_dir/config"

    # Remove the old, incorrect symlinks from the staging area before creating new ones.
    log_debug "Removing original symlinks from staging area..."
    run_cmd rm -f "$staging_dir/host_vars" "$staging_dir/group_vars"

    # Create the new, relative symlinks required by the playbook within the staging area.
    log_debug "Creating relative symlinks in staging area..."
    run_cmd ln -s ./config/host_vars "$staging_dir/host_vars"
    run_cmd ln -s ./config/group_vars "$staging_dir/group_vars"

    # Atomically move the prepared configuration into the container's filesystem.
    # This is much safer than creating/deleting directories directly in the target.
    local ansible_config_dir="${mount_point}/opt/ansible-config"
    log_debug "Moving staged configuration to final destination: $ansible_config_dir"
    run_cmd rm -rf "$ansible_config_dir" # This is now safe as it's a specific, known subdir.
    run_cmd mv "$staging_dir" "$ansible_config_dir"

    # Clean up the trap now that we're done with the staging directory.
    trap - EXIT

    # --- STAGE 2: Execute Ansible in existing container ---
    log_info "Executing Ansible playbook in container..."
    
    # Container should already be created and started by orchestrator
    local container_name="${BUILD_NAME}"
    
    # Create the ansible setup script inside the container
    local setup_script="${mount_point}/root/setup-ansible.sh"
    cat > "$setup_script" << 'SCRIPT_EOF'
#!/bin/bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C.UTF-8 LANG=C.UTF-8 LANGUAGE=C.UTF-8
cd /opt/ansible-config

# Ansible should already be installed, just install role/collection dependencies
if [[ -f 'requirements.yml' ]]; then
    log_info 'Installing Ansible role dependencies...'
    ansible-galaxy install -r requirements.yml -p ./roles
    log_info 'Installing Ansible collection dependencies...'
    ansible-galaxy collection install -r requirements.yml -p ./collections
else
    log_info 'No requirements.yml found, skipping role installation.'
fi
SCRIPT_EOF
    chmod +x "$setup_script"

    # Create the main ansible execution script
    local ansible_playbook_cmd=(
        "ansible-playbook"
        "-i" "inventory"
        "$PLAYBOOK"
        "-c" "local"
        "-l" "$ANSIBLE_LIMIT"
    )
    [[ -n "$ANSIBLE_TAGS" ]] && ansible_playbook_cmd+=("--tags" "$ANSIBLE_TAGS")
    [[ "$DEBUG" == true ]] && ansible_playbook_cmd+=("-vv")
    [[ "$DRY_RUN" == true ]] && ansible_playbook_cmd+=("--check" "--diff")
    
    local run_script="${mount_point}/root/run-ansible.sh"
    cat > "$run_script" << SCRIPT_EOF
#!/bin/bash
set -euo pipefail
cd /opt/ansible-config
log_info 'Executing Ansible playbook...'
${ansible_playbook_cmd[*]}
SCRIPT_EOF
    chmod +x "$run_script"

    # Execute Ansible setup and playbook in the container
    log_info "Setting up Ansible dependencies in container..."
    if ! run_cmd "$script_dir/manage-root-containers.sh" exec --name "$container_name" "$BUILD_NAME" /root/setup-ansible.sh; then
        log_error "Failed to setup Ansible in container"
        return 1
    fi
    
    log_info "Executing Ansible playbook in container..."
    if ! run_cmd "$script_dir/manage-root-containers.sh" exec --name "$container_name" "$BUILD_NAME" /root/run-ansible.sh; then
        log_error "Ansible playbook execution failed"
        return 1
    fi

    log_info "Configuration of build '$BUILD_NAME' completed successfully."
}

# --- Execute Main Function ---
(
    main "$@"
)
