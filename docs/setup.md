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
- [9. Clean up](#9-clean-up)
- [10. Troubleshooting](#10-troubleshooting)

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

### Investigation and repair test

Keep the Keycloak, Holmes (`5050`), and operator (`5051`) port-forwards running. This test changes the demo Deployment and uses Anthropic API credits. Start from a healthy deployment.

Trigger a failed rollout:

```bash
kubectl set image deployment/demo-web web=nginx:does-not-exist-lab -n demo
kubectl rollout status deployment/demo-web -n demo --timeout=60s || true
kubectl get deployment,pods -n demo
```

Mint a fresh Holmes token and ask it to investigate. The request names the GitHub repository so Holmes can check its commits.

```bash
source .local/lab-secrets.env

HOLMES_TOKEN="$(curl --fail --silent --show-error \
  --connect-to keycloak.identity.svc.cluster.local:8080:127.0.0.1:8081 \
  --user "holmes:$HOLMES_CLIENT_SECRET" \
  --data-urlencode grant_type=client_credentials \
  http://keycloak.identity.svc.cluster.local:8080/realms/sre-lab/protocol/openid-connect/token \
  | jq -er '.access_token')"

curl --fail-with-body --silent --show-error \
  http://localhost:5050/api/chat \
  -H "Authorization: Bearer $HOLMES_TOKEN" \
  -H 'Content-Type: application/json' \
  --data '{"ask":"Investigate demo-web in namespace demo. Read its Deployment, pods, events, logs, and recent GitHub commits in fsclyde/kubernetes-sre-security-lab. Identify the likely cause and recommend a fix. Do not change anything. Keep the answer to 5 concise bullets max: cause, key evidence, and recommended fix. Skip the investigation narration. If a tool fails, name the failing tool and exact error in one sentence.","model":"claude-sonnet"}' \
| jq -r '.analysis // .response // .detail // .'
```

Review Holmes's findings. It should identify the invalid image and recommend `nginx:1.27.5-alpine`; Holmes must not make changes. Then mint a separate operator token and ask the operator to apply that reviewed fix:

```bash
OPERATOR_TOKEN="$(curl --fail --silent --show-error \
  --connect-to keycloak.identity.svc.cluster.local:8080:127.0.0.1:8081 \
  --user "operator:$OPERATOR_CLIENT_SECRET" \
  --data-urlencode grant_type=client_credentials \
  http://keycloak.identity.svc.cluster.local:8080/realms/sre-lab/protocol/openid-connect/token \
  | jq -er '.access_token')"

curl --fail-with-body --silent --show-error \
  http://localhost:5051/api/chat \
  -H "Authorization: Bearer $OPERATOR_TOKEN" \
  -H 'Content-Type: application/json' \
  --data '{"ask":"Repair demo-web in namespace demo. Read its current Deployment, then change only the web container image to nginx:1.27.5-alpine. Report the change and do not modify any other resource.","model":"claude-sonnet"}' \
| jq -r '.analysis // .response // .detail // .'
```

Check that the Deployment recovered:

```bash
kubectl rollout status deployment/demo-web -n demo --timeout=3m
kubectl get deployment demo-web -n demo \
  -o jsonpath='{.spec.template.spec.containers[0].image}{"\\n"}'
```

The image should be `nginx:1.27.5-alpine`.

### Verify Gateway traffic and agent egress

agentgateway writes a structured access log for each request it processes. After the test, inspect MCP and model routes:

```bash
kubectl logs -n agentgateway-system deployment/agentgateway-proxy --since=30m \
| grep -E 'http.path=/mcp|http.path=/v1/messages'
```

Look for the request path, status, `jwt.sub`, `mcp.method.name=tools/call`, and tool name. The request to Holmes's local `/api/chat` endpoint itself does not pass through agentgateway; Holmes's model and MCP calls should.

Check that NetworkPolicies prevent Holmes from bypassing the Gateway to reach the Kubernetes API or external model/GitHub endpoints:

```bash
for ns in holmes operator; do
  pod="$(kubectl get pods -n "$ns" -l app=holmes -o jsonpath='{.items[0].metadata.name}')"
  kubectl exec -n "$ns" "$pod" -- python -c '
import socket
for host, port in [("kubernetes.default.svc.cluster.local", 443), ("api.anthropic.com", 443), ("api.github.com", 443)]:
    try:
        conn = socket.create_connection((host, port), 3)
        conn.close()
        print("UNEXPECTED direct connection:", host)
    except OSError:
        print("Blocked:", host)
'
done
```

All three direct connections should be blocked from both agent namespaces. The Kubernetes MCP servers connect to the API using their own ServiceAccounts after agentgateway authorizes the MCP calls.

Inspect the matching Kubernetes API activity. These audit records identify the MCP ServiceAccount and operation; correlate their timestamps with Gateway tool-call logs:

```bash
jq -r 'select(.user.username | startswith("system:serviceaccount:mcp:")) | [.requestReceivedTimestamp, .user.username, .verb, .objectRef.namespace, .objectRef.resource, .objectRef.name, .responseStatus.code] | @tsv' \
  .local/k8s-audit/audit.log
```

Use the API audit query above for a record of Kubernetes API requests; Gateway logs cover MCP/model requests.

The primary security boundaries are:

| Mechanism | Enforced boundary |
| --- | --- |
| Keycloak JWT + Gateway policies | Separates Holmes and operator identities; only operator can use the write route |
| MCP backend policies | Limits GitHub tools and protects Kubernetes MCP routes |
| Kubernetes RBAC | Restricts operator writes to Deployments in demo; Holmes is read-only |
| Calico NetworkPolicy | Default-denies pod traffic and allows required paths only |
| Pod Security restricted | Runs Holmes and operator without root, privilege escalation, or extra capabilities |
| Kubernetes audit policy | Records API activity for review in .local/k8s-audit/audit.log |

## 9. Clean up

```bash
kind delete cluster --name agent-security-lab
```

This leaves .local files, including credentials and audit logs. Remove .local manually when they are no longer needed.

## 10. Troubleshooting

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

### Kubernetes MCP calls time out

If MCP initialization succeeds but `tools/call` returns HTTP 500 with `upstream call timeout`, inspect the API endpoint, MCP logs, and write ServiceAccount permission:

```bash
kubectl get svc kubernetes -n default -o wide
kubectl get endpointslice -n default \
  -l kubernetes.io/service-name=kubernetes -o wide
kubectl logs -n mcp deployment/k8s-mcp-write --since=10m
kubectl auth can-i get deployments -n demo \
  --as=system:serviceaccount:mcp:k8s-mcp-write
```

If the MCP logs show API discovery timeouts and the RBAC check returns `yes`, egress to the API is blocked. The Service ClusterIP and its endpoint can use different addresses and ports (for example, `10.96.0.1:443` may route to `172.19.0.3:6443`). The lab's Calico policy matches the `default/kubernetes` Service so it follows the actual endpoint. Apply the updated policy:

```bash
kubectl apply -f manifests/networking/policies.yaml
```

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
