#!/bin/bash
# Runs after xcodebuild archive, before Xcode Cloud exports+uploads to TestFlight.
# Writes the ASC API key so xcodebuild's exportArchive step uses API key auth
# instead of the expired Session Proxy Provider (Apple ID session).

set -euo pipefail

KEY_ID="WQLSW6398S"
ISSUER_ID="cc920828-bbbd-40ca-9135-fb1a5c30dacd"
KEY_B64="REDACTED_ASC_KEY"

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
