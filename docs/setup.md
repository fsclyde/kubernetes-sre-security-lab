# Setup commands

> **Current scope:** these commands prepare the audited `kind` cluster, install the agentgateway control plane, apply the lab RBAC, and run the RBAC proof. They do not deploy the full agent scenario yet. Keycloak, the Holmes and operator deployments, MCP routes, demo workload, and Falco/Tetragon configuration are not in this branch yet.

## Prerequisites

On macOS with Homebrew:

```bash
brew install kind kubectl helm jq
```

Install and start Docker Desktop separately. Allocate at least 8 GB of memory to Docker for the planned full lab. Confirm the tools and Docker engine are available:

```bash
docker version
kind version
kubectl version --client
helm version
jq --version
```

## Clone the lab branch

```bash
git clone --single-branch --branch codex/kubernetes-sre-security-lab \
  https://github.com/fsclyde/kubernetes-sre-security-lab.git
cd kubernetes-sre-security-lab
```

## Create the audited local cluster

The kind configuration mounts the audit policy and audit log directory from `.local/`. Create those paths before creating the cluster:

```bash
mkdir -p .local/k8s-audit
cp kind/audit-policy.yaml .local/audit-policy.yaml
kind create cluster --config kind/cluster.yaml --wait 120s
kubectl config use-context kind-agent-security-lab
kubectl cluster-info
```

## Install Gateway API and agentgateway

The control plane is installed for the later authenticated routes. Gateway API CRDs and the agentgateway charts are pinned to the versions used by this lab.

```bash
kubectl apply --server-side --force-conflicts \
  -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.2/standard-install.yaml

helm upgrade --install agentgateway-crds \
  oci://cr.agentgateway.dev/charts/agentgateway-crds \
  --create-namespace \
  --namespace agentgateway-system \
  --version v1.6.0 \
  --wait --timeout 5m

helm upgrade --install agentgateway \
  oci://cr.agentgateway.dev/charts/agentgateway \
  --namespace agentgateway-system \
  --version v1.6.0 \
  --wait --timeout 5m

kubectl get pods -n agentgateway-system
kubectl get crds | grep agentgateway
```

## Apply the least-privilege Kubernetes roles

```bash
kubectl apply -f manifests/rbac/demo-roles.yaml
kubectl get namespaces demo mcp
kubectl get roles,rolebindings -n demo
kubectl get serviceaccounts -n mcp
./scripts/check-rbac.sh
```

The proof script checks the read-only identity and the operator identity against the Kubernetes API. Run it with a cluster-admin context so `kubectl auth can-i --as=...` can impersonate those service accounts.

## Inspect audit records

Audit output is written to `.local/k8s-audit/audit.log` on the host. MCP request records will appear after the MCP servers are deployed and make API calls.

```bash
test -f .local/k8s-audit/audit.log
jq -c 'select(.user.username | startswith("system:serviceaccount:mcp:")) | {user: .user.username, verb, objectRef, responseStatus}' \
  .local/k8s-audit/audit.log
```

To follow the API-server audit log inside the kind node:

```bash
docker exec -it agent-security-lab-control-plane \
  sh -c 'tail -f /var/log/kubernetes/audit.log'
```

## Cleanup

```bash
kind delete cluster --name agent-security-lab
```

This removes the local cluster. The audit files and repository checkout remain on disk.
