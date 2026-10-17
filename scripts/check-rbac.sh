#!/usr/bin/env bash
set -euo pipefail

READ_IDENTITY='system:serviceaccount:mcp:k8s-mcp-read'
WRITE_IDENTITY='system:serviceaccount:mcp:k8s-mcp-write'
PASS=0
FAIL=0

check() {
  local description="$1"
  local expected="$2"
  shift 2

  local actual
  actual="$(kubectl auth can-i "$@")"
  if [[ "$actual" == "$expected" ]]; then
    printf '[PASS] %s -> %s\n' "$description" "$actual"
    PASS=$((PASS + 1))
  else
    printf '[FAIL] %s -> expected %s, got %s\n' "$description" "$expected" "$actual"
    FAIL=$((FAIL + 1))
  fi
}

kubectl get namespace demo >/dev/null
kubectl get namespace mcp >/dev/null

check 'Holmes can list demo pods' yes list pods -n demo --as="$READ_IDENTITY"
check 'Holmes can read demo pod logs' yes get pods/log -n demo --as="$READ_IDENTITY"
check 'Holmes cannot read demo Secrets' no get secrets -n demo --as="$READ_IDENTITY"
check 'Holmes cannot patch demo Deployments' no patch deployments.apps -n demo --as="$READ_IDENTITY"
check 'Holmes cannot create pod exec sessions' no create pods/exec -n demo --as="$READ_IDENTITY"
check 'Holmes cannot read pods in default namespace' no list pods -n default --as="$READ_IDENTITY"
check 'Operator can patch demo Deployments' yes patch deployments.apps -n demo --as="$WRITE_IDENTITY"
check 'Operator cannot delete demo Deployments' no delete deployments.apps -n demo --as="$WRITE_IDENTITY"
check 'Operator cannot read demo Secrets' no get secrets -n demo --as="$WRITE_IDENTITY"
check 'Operator cannot patch Deployments outside demo' no patch deployments.apps -n default --as="$WRITE_IDENTITY"

printf '\nRBAC proof: %s passed, %s failed\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then
  exit 1
fi
