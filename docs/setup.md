# Lab setup

This guide installs the local Kubernetes SRE security lab on macOS with Docker Desktop and kind. It includes HolmesGPT investigation, a separately authorized operator, Keycloak, agentgateway, GitHub MCP, and Kubernetes MCP servers.

Review [known validation gaps](validation-gaps.md) before adapting the lab for production.

## Table of contents

- [1. Prerequisites](#1-prerequisites)
- [2. Create the cluster and install the Gateway](#2-create-the-cluster-and-install-the-gateway)
- [3. Install Kubernetes MCP servers](#3-install-kubernetes-mcp-servers)
- [4. Create credentials and deploy identity and demo services](#4-create-credentials-and-deploy-identity-and-demo-services)
- [5. Apply Gateway routes and policies](#5-apply-gateway-routes-and-policies)
- [6. Deploy HolmesGPT and the operator](#6-deploy-holmesgpt-and-the-operator)
- [7. Apply network policies and verify RBAC](#7-apply-network-policies-and-verify-rbac)
- [8. Test the lab](#8-test-the-lab)
- [9. Optional runtime detection](#9-optional-runtime-detection)
- [10. Clean up](#10-clean-up)
- [11. Troubleshooting](#11-troubleshooting)

## 1. Prerequisites

Install tools and start Docker Desktop. Allocate at least 10 GB of memory to Docker.

```bash
brew install kind kubectl helm jq gettext openssl
docker version
kind version
kubectl version --client
helm version
```

## 2. Create the cluster and install the Gateway

The kind cluster disables its default CNI so Calico can enforce NetworkPolicies. Kubernetes 1.35 also needs the MutatingAdmissionPolicy feature gate enabled for Calico 3.33.

```bash
mkdir -p .local/k8s-audit
cp kind/audit-policy.yaml .local/audit-policy.yaml
kind create cluster --config kind/cluster.yaml --wait 120s
kubectl config use-context kind-agent-security-lab
./scripts/install-calico.sh

kubectl apply --server-side --force-conflicts \
  -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.2/standard-install.yaml
helm upgrade --install agentgateway-crds \
  oci://cr.agentgateway.dev/charts/agentgateway-crds \
  --namespace agentgateway-system --create-namespace --version v1.6.0 --wait --timeout 5m
helm upgrade --install agentgateway \
  oci://cr.agentgateway.dev/charts/agentgateway \
  --namespace agentgateway-system --version v1.6.0 --wait --timeout 5m

kubectl apply -f manifests/networking/namespaces.yaml
kubectl create namespace demo --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace mcp --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f manifests/rbac/demo-roles.yaml
```

## 3. Install Kubernetes MCP servers

The read and write servers have separate ServiceAccounts and RBAC. The read server is read-only; the operator server can update Deployments only in demo.

```bash
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

## 4. Create credentials and deploy identity and demo services

Create a fine-grained GitHub token for this repository. Grant **Contents: Read-only** and **Issues: Read-only**; leave other permissions off. The bootstrap script prompts for this token and an Anthropic API key, then writes credentials to ignored local files and Kubernetes Secrets.

```bash
./scripts/bootstrap-secrets.sh
kubectl apply -f manifests/keycloak/keycloak.yaml
kubectl rollout status deployment/keycloak -n identity --timeout=5m

kubectl apply -f manifests/demo/app.yaml
kubectl apply -f manifests/github-mcp/deployment.yaml
kubectl rollout status deployment/demo-web -n demo --timeout=3m
kubectl rollout status deployment/github-mcp -n mcp --timeout=3m
```

The GitHub MCP server is configured for the repos, issues, and pull_requests toolsets. agentgateway injects the GitHub token and a read-only header. Its NetworkPolicy permits HTTPS on port 443; Kubernetes NetworkPolicy cannot restrict that egress by domain, so the IP range is broad.

## 5. Apply Gateway routes and policies

```bash
kubectl apply -f manifests/agentgateway/routes.yaml
kubectl delete agentgatewaypolicy keycloak-jwt -n agentgateway-system --ignore-not-found
kubectl get gateway,httproute,agentgatewaybackend,agentgatewaypolicy -A
```

The GitHub and Kubernetes MCP routes use Keycloak identities. The Anthropic route uses a separate client key; the provider API key stays in a Kubernetes Secret in agentgateway-system.

Holmes performs MCP initialization and lists tool names before it has a caller token. The MCP routes therefore allow only the protocol handshake and tool-list methods without a token. All other requests require a valid Holmes or operator JWT, and backend policies plus Kubernetes RBAC authorize actual tool calls. This keeps discovery working without granting anonymous tool execution.

For local testing, open these port-forwards in separate terminals:

```bash
kubectl port-forward -n agentgateway-system svc/agentgateway-proxy 8080:80
kubectl port-forward -n identity svc/keycloak 8081:8080
```

## 6. Deploy HolmesGPT and the operator

The namespaces enforce Pod Security restricted. The values set non-root UID/GID 10001, RuntimeDefault seccomp, no privilege escalation, and drop all Linux capabilities. The two releases have separate identities and tool access.

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

The MCP server definitions belong at the top level of each values file. Holmes 0.45.0 rejects the unsupported MCP-level allowed_tools field; the Gateway and Kubernetes RBAC enforce the restrictions instead.

Open Holmes API port-forwards in separate terminals:

```bash
kubectl port-forward -n holmes deployment/holmes-holmes 5050:5050
kubectl port-forward -n operator deployment/operator-holmes 5051:5050
```

Use the end-to-end investigation and repair prompts in the [lab runbook](lab-runbook.md).

## 7. Apply network policies and verify RBAC

Apply policies after the required services are running. Calico enforces default-deny egress with explicit DNS, Gateway, Kubernetes API, and GitHub MCP exceptions.

```bash
kubectl apply -f manifests/networking/policies.yaml
./scripts/check-rbac.sh
kubectl get networkpolicy -A
kubectl get namespace holmes operator \
  -L pod-security.kubernetes.io/enforce,pod-security.kubernetes.io/enforce-version
```

Holmes and operator pods use the label app=holmes. Their policies allow access to Keycloak and agentgateway, but not direct access to the Kubernetes API.

## 8. Test the lab

With the Gateway and Keycloak port-forwards running:

```bash
/bin/bash scripts/smoke-test.sh
```

The script obtains fresh Holmes and operator tokens and tests Gateway authentication, allowed MCP calls, and expected denials. It does not call Anthropic or modify the cluster. Add VERBOSE=1 to print response headers and bodies:

```bash
VERBOSE=1 /bin/bash scripts/smoke-test.sh
```

The primary security boundaries are:

| Mechanism | Enforced boundary |
| --- | --- |
| Keycloak JWT + Gateway policies | Separates Holmes and operator identities; only operator can use the write route |
| MCP backend policies | Limits GitHub tools and protects Kubernetes MCP routes |
| Kubernetes RBAC | Restricts operator writes to Deployments in demo; Holmes is read-only |
| Calico NetworkPolicy | Default-denies pod traffic and allows required paths only |
| Pod Security restricted | Runs Holmes and operator without root, privilege escalation, or extra capabilities |
| Kubernetes audit policy | Records API activity for review in .local/k8s-audit/audit.log |

## 9. Optional runtime detection

Falco provides runtime events:

```bash
helm repo add falcosecurity https://falcosecurity.github.io/charts
helm repo update
helm upgrade --install falco falcosecurity/falco \
  --namespace falco --create-namespace \
  --values manifests/falco/values.yaml --wait --timeout 10m
```

Tetragon requires Linux kernel BTF/eBPF support. Check the kind node first:

```bash
./scripts/check-tetragon-kernel.sh
```

On a supported native Linux host, install it with:

```bash
helm repo add cilium https://helm.cilium.io
helm repo update
helm upgrade --install tetragon cilium/tetragon \
  --namespace kube-system --wait --timeout 10m
```

Docker Desktop may not expose the kernel features Tetragon needs. Falco and Tetragon are optional.

## 10. Clean up

```bash
kind delete cluster --name agent-security-lab
```

This leaves .local files, including credentials and audit logs. Remove .local manually when they are no longer needed.

## 11. Troubleshooting

### Holmes MCP tools return 401 from agentgateway

The Gateway must allow unauthenticated MCP initialization and tools/list, while requiring JWTs for other methods. Apply the current routes and policies:

```bash
kubectl apply -f manifests/agentgateway/routes.yaml
kubectl get agentgatewaypolicy -A
```

The policy allows only initialize, notifications/initialized, tools/list, and ping without a JWT. A tools/call still needs the incoming Keycloak bearer token. Use a fresh token; this lab's access tokens expire after 300 seconds. Confirm Holmes is configured to forward Authorization: HOLMES_PASSTHROUGH_BLOCKED_HEADERS should be cookie,set-cookie and must not include authorization.

Run the Gateway smoke test. If it passes but Holmes still gets 401, inspect Holmes logs and verify the values were applied:

```bash
kubectl logs -n holmes deployment/holmes-holmes --since=15m
kubectl logs -n operator deployment/operator-holmes --since=15m
kubectl get deployment holmes-holmes -n holmes -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="HOLMES_PASSTHROUGH_BLOCKED_HEADERS")].value}{"\n"}'
```

If a request to /api/chat succeeds but MCP calls fail, confirm the Authorization header is present on that Holmes request. Do not paste bearer tokens into logs or chat.

### Toolset invalid: extra_forbidden

Holmes 0.45.0 rejects allowed_tools in remote MCP server definitions. The supplied values omit it. Reapply the Helm values from section 6; do not enable built-in Kubernetes toolsets as a workaround.

### Holmes has no Kubernetes or GitHub tools

Keep mcp_servers at the top level of the values files. Upgrade both Holmes releases using section 6 and inspect their logs. Tool definitions load from the MCP services.

### Holmes cannot connect to the Gateway

Check the selector and service endpoints:

```bash
kubectl get networkpolicy allow-holmes-to-auth-and-gateway -n holmes -o yaml
kubectl get networkpolicy allow-operator-to-auth-and-gateway -n operator -o yaml
kubectl get svc,endpointslice -n agentgateway-system
```

The Holmes policies must select app=holmes. To probe egress from the Gateway pod itself, start a temporary debug container and try its backend and HTTPS URLs:

```bash
GATEWAY_POD="$(kubectl get pods -n agentgateway-system -l app.kubernetes.io/name=agentgateway-proxy -o jsonpath='{.items[0].metadata.name}')"
kubectl debug -n agentgateway-system -it "pod/$GATEWAY_POD" \
  --image=curlimages/curl:8.11.1 --target=agentgateway-proxy -- sh
```

At the debug prompt, run curl against http://github-mcp.mcp.svc.cluster.local:8082/, http://k8s-mcp-read.mcp.svc.cluster.local:8080/, https://api.anthropic.com/, and https://api.github.com/. An HTTP response proves DNS/TCP/HTTP reachability, but not MCP authorization. A timeout suggests a service endpoint or network path issue. Then run scripts/smoke-test.sh to check the complete authenticated route.

### Anthropic request returns 401

Remove a stale Gateway-wide keycloak-jwt policy; it can incorrectly require Keycloak on the model route. The Anthropic route uses the generated model client key, not HOLMES_TOKEN. See section 5 and reapply the routes.

### Helm upgrade times out or Holmes pods cannot start

Check pod events and available memory:

```bash
kubectl get pods -n holmes -o wide
kubectl get events -n holmes --sort-by=.lastTimestamp
```

A runAsNonRoot error means the updated values were not applied. Insufficient memory on kind requires reducing other workloads or increasing Docker Desktop memory.

### Calico reports MutatingAdmissionPolicy API unavailable

Use the supplied kind configuration and Calico install script. The kind config enables the Kubernetes 1.35 MutatingAdmissionPolicy feature gate required by Calico 3.33.
