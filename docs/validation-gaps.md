# Known validation gaps

The configuration is prepared, but these behaviors still need confirmation in a full local run. Match checks to the pinned chart, image, and Gateway versions.

- **End-to-end requests:** verify Holmes model calls and MCP tool discovery/calls through agentgateway. Model checks use Anthropic API credits.
- **Holmes configuration:** confirm chart rendering, MCP server definitions, and forwarding of each caller's Keycloak token.
- **Kubernetes MCP:** verify chart/image versions, service labels and ports, tool names, read-only mode, and separate ServiceAccounts/RBAC.
- **GitHub MCP:** verify GitHub MCP v2.0.2 honors the injected token and `X-MCP-Readonly` header. HTTPS egress currently allows public IPs broadly because Kubernetes NetworkPolicy has no domain matching.
- **NetworkPolicy:** confirm the selected CNI enforces the supplied policies and permits only required DNS, Gateway, API, and GitHub MCP paths.
- **Calico / Kubernetes 1.35:** verify the configured MutatingAdmissionPolicy feature gate and API support before installing Calico 3.33.
- **Falco runtime coverage:** verify the custom rule records syscall events for Holmes, operator, MCP, and Gateway pods; watch for event drops and resource pressure. Falco does not provide a complete semantic record of every agent action.
- **Identity lifecycle:** measure token rejection after client disablement and behavior during JWKS refresh/rotation; do not assume a revocation bound.
- **Secret redaction:** no prompt-redaction policy is included yet. Do not claim model-bound secrets are filtered.
- **Audit identity:** baseline Kubernetes audit entries identify the MCP ServiceAccounts. Direct Holmes/operator attribution requires the optional OIDC configuration.

## References

- [Kubernetes MCP Server configuration](https://github.com/containers/kubernetes-mcp-server/blob/main/docs/configuration.md)
- [Agentgateway JWT with Keycloak](https://agentgateway.dev/docs/kubernetes/latest/documentation/security/jwt/setup/) and [standalone Keycloak integration](https://agentgateway.dev/docs/standalone/latest/integrations/auth/keycloak/)
- [HolmesGPT remote MCP servers](https://holmesgpt.dev/dev/data-sources/remote-mcp-servers/), [header propagation](https://holmesgpt.dev/0.22.0/data-sources/header-propagation/), and [Helm configuration](https://holmesgpt.dev/latest/reference/helm-configuration/)
- [Agentgateway provider API keys](https://agentgateway.dev/docs/kubernetes/latest/documentation/llm/api-keys/) and [API-key authentication](https://agentgateway.dev/docs/kubernetes/latest/documentation/security/apikey/)

Always check the references against the versions pinned in this lab.