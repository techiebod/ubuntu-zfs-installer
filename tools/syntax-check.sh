#!/bin/bash
#
# Syntax Check Tool
#
# Performs comprehensive syntax validation on all shell scripts in the project.

set -euo pipefail

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m' # No Color

# Configuration
# shellcheck disable=SC2155
readonly PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly EXIT_SUCCESS=0
readonly EXIT_FAILURE=1

# Statistics
total_files=0
passed_files=0
failed_files=0

# Function to print colored output
print_status() {
    local status="$1"
    local file="$2"
    local message="${3:-}"
    
    case "$status" in
        "PASS")
            echo -e "${GREEN}✓ PASS${NC} $file"
            ;;
        "FAIL")
            echo -e "${RED}✗ FAIL${NC} $file${message:+ - $message}"
            ;;
        "SKIP")
            echo -e "${YELLOW}- SKIP${NC} $file${message:+ - $message}"
            ;;
    esac
}

# Function to check syntax of a single file
check_file_syntax() {
    local file="$1"
    local relative_path="${file#$PROJECT_ROOT/}"
    
    ((total_files++))
    
    # Skip non-executable shell scripts that might be templates
    if [[ "$file" == *.j2 ]] || [[ "$file" == *.template ]]; then
        print_status "SKIP" "$relative_path" "template file"
        return 0
    fi
    
    # Check if file has shell shebang or .sh extension
    local is_shell=false
    if [[ "$file" == *.sh ]] || [[ "$(head -n1 "$file" 2>/dev/null)" =~ ^#!.*(bash|sh) ]]; then
        is_shell=true
    fi
    
    if [[ "$is_shell" != true ]]; then
        print_status "SKIP" "$relative_path" "not a shell script"
        return 0
    fi
    
    # Perform syntax check
    if bash -n "$file" 2>/dev/null; then
        print_status "PASS" "$relative_path"
        ((passed_files++))
        return 0
    else
        # Capture error details
        local error_output
        error_output=$(bash -n "$file" 2>&1 || true)
        print_status "FAIL" "$relative_path" "$error_output"
        ((failed_files++))
        return 1
    fi
}

# Function to find and check all shell scripts
check_all_scripts() {
    echo "Performing syntax check on shell scripts..."
    echo "Project root: $PROJECT_ROOT"
    echo
    
    local exit_code=0
    
    # Find all shell scripts
    while IFS= read -r -d '' file; do
        if ! check_file_syntax "$file"; then
            exit_code=1
        fi
    done < <(find "$PROJECT_ROOT" \( -name "*.sh" -o -executable -type f \) -print0 | grep -zv -E '\.(git|bats)/')
    
    return $exit_code
}

# Function to print summary
print_summary() {
    echo
    echo "=================================================="
    echo "SYNTAX CHECK SUMMARY"
    echo "=================================================="
    echo "Total files checked: $total_files"
    echo -e "Passed: ${GREEN}$passed_files${NC}"
    echo -e "Failed: ${RED}$failed_files${NC}"
    echo -e "Skipped: ${YELLOW}$((total_files - passed_files - failed_files))${NC}"
    echo
    
    if [[ $failed_files -eq 0 ]]; then
        echo -e "${GREEN}✓ All syntax checks passed!${NC}"
        return $EXIT_SUCCESS
    else
        echo -e "${RED}✗ $failed_files file(s) failed syntax check${NC}"
        return $EXIT_FAILURE
    fi
}

# Main function
main() {
    cd "$PROJECT_ROOT"
    
    local exit_code=0
    
    if ! check_all_scripts; then
        exit_code=1
    fi
    
    if ! print_summary; then
        exit_code=1
    fi
    
    exit $exit_code
}

# Help function
show_help() {
    cat << EOF
Syntax Check Tool

Usage: $0 [OPTIONS]

OPTIONS:
    -h, --help      Show this help message

DESCRIPTION:
    Performs bash syntax validation on all shell scripts in the project.
    Checks files with .sh extension and files with bash/sh shebangs.
    Skips template files (.j2, .template) and non-shell files.

EXIT CODES:
    0    All files passed syntax check
    1    One or more files failed syntax check

EXAMPLES:
    $0              # Check all shell scripts
    $0 --help       # Show this help

EOF
}

# Parse command line arguments
case "${1:-}" in
    -h|--help)
        show_help
        exit $EXIT_SUCCESS
        ;;
    "")
        main
        ;;
    *)
        echo "Error: Unknown option: $1" >&2
        echo "Use --help for usage information." >&2
        exit $EXIT_FAILURE
        ;;
esac
