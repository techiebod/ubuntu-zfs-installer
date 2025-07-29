#!/bin/bash
#
# ZFSBootMenu Management Script
#
# This script provides command-line interface for ZFSBootMenu installation,
# configuration, and version management.

# --- Script Setup ---
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
lib_dir="$script_dir/../lib"

# Load the core library which sets up essential project structure and variables
source "$lib_dir/core.sh"

# Load libraries we need
source "$lib_dir/logging.sh"         # For logging functions
source "$lib_dir/execution.sh"       # For argument parsing and run_cmd
source "$lib_dir/validation.sh"      # For input validation
source "$lib_dir/dependencies.sh"    # For require_command
source "$lib_dir/zfsbootmenu.sh"     # For ZFSBootMenu operations (primary functionality)
source "$lib_dir/flag-helpers.sh"    # For common flag definitions

# Load shflags library for standardized argument parsing
source "$lib_dir/vendor/shflags"

# --- Flag Definitions ---
# Define all command-line flags with defaults and descriptions
define_common_flags  # Add standard dry-run and debug flags

# --- Script-specific Variables ---
COMMAND=""

# --- Usage Information ---
show_usage() {
    cat << EOF
Usage: $0 [OPTIONS] COMMAND

Manage ZFSBootMenu installation, configuration, and version information.

COMMANDS:
  status                         Show ZFSBootMenu status and EFI files
  create-images                  Create or download ZFSBootMenu EFI images

EOF
    echo "OPTIONS:"
    flags_help
    cat << EOF

EXAMPLES:
  # Show ZFSBootMenu status and EFI files
  $0 status
  
  # Create or update ZFSBootMenu EFI images
  $0 create-images
  
  # Force recreation of EFI images
  $0 create-images --force

  # Show what would be done (dry run)
  $0 --dry_run status

  # Enable debug output
  $0 --debug status

NOTES:
  This is the initial implementation focusing on status checking and image management.
  Additional commands (install, update, configure) will be added in future phases.

EOF
}

# --- Argument Parsing ---
parse_args() {
    # Parse flags and return non-flag arguments
    FLAGS "$@" || exit 1
    eval set -- "${FLAGS_ARGV}"
    
    # Process positional arguments
    if [[ $# -ne 1 ]]; then
        log_error "Expected exactly one COMMAND argument"
        echo ""
        show_usage
        exit 1
    fi
    
    COMMAND="$1"
    
    # Process common flags (dry-run and debug)
    process_common_flags
}

# --- Command Functions ---

# Show ZFSBootMenu status and EFI files
cmd_status() {
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log_info "[DRY RUN] Would show ZFSBootMenu status and EFI file discovery"
        log_info "[DRY RUN] Would search directories: ${ZBM_DEFAULT_EFI_SEARCH_DIRS[*]}"
        log_info "[DRY RUN] Would check EFI files against checksum database"
        log_info "[DRY RUN] Would display tabular results with partition, directory, filename, purpose, and status"
        return 0
    fi
    
    # Just show the clean EFI discovery output
    zfsbootmenu_discover_all_efi_files
}

# Create or download ZFSBootMenu EFI images
cmd_create_images() {
    log_info "Creating ZFSBootMenu EFI images..."
    
    local force_flag=""
    
    # Check for --force in remaining arguments (crude but functional)
    if [[ "$*" == *"--force"* ]]; then
        force_flag="--force"
        log_info "Force recreation requested"
    fi
    
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log_info "[DRY RUN] Would create ZFSBootMenu EFI images"
        log_info "[DRY RUN] Target directory: $DEFAULT_EFI_MOUNT/$DEFAULT_EFI_ZBM_DIR"
        log_info "[DRY RUN] Force flag: ${force_flag:-not set}"
        log_info "[DRY RUN] Would check for Perl dependencies"
        log_info "[DRY RUN] Would try generate-zbm if dependencies available"
        log_info "[DRY RUN] Would fallback to downloading pre-built images from GitHub"
        return 0
    fi
    
    if zfsbootmenu_create_images $force_flag; then
        log_info "✅ ZFSBootMenu EFI images ready"
    else
        log_error "❌ Failed to create ZFSBootMenu EFI images"
        return 1
    fi
}

# --- Main Function ---
main() {
    parse_args "$@"
    
    log_debug "ZFSBootMenu management command: $COMMAND"
    log_debug "Dry run mode: ${DRY_RUN:-false}"
    log_debug "Debug mode: ${DEBUG:-false}"
    
    case "$COMMAND" in
        status)
            cmd_status
            ;;
        create-images)
            cmd_create_images "$@"
            ;;
        *)
            log_error "Unknown command: $COMMAND"
            echo ""
            show_usage
            exit 1
            ;;
    esac
}

# --- Execute Main Function ---
(
    main "$@"
)
