# Full lab setup

These commands build the local demonstration stack. They are written for macOS with Docker Desktop and `kind`. The manifests are secret-free. Review [known validation gaps](validation-gaps.md) before using a production cluster.

## 1. Install local tools

```bash
brew install kind kubectl helm jq gettext openssl
```

Start Docker Desktop and allocate at least 10 GB memory for the full stack. Confirm access:

```bash
docker version
kind version
kubectl version --client
helm version
jq --version
envsubst --version
```

## 2. Clone the feature branch

```bash
git clone --single-branch --branch codex/kubernetes-sre-security-lab \
  https://github.com/fsclyde/kubernetes-sre-security-lab.git
cd kubernetes-sre-security-lab
```

## 3. Create the audited cluster and install Calico

The cluster disables kind's default CNI so Calico can enforce NetworkPolicies. Prepare the audit mount paths before creating the cluster.

```bash
mkdir -p .local/k8s-audit
cp kind/audit-policy.yaml .local/audit-policy.yaml
kind create cluster --config kind/cluster.yaml --wait 120s
kubectl config use-context kind-agent-security-lab
kubectl cluster-info
./scripts/install-calico.sh
```

Install Gateway API and the agentgateway control plane:

```bash
kubectl apply --server-side --force-conflicts \
  -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.2/standard-install.yaml

helm upgrade --install agentgateway-crds \
  oci://cr.agentgateway.dev/charts/agentgateway-crds \
  --create-namespace --namespace agentgateway-system \
  --version v1.6.0 --wait --timeout 5m

helm upgrade --install agentgateway \
  oci://cr.agentgateway.dev/charts/agentgateway \
  --namespace agentgateway-system --version v1.6.0 \
  --wait --timeout 5m
```

Create the namespaces, base RBAC, and separate Kubernetes MCP servers:

```bash
kubectl apply -f manifests/networking/namespaces.yaml
kubectl create namespace demo --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace mcp --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f manifests/rbac/demo-roles.yaml

helm upgrade --install k8s-mcp-read \
  oci://ghcr.io/containers/charts/kubernetes-mcp-server \
  --version 0.1.0 --namespace mcp \
  --values manifests/mcp/read-values.yaml --wait --timeout 5m

helm upgrade --install k8s-mcp-write \
  oci://ghcr.io/containers/charts/kubernetes-mcp-server \
  --version 0.1.0 --namespace mcp \
  --values manifests/mcp/write-values.yaml --wait --timeout 5m

kubectl patch service k8s-mcp-read -n mcp --type=json \
  -p='[{"op":"add","path":"/spec/ports/0/appProtocol","value":"agentgateway.dev/mcp"}]'
kubectl patch service k8s-mcp-write -n mcp --type=json \
  -p='[{"op":"add","path":"/spec/ports/0/appProtocol","value":"agentgateway.dev/mcp"}]'
```

## 4. Create credentials and install Keycloak

Create a fine-grained GitHub token with read-only access to the demo repository and have an Anthropic API key ready. The bootstrap script prompts for these values and stores them in ignored `.local/` files with owner-only permissions.

```bash
./scripts/bootstrap-secrets.sh
kubectl apply -f manifests/keycloak/keycloak.yaml
kubectl rollout status deployment/keycloak -n identity --timeout=5m
```

The Keycloak realm creates separate `holmes` and `operator` confidential clients and uses a 300-second access token lifetime. The GitHub credential and Anthropic API key are stored only as Kubernetes Secrets in the gateway namespace.

## 5. Deploy the demo app and GitHub MCP

```bash
kubectl apply -f manifests/demo/app.yaml
kubectl apply -f manifests/github-mcp/deployment.yaml
kubectl rollout status deployment/demo-web -n demo --timeout=3m
kubectl rollout status deployment/github-mcp -n mcp --timeout=3m
```

The GitHub MCP container runs in HTTP mode. Its upstream token and `X-MCP-Readonly` header are injected by the gateway backend. The network policy allows this one pod outbound HTTPS; Kubernetes NetworkPolicy does not provide domain-based egress matching, so the allowed public IP range is broad.

## 6. Apply the Gateway API routes and policies

```bash
kubectl apply -f manifests/agentgateway/routes.yaml
kubectl get gateway,httproute,agentgatewaybackend,agentgatewaypolicy -A
kubectl get pods -n agentgateway-system
```

The Gateway accepts only Keycloak JWTs. The GitHub MCP backend has a tool allowlist, and only the `operator` client can reach the write-capable Kubernetes MCP backend. The Anthropic credential remains with agentgateway. Port-forward for local inspection:

```bash
kubectl port-forward -n agentgateway-system svc/agentgateway-proxy 8080:80
```

Start a second port-forward for Keycloak in another terminal:

```bash
kubectl port-forward -n identity svc/keycloak 8081:8080
```

Then use Keycloak's client-credentials flow to get a temporary token, after setting the client secret from `.local/lab-secrets.env`:

```bash
set -a
source .local/lab-secrets.env
set +a
HOLMES_TOKEN="$(curl --fail --silent --show-error \
  -u "holmes:${HOLMES_CLIENT_SECRET}" \
  -d grant_type=client_credentials \
  http://localhost:8081/realms/sre-lab/protocol/openid-connect/token | jq -r .access_token)"
```

The Gateway routes are `/mcp` for GitHub MCP, `/mcp/k8s-read` and `/mcp/k8s-write` for the Kubernetes MCP servers, and `/v1/messages` for Anthropic.

## 7. Deploy HolmesGPT and the operator release

The repository contains separate values files so each Holmes release has its own namespace and identity boundary. The built-in Kubernetes, Bash, internet, and default integrations are disabled.

```bash
helm repo add robusta https://robusta-charts.storage.googleapis.com
helm repo update

helm upgrade --install holmes robusta/holmes \
  --namespace holmes --create-namespace \
  --values manifests/holmes/values.yaml --wait --timeout 10m

helm upgrade --install operator robusta/holmes \
  --namespace operator --create-namespace \
  --values manifests/operator/values.yaml --wait --timeout 10m
```

The two releases provide separate HolmesGPT deployments for investigation and repair. Connect their MCP and model clients to the authenticated gateway endpoints. Automated Keycloak client-credentials refresh inside the Holmes chart is still an integration item; do not put a long-lived bearer token in a ConfigMap or values file. The operator should be activated by the learner only for the repair step.

## 8. Apply NetworkPolicies and verify RBAC

Apply default-deny and allow rules only after required components are running:

```bash
kubectl apply -f manifests/networking/policies.yaml
./scripts/check-rbac.sh
kubectl get networkpolicy -A
```

The `mcp` servers can reach the Kubernetes API, while Holmes and operator pods do not get direct Kubernetes API egress. Policies are enforced by Calico, not kind's default networking.

## 9. Optional runtime detection

Install Falco for runtime events:

```bash
helm repo add falcosecurity https://falcosecurity.github.io/charts
helm repo update
helm upgrade --install falco falcosecurity/falco \
  --namespace falco --create-namespace \
  --values manifests/falco/values.yaml --wait --timeout 10m
```

The Kubernetes API audit log is written to `.local/k8s-audit/audit.log`. The current Falco values install runtime detection but do not yet configure the Falco Kubernetes audit webhook plugin; correlate audit records from the file directly until that integration is completed.

Tetragon needs a Linux kernel with BTF/eBPF support. Docker Desktop runs kind inside a Linux VM; support depends on the kernel exposed by that VM. Check whether the kind node can see BTF:

```bash
./scripts/check-tetragon-kernel.sh
```

On native Linux, install with the upstream chart after confirming the node kernel prerequisites:

```bash
helm repo add cilium https://helm.cilium.io
helm repo update
helm upgrade --install tetragon cilium/tetragon \
  --namespace kube-system --wait --timeout 10m
```

On Docker Desktop, skip Tetragon if its DaemonSet cannot load eBPF programs. Use the Tetragon FAQ and kind instructions in the references before troubleshooting kernel support.

## 10. Inspect and clean up

```bash
kubectl get pods -A
kubectl get gateway,httproute,agentgatewaybackend,agentgatewaypolicy -A
jq -c 'select(.user.username | startswith("system:serviceaccount:mcp:")) | {user: .user.username, verb, objectRef, responseStatus}' \
  .local/k8s-audit/audit.log
kind delete cluster --name agent-security-lab
```

Deleting the cluster leaves the repository checkout and local audit/secret files in place. Remove `.local/` manually when you no longer need those artifacts.
