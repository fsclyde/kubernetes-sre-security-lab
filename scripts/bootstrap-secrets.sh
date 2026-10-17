#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCAL_DIR="$ROOT_DIR/.local"
mkdir -p "$LOCAL_DIR"
chmod 700 "$LOCAL_DIR"

if [[ ! -f "$LOCAL_DIR/lab-secrets.env" ]]; then
  umask 077
  HOLMES_CLIENT_SECRET="$(openssl rand -hex 32)"
  OPERATOR_CLIENT_SECRET="$(openssl rand -hex 32)"
  KEYCLOAK_ADMIN_PASSWORD="$(openssl rand -hex 24)"
  read -r -s -p "Anthropic API key: " ANTHROPIC_API_KEY
  printf '\n'
  read -r -s -p "Fine-grained, read-only GitHub token: " GITHUB_TOKEN
  printf '\n'
  cat > "$LOCAL_DIR/lab-secrets.env" <<EOF
HOLMES_CLIENT_SECRET=$HOLMES_CLIENT_SECRET
OPERATOR_CLIENT_SECRET=$OPERATOR_CLIENT_SECRET
KEYCLOAK_ADMIN_PASSWORD=$KEYCLOAK_ADMIN_PASSWORD
ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY
GITHUB_TOKEN=$GITHUB_TOKEN
EOF
  chmod 600 "$LOCAL_DIR/lab-secrets.env"
fi

set -a
# shellcheck disable=SC1090
source "$LOCAL_DIR/lab-secrets.env"
set +a

mkdir -p "$LOCAL_DIR/keycloak-import"
envsubst '${HOLMES_CLIENT_SECRET} ${OPERATOR_CLIENT_SECRET}' \
  < "$ROOT_DIR/manifests/keycloak/realm.json.template" \
  > "$LOCAL_DIR/keycloak-import/sre-lab-realm.json"
chmod 600 "$LOCAL_DIR/keycloak-import/sre-lab-realm.json"

kubectl -n identity create secret generic keycloak-admin \
  --from-literal=password="$KEYCLOAK_ADMIN_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n agentgateway-system create secret generic anthropic-secret \
  --from-literal=Authorization="$ANTHROPIC_API_KEY" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n agentgateway-system create secret generic github-mcp-token \
  --from-literal=token="$GITHUB_TOKEN" \
  --from-literal=readonly=true \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n identity create configmap keycloak-realm \
  --from-file=sre-lab-realm.json="$LOCAL_DIR/keycloak-import/sre-lab-realm.json" \
  --dry-run=client -o yaml | kubectl apply -f -

printf 'Local secrets and Kubernetes Secret/ConfigMap resources are ready.\n'
