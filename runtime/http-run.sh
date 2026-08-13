#!/usr/bin/env bash
set -euo pipefail

readonly GBRAIN_BIN=/usr/local/bin/gbrain
readonly TOKEN_FILE=/data/.gbrain/admin-bootstrap-token
readonly ENV_BRIDGE=/app/runtime/gbrain-env-bridge.sh

export HOME=/data
export GBRAIN_HTTP_TRUST_PROXY=1

if [[ ! -x "$GBRAIN_BIN" ]]; then
  printf '[gbrain-http] missing executable: %s\n' "$GBRAIN_BIN" >&2
  exit 78
fi

if [[ ! -r "$ENV_BRIDGE" ]]; then
  printf '[gbrain-http] missing env bridge: %s\n' "$ENV_BRIDGE" >&2
  exit 78
fi

source "$ENV_BRIDGE"

mkdir -p /data/.gbrain

if [[ ! -s "$TOKEN_FILE" ]]; then
  umask 077
  /usr/bin/python3 -c 'import secrets; print(secrets.token_hex(32))' > "${TOKEN_FILE}.tmp"
  chmod 600 "${TOKEN_FILE}.tmp"
  mv "${TOKEN_FILE}.tmp" "$TOKEN_FILE"
fi

export GBRAIN_ADMIN_BOOTSTRAP_TOKEN
GBRAIN_ADMIN_BOOTSTRAP_TOKEN="$(<"$TOKEN_FILE")"

if [[ ! "$GBRAIN_ADMIN_BOOTSTRAP_TOKEN" =~ ^[A-Za-z0-9_-]{32,}$ ]]; then
  printf '%s\n' '[gbrain-http] invalid admin bootstrap token file' >&2
  exit 78
fi

cd /data/brain

exec "$GBRAIN_BIN" serve \
  --http \
  --port 3131 \
  --bind 0.0.0.0 \
  --public-url https://gbrain-edge.onrender.com \
  --surface full \
  --suppress-bootstrap-token
