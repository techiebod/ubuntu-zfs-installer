#!/bin/bash
#
# Dependencies Library
#
# This library provides dependency checking and command validation functionality.
# It handles command availability checks, installation hints, and dependency
# error reporting with recovery suggestions.

# --- Prevent multiple sourcing ---
if [[ "${__DEPENDENCIES_LIB_LOADED:-}" == "true" ]]; then
    return 0
fi
readonly __DEPENDENCIES_LIB_LOADED="true"

# Load logging library if not already loaded
if [[ "${__LOGGING_LIB_LOADED:-}" != "true" ]]; then
    # Determine library directory
    DEPENDENCIES_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    source "$DEPENDENCIES_LIB_DIR/logging.sh"
fi

# ==============================================================================
# DEPENDENCY VALIDATION FRAMEWORK
# ==============================================================================

# Enhanced command requirement checking with installation hints
# Usage: require_command "docker" "Docker is required" "sudo apt install docker.io"
require_command() {
    local cmd="$1"
    local description="${2:-Command '$cmd' is required}"
    local install_hint="${3:-}"
    
    if ! command -v "$cmd" &>/dev/null; then
        if [[ -n "$install_hint" ]]; then
            die_with_dependency_error "$cmd" "$install_hint"
        else
            # Provide common installation hints
            case "$cmd" in
                docker)
                    die_with_dependency_error "$cmd" "sudo apt install docker.io && sudo systemctl start docker"
                    ;;
                jq)
                    die_with_dependency_error "$cmd" "sudo apt install jq"
                    ;;
                curl)
                    die_with_dependency_error "$cmd" "sudo apt install curl"
                    ;;
                zfs|zpool)
                    die_with_dependency_error "$cmd" "sudo apt install zfsutils-linux"
                    ;;
                systemd-nspawn)
                    die_with_dependency_error "$cmd" "sudo apt install systemd-container"
                    ;;
                ansible-playbook)
                    die_with_dependency_error "$cmd" "sudo apt install ansible"
                    ;;
                git)
                    die_with_dependency_error "$cmd" "sudo apt install git"
                    ;;
                wget)
                    die_with_dependency_error "$cmd" "sudo apt install wget"
                    ;;
                tar)
                    die_with_dependency_error "$cmd" "sudo apt install tar"
                    ;;
                gzip|gunzip)
                    die_with_dependency_error "$cmd" "sudo apt install gzip"
                    ;;
                rsync)
                    die_with_dependency_error "$cmd" "sudo apt install rsync"
                    ;;
                ssh)
                    die_with_dependency_error "$cmd" "sudo apt install openssh-client"
                    ;;
                mount|umount)
                    die_with_dependency_error "$cmd" "sudo apt install util-linux"
                    ;;
                *)
                    die_with_dependency_error "$cmd" ""
                    ;;
            esac
        fi
    fi
    log_debug "✓ Command available: $cmd"
}

# Check multiple commands at once
# Usage: require_commands "docker" "jq" "curl"
require_commands() {
    local missing_commands=()
    
    for cmd in "$@"; do
        if ! command -v "$cmd" &>/dev/null; then
            missing_commands+=("$cmd")
        else
            log_debug "✓ Command available: $cmd"
        fi
    done
    
    if [[ ${#missing_commands[@]} -gt 0 ]]; then
        log_error "Missing required commands: ${missing_commands[*]}"
        for cmd in "${missing_commands[@]}"; do
            require_command "$cmd"  # This will die with specific install instructions
        done
    fi
}

# Check if a command is available without failing
# Usage: if has_command "docker"; then ... fi
has_command() {
    local cmd="$1"
    command -v "$cmd" &>/dev/null
}

# Check for optional commands with warnings
# Usage: check_optional_command "git" "Git is recommended for version control"
check_optional_command() {
    local cmd="$1"
    local purpose="${2:-$cmd is recommended}"
    
    if ! command -v "$cmd" &>/dev/null; then
        log_warn "⚠️  Optional command '$cmd' not found: $purpose"
        return 1
    else
        log_debug "✓ Optional command available: $cmd"
        return 0
    fi
}

# ==============================================================================
# SYSTEM DEPENDENCY CHECKS
# ==============================================================================

# Check if running as root (when required)
require_root() {
    if [[ $EUID -ne 0 ]]; then
        die_with_permission_error "This script must be run as root (use sudo)"
    fi
    log_debug "✓ Running as root"
}

# Check if NOT running as root (when dangerous)
require_non_root() {
    if [[ $EUID -eq 0 ]]; then
        die "This script should not be run as root for security reasons"
    fi
    log_debug "✓ Running as non-root user"
}

# Check if user is in a specific group
require_group_membership() {
    local group="$1"
    local username="${2:-$(whoami)}"
    
    if ! groups "$username" | grep -q "\b$group\b"; then
        die_with_context \
            "User '$username' is not in the '$group' group" \
            "Add user to group with: sudo usermod -aG $group $username (then logout/login)" \
            "$EXIT_MISSING_DEPS"
    fi
    log_debug "✓ User '$username' is in group '$group'"
}

# Check system architecture
check_architecture() {
    local required_arch="${1:-amd64}"
    local current_arch
    current_arch=$(dpkg --print-architecture 2>/dev/null || uname -m)
    
    # Normalize architecture names
    case "$current_arch" in
        x86_64) current_arch="amd64" ;;
        aarch64) current_arch="arm64" ;;
    esac
    
    if [[ "$current_arch" != "$required_arch" ]]; then
        die "Unsupported architecture: $current_arch (required: $required_arch)"
    fi
    log_debug "✓ Architecture: $current_arch"
}

# Check minimum disk space
check_disk_space() {
    local path="$1"
    local min_gb="$2"
    
    if [[ ! -d "$path" ]]; then
        die "Directory not found: $path"
    fi
    
    local available_kb
    available_kb=$(df "$path" | awk 'NR==2 {print $4}')
    local required_kb=$((min_gb * 1024 * 1024))
    
    if [[ $available_kb -lt $required_kb ]]; then
        local available_gb=$((available_kb / 1024 / 1024))
        die "Insufficient disk space: ${available_gb}GB available, ${min_gb}GB required at $path"
    fi
    
    log_debug "✓ Sufficient disk space: $((available_kb / 1024 / 1024))GB available at $path"
}

# Check memory requirements
check_memory() {
    local min_gb="$1"
    
    local total_kb
    total_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    local required_kb=$((min_gb * 1024 * 1024))
    
    if [[ $total_kb -lt $required_kb ]]; then
        local total_gb=$((total_kb / 1024 / 1024))
        log_warn "⚠️  Low system memory: ${total_gb}GB available, ${min_gb}GB recommended"
    else
        log_debug "✓ Sufficient memory: $((total_kb / 1024 / 1024))GB available"
    fi
}

# ==============================================================================
# RECOVERY SUGGESTIONS
# ==============================================================================

# Recovery suggestions for common error scenarios
suggest_recovery() {
    local error_type="$1"
    
    case "$error_type" in
        "permission")
            log_info "💡 Recovery suggestions for permission errors:"
            log_info "   • Run with sudo if accessing system resources"
            log_info "   • Check file/directory ownership and permissions"
            log_info "   • Ensure your user is in required groups (docker, etc.)"
            ;;
        "network")
            log_info "💡 Recovery suggestions for network errors:"
            log_info "   • Check internet connectivity"
            log_info "   • Verify proxy settings if behind corporate firewall"
            log_info "   • Try again in a few minutes if servers are temporarily unavailable"
            ;;
        "zfs")
            log_info "💡 Recovery suggestions for ZFS errors:"
            log_info "   • Check ZFS pool status: sudo zpool status"
            log_info "   • Ensure ZFS modules are loaded: sudo modprobe zfs"
            log_info "   • Verify sufficient disk space: df -h"
            ;;
        "docker")
            log_info "💡 Recovery suggestions for Docker errors:"
            log_info "   • Start Docker daemon: sudo systemctl start docker"
            log_info "   • Add user to docker group: sudo usermod -aG docker $USER"
            log_info "   • Check Docker status: sudo systemctl status docker"
            ;;
        "dependency")
            log_info "💡 Recovery suggestions for dependency errors:"
            log_info "   • Update package lists: sudo apt update"
            log_info "   • Install missing packages using the commands shown above"
            log_info "   • Check if snap packages are available: snap find <package>"
            ;;
        *)
            log_info "💡 General recovery suggestions:"
            log_info "   • Check the error message above for specific details"
            log_info "   • Review logs in $STATUS_DIR for build history"
            log_info "   • Try running with --debug for more detailed output"
            ;;
    esac
}

# --- Finalization ---
log_debug "Dependencies library initialized."
