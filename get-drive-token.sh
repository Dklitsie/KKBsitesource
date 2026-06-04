#!/usr/bin/env bash
set -euo pipefail


PRIVATE_KEY_FILE=$(mktemp)
echo "$PRIVATE_KEY" > "$PRIVATE_KEY_FILE"

NOW=$(date +%s)
EXP=$((NOW + 3600))

HEADER='{"alg":"RS256","typ":"JWT"}'

PAYLOAD=$(jq -nc \
  --arg iss "$CLIENT_EMAIL" \
  --arg scope "https://www.googleapis.com/auth/drive.readonly" \
  --arg aud "https://oauth2.googleapis.com/token" \
  --argjson iat "$NOW" \
  --argjson exp "$EXP" \
  '{iss:$iss,scope:$scope,aud:$aud,iat:$iat,exp:$exp}')

b64url() {
    openssl base64 -A | tr '+/' '-_' | tr -d '='
}

HEADER_B64=$(printf '%s' "$HEADER" | b64url)
PAYLOAD_B64=$(printf '%s' "$PAYLOAD" | b64url)

UNSIGNED="${HEADER_B64}.${PAYLOAD_B64}"

SIG=$(printf '%s' "$UNSIGNED" \
    | openssl dgst -sha256 -sign "$PRIVATE_KEY_FILE" \
    | b64url)

JWT="${UNSIGNED}.${SIG}"

ACCESS_TOKEN=$(
curl -s https://oauth2.googleapis.com/token \
    -d grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer \
    --data-urlencode assertion="$JWT" \
    | jq -r '.access_token'
)

rm "$PRIVATE_KEY_FILE"

echo "$ACCESS_TOKEN"
