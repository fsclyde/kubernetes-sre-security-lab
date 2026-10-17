# Technical items to validate before calling this lab runnable

This document separates documented component features from behavior that still depends on exact versions or the local environment. Deployment images, charts, settings, and commands should be pinned in the repository with the final manifests.

| Topic | What to verify | Why it matters |
| --- | --- | --- |
| HolmesGPT / agentgateway | HolmesGPT accepts a custom Anthropic endpoint (`api_base`) and routes all model calls through agentgateway | Confirm provider, proxy, and identity-sidecar configuration for the pinned versions |
| HolmesGPT | Actual default toolsets; disable built-in Kubernetes and Bash; prevent ServiceAccount token mounting; chart value names | Avoid direct Kubernetes access and avoid inventing Helm keys |
| Kubernetes MCP Server | Version and chart; `read_only`, `disabled_tools`, toolsets, and authentication mode | Upstream documentation describes these controls; confirm the pinned chart schema and actual tool names |
| Baseline identity | Each MCP server uses its own ServiceAccount, one read-only and one write-enabled | Confirm the ServiceAccount token mount and absence of cluster-wide access |
| GitHub header | agentgateway v1.6.0 injects the token and enforces read-only behavior on the MCP backend route | Ensure the client cannot override the header or reach GitHub directly |
| `kind` and NetworkPolicy | The selected cluster CNI enforces policies while allowing required DNS and egress | Install/configure a compatible CNI if the local cluster does not enforce policies |
| Falco audit | `kind` audit configuration, file/webhook delivery, and safe capture level for Secrets | Use `Metadata` for Secret access and avoid storing sensitive request bodies |
| Tetragon on Docker Desktop | Host-kernel eBPF support with the local Docker Desktop and `kind` node setup | If unavailable, keep Falco/audit in the baseline and make Tetragon optional or use native Linux |
| Revocation and JWKS | Token rejection delay after client disablement and key-cache/rotation behavior | Do not promise a five-minute bound until the gateway behavior is verified |
| Redaction | Mask secrets in model-bound content without breaking the investigation | Define fake values and inspect the body received by a test backend |
| Kubernetes audit | `kind` audit configuration and identity correlation | Baseline attributes actions to the two MCP ServiceAccounts; direct agent identity requires advanced OIDC |

## Reference documentation

- [Kubernetes MCP Server configuration](https://github.com/containers/kubernetes-mcp-server/blob/main/docs/configuration.md): `read_only`, `disabled_tools`, toolsets, OAuth, and `cluster_auth_mode`.
- [JWT with Keycloak in agentgateway](https://agentgateway.dev/docs/kubernetes/latest/documentation/security/jwt/setup/) and [standalone Keycloak integration](https://agentgateway.dev/docs/standalone/latest/integrations/auth/keycloak/).
- [HolmesGPT configuration](https://docs.holmesgpt.dev/).

HolmesGPT and agentgateway links refer to their current documentation. Final examples must match the exact versions pinned by this lab.
