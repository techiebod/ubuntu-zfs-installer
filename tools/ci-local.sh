#!/usr/bin/env bash
#
# Local CI Runner
#
# Extracts and runs the exact same commands from .github/workflows/ci.yml

set -euo pipefail

echo "📥 Extracting shell run commands from CI YAML..."

# Use Python to extract run commands from the YAML workflow
python3 -c "
import yaml
import sys

try:
    with open('.github/workflows/ci.yml', 'r') as f:
        workflow = yaml.safe_load(f)
    
    for job_name, job in workflow.get('jobs', {}).items():
        for step in job.get('steps', []):
            if 'run' in step:
                print(step['run'])
except Exception as e:
    print(f'Error reading workflow: {e}', file=sys.stderr)
    sys.exit(1)
" | while read -r cmd; do
  echo "➡️ Running: $cmd"
  eval "$cmd"
done
