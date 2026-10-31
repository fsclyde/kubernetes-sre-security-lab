# Architecture and threat model

## Assets to protect

- The Kubernetes cluster and workloads outside the `demo` namespace.
- Kubernetes Secrets, GitHub credentials, and the Anthropic API key.
- The integrity of the demo manifests and the repair applied by the operator.
- Keycloak tokens, model availability, and audit records.

## Trust boundaries

1. A user asks HolmesGPT to investigate an incident.
2. HolmesGPT and the operator are separate Keycloak clients and receive separate short-lived tokens for each API request.
3. Holmes forwards the request's Keycloak token only to the MCP servers; agentgateway validates it and authorizes MCP calls by client identity and tool.
4. Holmes and the operator use separate client keys for model requests. agentgateway validates those keys and uses its stored Anthropic provider key.
5. The Kubernetes MCP servers use separate identities and RoleBindings.
6. Kubernetes events, pod logs, and GitHub content are untrusted inputs. Prompt filtering should redact secrets without removing data needed for the investigation.

## Threats and controls

| Threat | Planned control | Enforcement point |
| --- | --- | --- |
| An unauthenticated caller invokes a tool | Require Keycloak token; validate signature, issuer, and authorized client | agentgateway MCP-route policies |
| An unauthenticated caller invokes the model | Require a per-agent Gateway model key; keep the Anthropic provider key in a Gateway Secret | agentgateway Anthropic-route policy and backend |
| Expired or revoked token is reused | Short token lifetime; disable client; rotate JWKS keys | Keycloak and agentgateway |
| Agent acts outside its role | Authorize tools by `k8s-read`, `k8s-write`, and `github-read` roles | agentgateway |
| Prompt injection in a GitHub issue | Holmes has read-only tools; Kubernetes RBAC is read-only | Gateway and Kubernetes |
| Anthropic or GitHub credential leaks | Credentials stay with gateway/backend and are never sent to Holmes | Gateway |
| Secret is included in a prompt from a log | Redact known keys and tokens before forwarding to the model | Gateway |
| Agent loops or consumes excessive quota | Per-identity quota and rate limit using `jwt.azp` | Gateway |
| Holmes bypasses the gateway to access the cluster | Disable Holmes built-in Kubernetes tools; allow MCP route only; scope RBAC to namespace | Holmes, network, and Kubernetes |
| Direct access to `/api/chat` | Allow ingress only from authenticated route or operator namespace | NetworkPolicy / gateway |
| Actions cannot be attributed | Log `azp`, tool, decision, and denial reason; enable Kubernetes audit | Gateway, Keycloak, Kubernetes |

## Roles and permissions

| Identity | Exposed MCP tools | Kubernetes permissions |
| --- | --- | --- |
| `holmes` | `k8s-read`, `github-read` | Read selected workloads and events in `demo`; no Secrets or writes |
| `operator` | `k8s-read`, `k8s-write`, `github-read` | Same read access; `get/list/watch/patch/update` Deployments in `demo` |

The read and write MCP servers use separate ServiceAccounts in `mcp`. RoleBindings in `demo` grant only the required permissions. The proposed manifests are in [`../manifests/rbac/demo-roles.yaml`](../manifests/rbac/demo-roles.yaml).

## Component hardening

### HolmesGPT

- Keep only the required MCP tools; disable its built-in Kubernetes toolsets and Bash.
- Use a ServiceAccount with no useful permissions and prevent its token from being mounted.
- Apply the Kubernetes `restricted` pod security profile: non-root, read-only filesystem, drop capabilities, `seccompProfile: RuntimeDefault`, and no privilege escalation.
- Limit egress to the identity sidecar; the sidecar can reach only Keycloak, agentgateway, and DNS.
- Restrict access to `/api/chat`.

The sample values are in [`../manifests/holmes/values.yaml`](../manifests/holmes/values.yaml) and [`../manifests/operator/values.yaml`](../manifests/operator/values.yaml). Review the chart's rendered configuration when upgrading the pinned chart.

### agentgateway and Keycloak

- Configure separate Keycloak clients (`holmes`, `operator`), dedicated roles, a named owner, and short-lived tokens.
- Forward each caller's Keycloak token from Holmes to MCP routes using request-context header propagation.
- Use separate Gateway model client keys for Holmes and operator; keep the Anthropic provider key in the Gateway namespace.
- Validate tokens using Keycloak JWKS; generate secrets at startup and never commit them.
- Authorize each tool route by role, apply per-identity quotas, and log denials.
- Scope the GitHub token to the demo repository with read-only permissions. The gateway injects backend credentials without exposing them to agents.

### Kubernetes MCP servers

- Deploy the MCP servers separately from the Holmes chart so all tool traffic passes through agentgateway.
- `k8s-mcp-read` exposes read-only tools and uses the `k8s-mcp-read` ServiceAccount.
- `k8s-mcp-write` exposes only the operations needed by the operator and uses `k8s-mcp-write`.
- Disable cluster-configuration tools and explicitly set the toolsets.
- In the baseline, each server uses its own ServiceAccount. Passing agent tokens through to Kubernetes is a separate advanced mode.

### Observability

- **agentgateway logs:** Keycloak identity, requested tool, decision, and denial reason.
- **Kubernetes audit:** accepted or denied API calls by identity and resource. Record Secret access at Metadata level only; exclude sensitive request bodies from audit records.
- **Falco:** consumes Kubernetes audit events and alerts on writes by the read-only account, Secret access, `exec`, and access outside `demo`.
- **Tetragon:** adds visibility into processes and network connections initiated by agent pods.

Falco and Tetragon provide complementary views. Neither replaces Kubernetes RBAC or agentgateway logs.

## Advanced step: end-to-end agent identity

In passthrough mode, an MCP server can forward the inbound token to the Kubernetes API. For Kubernetes audit records to show `holmes` and `operator` instead of the MCP ServiceAccounts, the `kind` API server must accept Keycloak tokens through OIDC, with a reachable HTTPS issuer, matching issuer/audience, and RBAC group mapping. This step is optional and separate from the baseline, where the two MCP servers use distinct ServiceAccounts.
