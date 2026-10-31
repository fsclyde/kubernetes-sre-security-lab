# Known gaps

## What I confirmed on my laptop

- HolmesGPT investigates through the gateway and cannot change anything.
- Only the operator can apply a fix, and only to Deployments in `demo`.
- Calls without a valid token are refused.
- The agent pods cannot reach the Kubernetes API, Anthropic or GitHub directly.

## What still needs work

- **Switching off an agent:** when I disable an agent in Keycloak, its current token may keep working for a few minutes until it expires. I still need to measure how long.
- **Secrets sent to the model:** nothing filters secrets out of prompts yet. If a secret shows up in a pod log, the model can see it.
- **Who did what in Kubernetes:** the Kubernetes audit log shows the tool server's account, not which agent asked. Linking the two needs an extra identity setup.
- **GitHub traffic:** Kubernetes network policies can't limit traffic by website name, so the GitHub tool server can reach any public address on HTTPS.
- **Runtime logs:** recording what runs inside the pods is useful but not complete, and it can produce a lot of data.

If something doesn't work for you, check that you're using the versions pinned in the [setup guide](setup.md).
