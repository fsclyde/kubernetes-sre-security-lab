#!/bin/bash
set -eo pipefail

# Restore standard macOS and Homebrew paths if the calling shell has a broken PATH.
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SECRETS_FILE="$ROOT_DIR/.local/lab-secrets.env"
BASE_URL="${GATEWAY_URL:-http://localhost:8080}"
KEYCLOAK_URL="http://keycloak.identity.svc.cluster.local:8080/realms/sre-lab/protocol/openid-connect/token"
PROTOCOL_VERSION="2025-03-26"
FAILURES=0
PASSES=0

if [[ ! -f "$SECRETS_FILE" ]]; then
  echo "Missing .local/lab-secrets.env. Run ./scripts/bootstrap-secrets.sh first." >&2
  exit 1
fi
if ! command -v curl >/dev/null || ! command -v jq >/dev/null; then
  echo "This test needs curl and jq. On macOS, run: brew install curl jq" >&2
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
INIT_BODY='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"lab-curl-test","version":"1.0"}}}'
MCP_SESSION_ID=""
LAST_RESPONSE=""
NEXT_REQUEST_ID=2
PROBE_SUFFIX="$$-$RANDOM"

set_http_status() {
  local first_line="${LAST_RESPONSE%%$'\r\n'*}"
  if [[ "$first_line" =~ ^HTTP/[0-9.]+[[:space:]]([0-9]{3}) ]]; then
    LAST_STATUS="${BASH_REMATCH[1]}"
  else
    LAST_STATUS="unknown"
  fi
}

print_verbose_response() {
  if [[ "${VERBOSE:-0}" == "1" ]]; then
    printf '%s\n' "$LAST_RESPONSE"
  fi
}

post_mcp() {
  local label="$1" path="$2" token="$3" body="$4" mode="$5"
  if [[ "$mode" == initialize ]]; then
    LAST_RESPONSE="$(curl --silent --show-error --include --request POST "$BASE_URL$path" \
      -H "Authorization: Bearer $token" \
      -H 'Content-Type: application/json' \
      -H 'Accept: application/json, text/event-stream' \
      --data "$body")"
  elif [[ -n "$MCP_SESSION_ID" ]]; then
    LAST_RESPONSE="$(curl --silent --show-error --include --request POST "$BASE_URL$path" \
      -H "Authorization: Bearer $token" \
      -H 'Content-Type: application/json' \
      -H 'Accept: application/json, text/event-stream' \
      -H "MCP-Protocol-Version: $PROTOCOL_VERSION" \
      -H "Mcp-Session-Id: $MCP_SESSION_ID" \
      --data "$body")"
  else
    LAST_RESPONSE="$(curl --silent --show-error --include --request POST "$BASE_URL$path" \
      -H "Authorization: Bearer $token" \
      -H 'Content-Type: application/json' \
      -H 'Accept: application/json, text/event-stream' \
      -H "MCP-Protocol-Version: $PROTOCOL_VERSION" \
      --data "$body")"
  fi
  set_http_status
  if [[ "${VERBOSE:-0}" == "1" ]]; then
    printf '\n--- %s ---\n' "$label"
    print_verbose_response
  fi
}

capture_session_id() {
  local line
  MCP_SESSION_ID=""
  while IFS= read -r line; do
    line="${line%$'\r'}"
    case "${line%%:*}" in
      [Mm]cp-[Ss]ession-[Ii]d)
        MCP_SESSION_ID="${line#*:}"
        MCP_SESSION_ID="${MCP_SESSION_ID# }"
        ;;
    esac
  done <<< "$LAST_RESPONSE"
}

start_mcp_session() {
  local label="$1" path="$2" token="$3" init_status
  post_mcp "$label initialize" "$path" "$token" "$INIT_BODY" initialize
  capture_session_id
  init_status="$LAST_STATUS"
  if [[ ! "$init_status" =~ ^2[0-9][0-9]$ ]]; then
    echo "Could not initialize $label (HTTP $init_status). Set VERBOSE=1 to show the full response." >&2
    print_verbose_response >&2
    exit 1
  fi
  PASSES=$((PASSES + 1))
  printf 'PASS %s initialized (HTTP %s)\n' "$label" "$init_status"
  post_mcp "$label initialized notification" "$path" "$token" \
    '{"jsonrpc":"2.0","method":"notifications/initialized"}' notification
  if [[ ! "$LAST_STATUS" =~ ^2[0-9][0-9]$ ]]; then
    printf 'FAIL %s initialized notification (HTTP %s)\n' "$label" "$LAST_STATUS"
    print_verbose_response >&2
    exit 1
  fi
}

tool_call() {
  local label="$1" path="$2" token="$3" tool="$4" arguments="$5"
  local body request_id="$NEXT_REQUEST_ID"
  NEXT_REQUEST_ID=$((NEXT_REQUEST_ID + 1))
  body="{\"jsonrpc\":\"2.0\",\"id\":$request_id,\"method\":\"tools/call\",\"params\":{\"name\":\"$tool\",\"arguments\":$arguments}}"
  post_mcp "$label" "$path" "$token" "$body" call
}

expect_body() {
  local label="$1" pattern="$2"
  if printf '%s' "$LAST_RESPONSE" | grep -Eiq "$pattern"; then
    PASSES=$((PASSES + 1))
    printf 'PASS %s (HTTP %s; %s)\n' "$label" "$LAST_STATUS" "$(response_reason)"
  else
    printf 'FAIL %s (HTTP %s; expected /%s/)\n' "$label" "$LAST_STATUS" "$pattern"
    FAILURES=$((FAILURES + 1))
    print_verbose_response >&2
  fi
}

response_reason() {
  if printf '%s' "$LAST_RESPONSE" | grep -Eiq 'unknown resource'; then
    echo 'unknown resource'
  elif printf '%s' "$LAST_RESPONSE" | grep -Eiq 'forbidden'; then
    echo 'forbidden'
  elif printf '%s' "$LAST_RESPONSE" | grep -Eiq 'authorization failed|authorization denied'; then
    echo 'authorization denied'
  elif printf '%s' "$LAST_RESPONSE" | grep -Eiq 'HTTP/[0-9.]+[[:space:]]401'; then
    echo 'authentication rejected'
  elif printf '%s' "$LAST_RESPONSE" | grep -Eiq 'unknown tool'; then
    echo 'unknown tool'
  else
    echo 'expected denial observed'
  fi
}

expect_success() {
  local label="$1"
  if printf '%s' "$LAST_RESPONSE" | grep -Eiq '^HTTP/[0-9.]+[[:space:]]2[0-9][0-9]' && \
    ! printf '%s' "$LAST_RESPONSE" | grep -Eiq '"isError"[[:space:]]*:[[:space:]]*true|"error"[[:space:]]*:'; then
    PASSES=$((PASSES + 1))
    printf 'PASS %s (HTTP %s)\n' "$label" "$LAST_STATUS"
  else
    printf 'FAIL %s (HTTP %s; expected successful MCP result)\n' "$label" "$LAST_STATUS"
    FAILURES=$((FAILURES + 1))
    print_verbose_response >&2
  fi
}

echo "Gateway: $BASE_URL"
echo "Expected: 401 without a valid token; 2xx for allowed calls; MCP/Kubernetes denial text for blocked calls."

# Invalid bearer token must be rejected before any MCP backend is reached.
LAST_RESPONSE="$(curl --silent --show-error --include --request POST "$BASE_URL/mcp" \
  -H 'Authorization: Bearer invalid' \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  --data "$INIT_BODY")"
set_http_status
if [[ "${VERBOSE:-0}" == "1" ]]; then
  printf '\n--- Invalid token is rejected ---\n'
  print_verbose_response
fi
expect_body 'Invalid token rejected by Gateway' 'HTTP/[0-9.]+ 401'

# GitHub MCP v2.0.2 uses the consolidated issue_write tool. The gateway allowlist
# excludes it, so the empty-arguments probe is denied before tool validation.
start_mcp_session 'Holmes → GitHub MCP' '/mcp' "$HOLMES_TOKEN"
tool_call 'Holmes issue_write is denied' '/mcp' "$HOLMES_TOKEN" 'issue_write' '{}'
expect_body 'Holmes cannot create GitHub issues' 'unknown resource|unknown tool|authorization failed|authorization denied'
start_mcp_session 'Operator → GitHub MCP' '/mcp' "$OPERATOR_TOKEN"
tool_call 'Operator issue_write is denied' '/mcp' "$OPERATOR_TOKEN" 'issue_write' '{}'
expect_body 'Operator cannot create GitHub issues' 'unknown resource|unknown tool|authorization failed|authorization denied'

# Holmes may read the demo Deployment, but cannot read Secrets or access write tools.
start_mcp_session 'Holmes → Kubernetes read MCP' '/mcp/k8s-read' "$HOLMES_TOKEN"
tool_call 'Holmes reads demo Deployment' '/mcp/k8s-read' "$HOLMES_TOKEN" 'resources_get' \
  '{"apiVersion":"apps/v1","kind":"Deployment","name":"demo-web","namespace":"demo"}'
expect_success 'Holmes can read the demo Deployment'
tool_call 'Holmes Secret read is denied' '/mcp/k8s-read' "$HOLMES_TOKEN" 'resources_get' \
  '{"apiVersion":"v1","kind":"Secret","name":"curl-test-does-not-exist","namespace":"demo"}'
expect_body 'Holmes cannot read Secrets' 'forbidden|unknown resource|authorization failed'
tool_call 'Holmes cross-namespace read is denied' '/mcp/k8s-read' "$HOLMES_TOKEN" 'resources_get' \
  "{\"apiVersion\":\"apps/v1\",\"kind\":\"Deployment\",\"name\":\"curl-test-$PROBE_SUFFIX\",\"namespace\":\"kube-system\"}"
expect_body 'Holmes cannot read outside demo' 'forbidden|unknown resource|authorization failed'
tool_call 'Holmes exec attempt is denied' '/mcp/k8s-read' "$HOLMES_TOKEN" 'pods_exec' \
  "{\"name\":\"curl-test-$PROBE_SUFFIX\",\"namespace\":\"demo\",\"command\":[\"true\"]}"
expect_body 'Holmes cannot exec in Pods' 'forbidden|unknown resource|unknown tool|authorization failed'
tool_call 'Holmes Deployment scale attempt is denied' '/mcp/k8s-read' "$HOLMES_TOKEN" 'resources_scale' \
  "{\"apiVersion\":\"apps/v1\",\"kind\":\"Deployment\",\"name\":\"curl-test-$PROBE_SUFFIX\",\"namespace\":\"demo\",\"scale\":1}"
expect_body 'Holmes cannot modify Deployments' 'forbidden|unknown resource|unknown tool|authorization failed'

# The Gateway must reject Holmes on the write backend before the fake delete reaches Kubernetes.
start_mcp_session 'Holmes → Kubernetes write MCP (denial probe)' '/mcp/k8s-write' "$HOLMES_TOKEN"
tool_call 'Holmes pod-delete attempt is denied' '/mcp/k8s-write' "$HOLMES_TOKEN" 'pods_delete' \
  "{\"name\":\"curl-test-pod-$PROBE_SUFFIX\",\"namespace\":\"demo\"}"
expect_body 'Holmes cannot use the write backend' 'unknown resource|unknown tool|authorization failed|authorization denied'

# Operator may use the write backend, but its Kubernetes ServiceAccount is limited to Deployments in demo.
start_mcp_session 'Operator → Kubernetes write MCP' '/mcp/k8s-write' "$OPERATOR_TOKEN"
tool_call 'Operator reads demo Deployment' '/mcp/k8s-write' "$OPERATOR_TOKEN" 'resources_get' \
  '{"apiVersion":"apps/v1","kind":"Deployment","name":"demo-web","namespace":"demo"}'
expect_success 'Operator can access the demo Deployment'
tool_call 'Operator Secret read is denied' '/mcp/k8s-write' "$OPERATOR_TOKEN" 'resources_get' \
  '{"apiVersion":"v1","kind":"Secret","name":"curl-test-does-not-exist","namespace":"demo"}'
expect_body 'Operator cannot read Secrets' 'forbidden|unknown resource|authorization failed'
tool_call 'Operator Pod delete is denied' '/mcp/k8s-write' "$OPERATOR_TOKEN" 'pods_delete' \
  "{\"name\":\"curl-test-pod-$PROBE_SUFFIX\",\"namespace\":\"demo\"}"
expect_body 'Operator cannot delete Pods' 'forbidden|unknown resource|authorization failed'
tool_call 'Operator Pod exec is denied' '/mcp/k8s-write' "$OPERATOR_TOKEN" 'pods_exec' \
  "{\"name\":\"curl-test-$PROBE_SUFFIX\",\"namespace\":\"demo\",\"command\":[\"true\"]}"
expect_body 'Operator cannot exec in Pods' 'forbidden|unknown resource|authorization failed'
tool_call 'Operator write outside demo is denied' '/mcp/k8s-write' "$OPERATOR_TOKEN" 'resources_scale' \
  "{\"apiVersion\":\"apps/v1\",\"kind\":\"Deployment\",\"name\":\"curl-test-$PROBE_SUFFIX\",\"namespace\":\"kube-system\",\"scale\":1}"
expect_body 'Operator cannot modify Deployments outside demo' 'forbidden|unknown resource|authorization failed'

echo
if [[ "$FAILURES" -eq 0 ]]; then
  printf 'Result: %s checks passed.\n' "$PASSES"
else
  printf 'Result: %s passed; %s failed. Set VERBOSE=1 for full responses; check Gateway/MCP logs for details.\n' "$PASSES" "$FAILURES"
  exit 1
fi
echo 'No model request was sent; this test does not incur Anthropic API usage.'
