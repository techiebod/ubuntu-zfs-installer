#!/bin/bash
#
# Simple YAML syntax checker using Python
#
# Usage:
#   ./tools/yaml-check.sh                      # Check all YAML files
#   ./tools/yaml-check.sh file.yml             # Check specific file
#   ./tools/yaml-check.sh --strict file.yml    # Strict mode (fails on warnings)
#

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Parse options
STRICT_MODE=false
YAML_CHECK_ARGS=()
FILES=()

for arg in "$@"; do
    if [[ "$arg" == "--strict" ]]; then
        STRICT_MODE=true
    elif [[ "$arg" == --* ]]; then
        YAML_CHECK_ARGS+=("$arg")
    else
        FILES+=("$arg")
    fi
done

# Default to all YAML files if none specified
if [[ ${#FILES[@]} -eq 0 ]]; then
    mapfile -t FILES < <(find "$PROJECT_ROOT" -name "*.yml" -o -name "*.yaml" | sort)
    
    if [[ ${#FILES[@]} -eq 0 ]]; then
        echo "No YAML files found in project."
        exit 0
    fi
fi

# Check if Python is available
if ! command -v python3 >/dev/null 2>&1; then
    echo "Error: python3 is required for YAML validation"
    exit 1
fi

# Create a temporary Python script for YAML validation
TEMP_CHECKER=$(mktemp)
trap 'rm -f "$TEMP_CHECKER"' EXIT

cat > "$TEMP_CHECKER" << 'EOF'
#!/usr/bin/env python3
import sys
import yaml
from pathlib import Path

def check_yaml_file(file_path, strict=False):
    """Check a single YAML file for syntax errors."""
    try:
        with open(file_path, 'r', encoding='utf-8') as f:
            content = f.read()
            
        # Try to parse the YAML
        try:
            documents = list(yaml.safe_load_all(content))
        except yaml.YAMLError as e:
            print(f"❌ YAML Error in {file_path}:")
            print(f"   {e}")
            return False
            
        # Check for empty documents
        if not documents or all(doc is None for doc in documents):
            if strict:
                print(f"⚠️  Warning in {file_path}: File contains no documents")
                return False
            else:
                print(f"⚠️  Warning in {file_path}: File contains no documents")
        
        # Additional checks for GitHub Actions workflows
        if file_path.endswith(('.yml', '.yaml')) and '/.github/workflows/' in str(file_path):
            for doc in documents:
                if doc and isinstance(doc, dict):
                    # Basic GitHub Actions structure validation
                    if 'on' not in doc and 'jobs' not in doc:
                        if strict:
                            print(f"⚠️  Warning in {file_path}: Missing 'on' or 'jobs' (not a valid GitHub Actions workflow)")
                            return False
        
        print(f"✅ {file_path}")
        return True
        
    except FileNotFoundError:
        print(f"❌ File not found: {file_path}")
        return False
    except Exception as e:
        print(f"❌ Error reading {file_path}: {e}")
        return False

def main():
    if len(sys.argv) < 2:
        print("Usage: python3 yaml_checker.py [--strict] <file1> [file2] ...")
        sys.exit(1)
    
    strict = False
    files = []
    
    for arg in sys.argv[1:]:
        if arg == '--strict':
            strict = True
        else:
            files.append(arg)
    
    if not files:
        print("No files specified")
        sys.exit(1)
    
    all_passed = True
    for file_path in files:
        if not check_yaml_file(file_path, strict):
            all_passed = False
    
    if all_passed:
        print(f"\n✅ All {len(files)} YAML files passed validation")
    else:
        print(f"\n❌ Some YAML files failed validation")
        sys.exit(1)

if __name__ == '__main__':
    main()
EOF

# Convert absolute paths to relative for display
RELATIVE_FILES=()
for file in "${FILES[@]}"; do
    RELATIVE_FILES+=("${file#$PROJECT_ROOT/}")
done

echo "Checking YAML syntax for ${#FILES[@]} files..."

# Run the Python checker
if [[ "$STRICT_MODE" == true ]]; then
    python3 "$TEMP_CHECKER" --strict "${FILES[@]}"
else
    python3 "$TEMP_CHECKER" "${FILES[@]}"
fi
