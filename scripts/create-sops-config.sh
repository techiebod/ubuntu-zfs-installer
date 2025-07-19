#!/bin/bash
# create-sops-config.sh — Generate .sops.yaml from your age key

set -euo pipefail

KEYFILE="${HOME}/.config/sops/age/keys.txt"
SOPS_CONFIG=".sops.yaml"

if [[ ! -f "$KEYFILE" ]]; then
  echo "❌ Age key not found at: $KEYFILE"
  echo "Generate one with: age-keygen -o $KEYFILE"
  exit 1
fi

PUBKEY=$(grep -o 'age1[[:alnum:]]*' "$KEYFILE" | head -n1)

if [[ -z "$PUBKEY" ]]; then
  echo "❌ Failed to extract public key from $KEYFILE"
  exit 1
fi

cat <<EOF > "$SOPS_CONFIG"
# .sops.yaml — auto-generated
creation_rules:
  - path_regex: config/secrets.sops.yaml
    encrypted_regex: '^(users|secrets)$'
    age:
      - $PUBKEY
EOF

echo "✅ Created $SOPS_CONFIG with public key:"
echo "   $PUBKEY"
