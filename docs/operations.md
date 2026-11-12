# Operations

## Secrets and HTTPS

ACA stores the API key and SQL connection as platform secrets and takes sensitive inputs as secure ARM parameters. Secure parameters are not deployment outputs. This starter does not create a Key Vault; use your approved vault and secret-reference policy for production if required.

The installer restricts `.local` to the current OS user (and SYSTEM on Windows). SQL credentials remain plaintext-equivalent in generated runtime/Kubernetes files. Docker-group administrators, Kubernetes secret readers and Azure operators with secret access can read them. Do not upload `.local`, include it in support bundles, or grant untrusted users host access.

Use 32-128 random URL-safe characters for the API key. Caddy substitutes environment values into its configuration, so arbitrary whitespace or config syntax is intentionally rejected by the installer and deployment UI. Direct ARM callers must maintain the same invariant.

To rotate: arrange a maintenance window, update the host secret and restart/reload the gateway so the environment substitution uses the new value; update the SRE connector header; rerun the verifier. Current setup uses one active key, not seamless dual-key rotation. Rotate a SQL password separately and update its host secret.

Never expose the unauthenticated DAB listener. In ACA/pods it binds loopback; Docker containers share one namespace, with only gateway loopback port 8080 published. Only authenticated `/mcp` routes proxy requests. `/health` is a coarse anonymous backend-health response, not a readiness/permissions certification.

## Updates and availability

Images are digest-pinned in `config/images.json`; Docker Compose and Kubernetes generation read that file, and Bicep embeds it. For an update, review release notes, change the digest, rebuild `infra/azuredeploy.json`, run package checks, and repeat integration tests. Never use `latest` as an automatic upgrade.

The deployment uses one replica because MCP sessions are process-local. Do not increase replicas without validating session routing and reconnection. There can be interruptions during restarts; SRE Agent may reconnect, but do not assume an investigation snapshot survives.

Enable the host's normal monitoring/retention and set budgets. ACA continuously runs a small replica; it is not free merely because the database is idle. New environments/subnets, private networking, DNS, public IPs, logs and VM/cluster resources can add costs.

## What is and is not automated

The package provisions hosting/configuration and generates a DBA script. It does not execute SQL as an administrator, change SQL firewall settings, create a private endpoint, configure organizational DNS/routing, install AKS ingress, issue VM certificates, or automatically modify SRE Agent.

The ARM template intentionally has no SQL startup readiness probe: initial DAB startup can fail before the DBA handoff. A completed deployment is **host deployed**, never **SQL verified**. After DBA setup, check the active/ready revision and run the protocol verifier. Configure your production alerting and startup/readiness policy after the identity and SQL objects exist.

Keep historical telemetry: Azure Monitor, application dependency traces, Query Store and approved Extended Events. Live DMV observations are neither durable history nor an atomic snapshot. A blocking chain can disappear between tool calls; never issue automatic KILL based on stale evidence.

## Local validation commands

PowerShell 7.2+, Python 3 (standard library only), and Azure CLI/Bicep:

```powershell
az bicep build --file infra/main.bicep --outfile infra/azuredeploy.json
python -m unittest discover -s tests -p "test_*.py"
```

Tests check template/config consistency, PowerShell parsing/generation, and the verifier against a local protocol fixture, including rejection cases. Fixtures do not replace a real SQL/ACA/connector integration test. [Validation status](validation.md).
