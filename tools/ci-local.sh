#!/usr/bin/env bash
#
# Local CI Runner
#
# Extracts and runs the exact same commands from .github/workflows/ci.yml

set -euo pipefail

echo "📥 Extracting shell run commands from CI YAML..."

# Set up GitHub Actions environment variables for local execution
export GITHUB_STEP_SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"

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
                # Handle both single line and multiline run commands
                run_command = step['run']
                if isinstance(run_command, str):
                    # For multiline commands, we need to treat them as a single block
                    print('---COMMAND_START---')
                    print(run_command.strip())
                    print('---COMMAND_END---')
                else:
                    print('---COMMAND_START---')
                    print(str(run_command).strip())
                    print('---COMMAND_END---')
except Exception as e:
    print(f'Error reading workflow: {e}', file=sys.stderr)
    sys.exit(1)
" | {
  command=""
  in_command=false
  
  while IFS= read -r line; do
    if [[ "$line" == "---COMMAND_START---" ]]; then
      in_command=true
      command=""
    elif [[ "$line" == "---COMMAND_END---" ]]; then
      in_command=false
      if [[ -n "$command" ]]; then
        # Skip commands that contain GitHub Actions template syntax
        if [[ "$command" =~ \$\{\{.*\}\} ]]; then
          echo "⏭️  Skipping GitHub Actions template command"
        else
          # Show first line of command for display
          first_line=$(echo "$command" | head -n1)
          if [[ $(echo "$command" | wc -l) -gt 1 ]]; then
            echo "➡️ Running: $first_line..."
          else
            echo "➡️ Running: $command"
          fi
          eval "$command"
        fi
      fi
    elif [[ "$in_command" == true ]]; then
      if [[ -n "$command" ]]; then
        command="$command"$'\n'"$line"
      else
        command="$line"
      fi
    fi
  done
}
