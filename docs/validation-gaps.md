# Technical items to validate before calling this lab runnable

This document separates documented component features from behavior that still depends on exact versions or the local environment. Deployment images, charts, settings, and commands should be pinned in the repository with the final manifests.

| Topic | What to verify | Why it matters |
| --- | --- | --- |
| HolmesGPT / agentgateway | Rendered chart model configuration and an Anthropic request through the Gateway | Values configure a named Claude model and separate model client keys; verify the exact chart/model behavior with a real local request (this incurs model usage) |
| HolmesGPT | Rendered MCP configuration and request-context header forwarding with the deployed chart/image | Values forward each caller's short-lived Keycloak token to MCP routes; verify initial tool discovery and real MCP calls in the local cluster |
| Kubernetes MCP Server | Chart `0.1.0`, image `v0.0.67`, `read_only`, toolsets, service labels, and tool names | Verify rendered labels, service ports, `appProtocol`, and configured tool names against the chart in the local cluster |
| Baseline identity | Each MCP server uses its own ServiceAccount, one read-only and one write-enabled | Confirm the ServiceAccount token mount and absence of cluster-wide access |
| GitHub header | agentgateway v1.6.0 injects the token and `X-MCP-Readonly` header on the MCP backend | Confirm GitHub MCP v2.0.2 header handling; egress currently permits TCP 443 to any public IP because Kubernetes NetworkPolicy has no DNS-name match |
| `kind` and NetworkPolicy | The selected cluster CNI enforces policies while allowing required DNS and egress | Install/configure a compatible CNI if the local cluster does not enforce policies |
| Calico on Kubernetes 1.35 | `MutatingAdmissionPolicy` feature gate and `admissionregistration.k8s.io/v1beta1` API availability | The kind API server must enable both before applying Calico 3.33 native CRDs; configured in `kind/cluster.yaml` |
| Falco audit | `kind` audit webhook delivery and Falco k8saudit plugin configuration | Current `kind` config writes audit records to a host-mounted file; Falco does not yet consume that file or receive webhook events. Secret records remain Metadata-only |
| Tetragon on Docker Desktop | Host-kernel eBPF support with the local Docker Desktop and `kind` node setup | If unavailable, keep Falco/audit in the baseline and make Tetragon optional or use native Linux |
| Revocation and JWKS | Token rejection delay after client disablement and key-cache/rotation behavior | Do not promise a five-minute bound until the gateway behavior is verified |
| Redaction | Mask secrets in model-bound content without breaking the investigation | No prompt-redaction policy is included yet; inspect the body received by a test backend before claiming coverage |
| Kubernetes audit | `kind` audit configuration and identity correlation | Baseline attributes actions to the two MCP ServiceAccounts; direct agent identity requires advanced OIDC |

## Reference documentation

- [Kubernetes MCP Server configuration](https://github.com/containers/kubernetes-mcp-server/blob/main/docs/configuration.md): `read_only`, `disabled_tools`, toolsets, OAuth, and `cluster_auth_mode`.
- [JWT with Keycloak in agentgateway](https://agentgateway.dev/docs/kubernetes/latest/documentation/security/jwt/setup/) and [standalone Keycloak integration](https://agentgateway.dev/docs/standalone/latest/integrations/auth/keycloak/).
- [HolmesGPT MCP servers](https://holmesgpt.dev/dev/data-sources/remote-mcp-servers/), [header propagation](https://holmesgpt.dev/0.22.0/data-sources/header-propagation/), and [Helm model configuration](https://holmesgpt.dev/latest/reference/helm-configuration/).
- [Agentgateway provider API keys](https://agentgateway.dev/docs/kubernetes/latest/documentation/llm/api-keys/) and [API-key authentication](https://agentgateway.dev/docs/kubernetes/latest/documentation/security/apikey/).
- [HolmesGPT configuration](https://docs.holmesgpt.dev/).

HolmesGPT and agentgateway links refer to their current documentation. Final examples must match the exact versions pinned by this lab.
