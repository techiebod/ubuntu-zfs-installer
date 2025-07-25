#!/bin/bash
#
# Configure Ubuntu ZFS base image with Ansible
#
# This script executes Ansible playbooks against a ZFS build environment.
# It expects a systemd-nspawn container to already be created and running.
#

# --- Script Setup ---
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(dirname "$script_dir")"
# shellcheck source=../lib/common.sh
source "$project_dir/lib/common.sh"

# --- Script-specific Default values ---
PLAYBOOK="site.yml"
INVENTORY="inventory"
ANSIBLE_TAGS=""
ANSIBLE_LIMIT=""
BUILD_NAME=""
HOSTNAME=""
POOL_NAME="${DEFAULT_POOL_NAME}"

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

OPTIONS:
  -p, --pool POOL         ZFS pool where the build dataset resides (default: ${DEFAULT_POOL_NAME}).
  -t, --tags TAGS         Comma-separated list of Ansible tags to run.
  -l, --limit PATTERN     Ansible limit pattern (default: HOSTNAME).
      --playbook FILE     Ansible playbook to run (default: ${PLAYBOOK}).
      --inventory FILE    Ansible inventory file to use (default: ${INVENTORY}).
      --verbose           Enable verbose output.
      --dry-run           Show commands without executing them.
      --debug             Enable detailed debug logging.
  -h, --help              Show this help message.

EXAMPLES:
  # Configure the 'ubuntu-noble' build for host 'blackbox'
  $0 ubuntu-noble blackbox

  # Configure with specific Ansible tags
  $0 --tags base,docker ubuntu-noble blackbox
EOF
    exit 0
}

# --- Argument Parsing ---
parse_args() {
    local positional_args=()

    while [[ $# -gt 0 ]]; do
        case $1 in
            -p|--pool) POOL_NAME="$2"; shift 2 ;;
            -t|--tags) ANSIBLE_TAGS="$2"; shift 2 ;;
            -l|--limit) ANSIBLE_LIMIT="$2"; shift 2 ;;
            --playbook) PLAYBOOK="$2"; shift 2 ;;
            --inventory) INVENTORY="$2"; shift 2 ;;
            --verbose) VERBOSE=true; shift ;;
            --dry-run) DRY_RUN=true; shift ;;
            --debug) DEBUG=true; shift ;;
            -h|--help) show_usage ;;
            -*) die "Unknown option: $1" ;;
            *) positional_args+=("$1"); shift ;;
        esac
    done

    if [[ ${#positional_args[@]} -ne 2 ]]; then
        show_usage
        die "Invalid number of arguments. Expected BUILD_NAME and HOSTNAME."
    fi

    BUILD_NAME="${positional_args[0]}"
    HOSTNAME="${positional_args[1]}"
}

# --- Prerequisite Checks ---
check_prerequisites() {
    log_info "Performing prerequisite checks for configuration..."

    # Check for required system commands
    require_command "systemd-nspawn" "systemd-nspawn is required to configure the system."

    # Check for required project structure
    local ansible_dir
    ansible_dir="$project_dir/ansible"
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
    host_vars_file="$project_dir/config/host_vars/${HOSTNAME}.yml"
    if [[ ! -f "$host_vars_file" ]]; then
        die "Ansible host_vars file not found for '$HOSTNAME' at '$host_vars_file'."
    fi

    # Check that the target dataset exists using the dataset management script
    if ! "$script_dir/manage-root-datasets.sh" --pool "$POOL_NAME" list | grep -q "^${BUILD_NAME}[[:space:]]"; then
        die "Target dataset '${POOL_NAME}/ROOT/${BUILD_NAME}' does not exist. Use manage-root-datasets.sh to create it first."
    fi

    log_info "All prerequisite checks passed."
}

# --- Main Logic ---
main() {
    parse_args "$@"
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
    run_cmd cp -rT "$project_dir/ansible" "$staging_dir/"
    run_cmd cp -rT "$project_dir/config" "$staging_dir/config"

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
    echo 'Installing Ansible role dependencies...'
    ansible-galaxy install -r requirements.yml -p ./roles
    echo 'Installing Ansible collection dependencies...'
    ansible-galaxy collection install -r requirements.yml -p ./collections
else
    echo 'No requirements.yml found, skipping role installation.'
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
    [[ "$VERBOSE" == true ]] && ansible_playbook_cmd+=("-vv")
    [[ "$DRY_RUN" == true ]] && ansible_playbook_cmd+=("--check" "--diff")
    
    local run_script="${mount_point}/root/run-ansible.sh"
    cat > "$run_script" << SCRIPT_EOF
#!/bin/bash
set -euo pipefail
cd /opt/ansible-config
echo 'Executing Ansible playbook...'
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
