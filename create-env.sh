#!/usr/bin/env bash
#
# Only to be run in local development
set -euo pipefail

PRIVATE_KEY_B64=$(jq -r '.private_key' google-drive-service-key.json | base64)
CLIENT_EMAIL=$(jq -r '.client_email' google-drive-service-key.json)

cat > .env <<EOF
PRIVATE_KEY_B64=$PRIVATE_KEY_B64
CLIENT_EMAIL=$CLIENT_EMAIL
EOF

echo "Created .env"
