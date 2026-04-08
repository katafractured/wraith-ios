#!/bin/bash
# Runs after xcodebuild archive, before Xcode Cloud exports+uploads to TestFlight.
# Writes the ASC API key so xcodebuild's exportArchive step uses API key auth
# instead of the expired Session Proxy Provider (Apple ID session).

set -euo pipefail

KEY_ID="WQLSW6398S"
ISSUER_ID="cc920828-bbbd-40ca-9135-fb1a5c30dacd"
KEY_B64="LS0tLS1CRUdJTiBQUklWQVRFIEtFWS0tLS0tCk1JR1RBZ0VBTUJNR0J5cUdTTTQ5QWdFR0NDcUdTTTQ5QXdFSEJIa3dkd0lCQVFRZ3k2VlFzK1BKSFF6WFJkWTgKSUxHSm1uMmFQczJIeTJDL0FKL2RrRWVQVExXZ0NnWUlLb1pJemowREFRZWhSQU5DQUFRMG5kYStsTFc1VVhjWgpQZnJTdm5OUmFiMXdMcG0xYnorVklMdDFGaHh4RWlydVZKZGVHQVU0Wms3ay84UU1EUHBYRmRYODgvM2xhd1hmCjJhTW9ETEZECi0tLS0tRU5EIFBSSVZBVEUgS0VZLS0tLS0="

# Write .p8 to the location xcodebuild searches automatically
KEYS_DIR="$HOME/.appstoreconnect/private_keys"
mkdir -p "$KEYS_DIR"
echo "$KEY_B64" | base64 --decode > "$KEYS_DIR/AuthKey_${KEY_ID}.p8"
chmod 600 "$KEYS_DIR/AuthKey_${KEY_ID}.p8"

# Also export env vars (belt and suspenders — Xcode Cloud may source this)
export APP_STORE_CONNECT_API_KEY_KEY_ID="$KEY_ID"
export APP_STORE_CONNECT_API_KEY_ISSUER_ID="$ISSUER_ID"
export APP_STORE_CONNECT_API_KEY_CONTENT="$KEY_B64"

echo "ci_post_xcodebuild: ASC API key written to $KEYS_DIR/AuthKey_${KEY_ID}.p8"
