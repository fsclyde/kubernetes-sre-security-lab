#!/bin/bash
set -euo pipefail

# Keep the standard macOS and Homebrew locations available even if this script
# is launched from a shell whose PATH was customized.
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SECRETS_FILE="$ROOT_DIR/.local/lab-secrets.env"
BASE_URL="${GATEWAY_URL:-http://localhost:8080}"
KEYCLOAK_URL="http://keycloak.identity.svc.cluster.local:8080/realms/sre-lab/protocol/openid-connect/token"

if [[ ! -f "$SECRETS_FILE" ]]; then
  echo "Missing .local/lab-secrets.env. Run ./scripts/bootstrap-secrets.sh first." >&2
  exit 1
fi

if ! command -v curl >/dev/null || ! command -v jq >/dev/null; then
  echo "This smoke test needs curl and jq. On macOS, run: brew install curl jq" >&2
  exit 1
fi

# shellcheck disable=SC1090
source "$SECRETS_FILE"
: "${HOLMES_CLIENT_SECRET:?Missing HOLMES_CLIENT_SECRET in .local/lab-secrets.env}"
: "${OPERATOR_CLIENT_SECRET:?Missing OPERATOR_CLIENT_SECRET in .local/lab-secrets.env}"

get_token() {
  local client="$1" secret="$2"
  curl --fail --silent --show-error \
    --connect-to keycloak.identity.svc.cluster.local:8080:127.0.0.1:8081 \
    --user "$client:$secret" \
    --data-urlencode grant_type=client_credentials \
    "$KEYCLOAK_URL" | jq --exit-status --raw-output .access_token
}

HOLMES_TOKEN="$(get_token holmes "$HOLMES_CLIENT_SECRET")"
OPERATOR_TOKEN="$(get_token operator "$OPERATOR_CLIENT_SECRET")"

INIT_BODY='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"lab-smoke-test","version":"1.0"}}}'

status_for() {
  local path="$1" token="${2:-}"
  curl --silent --show-error --output /dev/null --write-out '%{http_code}' \
    --request POST "$BASE_URL$path" \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    -H "Authorization: Bearer $token" \
    --data "$INIT_BODY"
}

expect_status() {
  local label="$1" expected="$2" actual
  shift 2
  actual="$(status_for "$@")"
  if [[ "$actual" != "$expected" ]]; then
    printf 'FAIL %-34s expected HTTP %s, got %s\n' "$label" "$expected" "$actual"
    return 1
  fi
  printf 'PASS %s (HTTP %s)\n' "$label" "$actual"
}

expect_2xx() {
  local label="$1" actual
  shift
  actual="$(status_for "$@")"
  if [[ ! "$actual" =~ ^2[0-9][0-9]$ ]]; then
    printf 'FAIL %-34s expected HTTP 2xx, got %s\n' "$label" "$actual"
    return 1
  fi
  printf 'PASS %s (HTTP %s)\n' "$label" "$actual"
}

echo "Checking the Gateway and MCP routes at $BASE_URL"
expect_status 'Missing token is rejected' 401 /mcp
expect_2xx 'Holmes → GitHub MCP' /mcp "$HOLMES_TOKEN"
expect_2xx 'Holmes → Kubernetes read MCP' /mcp/k8s-read "$HOLMES_TOKEN"
expect_2xx 'Operator → Kubernetes write MCP' /mcp/k8s-write "$OPERATOR_TOKEN"

echo "Smoke test passed. This checks MCP initialization and Gateway authentication; it does not call the paid Anthropic API."
