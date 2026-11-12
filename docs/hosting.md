# Hosting choices

Pick one host. The server and SQL permissions do not change between them.

## Azure Container Apps: simplest managed option

Use the [README deployment button](../README.md). The compiled ARM template and guided installer use the same Bicep source. Public Microsoft DAB and Docker Official Caddy images are digest-pinned; configuration is mounted, not baked into a custom image.

ACA terminates public HTTPS on port 443, forwards to the gateway on 8080, and DAB listens only on `127.0.0.1:5000` inside the replica. The gateway checks `X-API-Key` and strips inbound authorization/role headers. It exposes no REST/GraphQL endpoint.

No automatic SQL login/grant, VNet peering, DNS link, firewall change, or Entra application consent is performed. A new environment needs a dedicated, correctly sized subnet delegated to `Microsoft.App/environments` for private connectivity. Use an existing approved environment to minimize infrastructure work. Select its actual region. Monitoring destination is Azure Monitor; configure diagnostic settings and retention to suit your policy.

The initial DAB process can fail until the DBA has created the reader and objects. This is expected, not success. After DBA setup, wait for a ready revision and run the protocol check. Review `az containerapp logs show` and system logs if it does not recover. Do not broaden permissions merely to obtain a green status.

## Existing AKS or Kubernetes

Run `Install.ps1 -Hosting Kubernetes`. It generates one protected `.local/kubernetes.json` containing:

- Dedicated namespace/service account, ConfigMap, Secret and a one-replica Deployment.
- Two containers sharing the pod network, with DAB loopback-only.
- ClusterIP service exposing only gateway port 8080.
- `/mcp` ingress using your existing ingress class and TLS secret.

Review the file. Arrange DNS, ingress controller and a valid TLS certificate in namespace `sql-mcp`. Run the DBA script, then apply the generated file with `kubectl apply -f .local/kubernetes.json`. A certificate Secret must exist before ingress can be used. No cert-manager, ingress controller, load balancer or cluster is installed.

**Do not disable TLS validation.** Configure your ingress controller to serve HTTPS only, redirect or reject HTTP, and avoid buffering MCP streaming responses. Set its request/idle timeouts for your operational needs. Ensure its default backend cannot expose DAB.

For AKS managed identity, enable OIDC and workload identity and create a federated identity credential with subject `system:serviceaccount:sql-mcp:sql-mcp` and audience `api://AzureADTokenExchange`. Pass `-WorkloadIdentityClientId '<identity-client-id>'` to the installer and supply a supported SqlClient workload-identity connection string at the secure prompt. This is advanced customer configuration, not automatically installed or certified by this starter. A VM's IMDS authentication string is not an AKS workload-identity configuration.

The generated Secret and `.local` manifest contain plaintext-equivalent credentials. Use your existing external-secrets/Key Vault CSI integration in production. Review Kubernetes RBAC, etcd encryption and NetworkPolicies. The package does not change cluster-wide policies.

For approved unattended generation, `New-Kubernetes.ps1` also accepts `-ConnectionStringFile` pointing to an access-restricted file. Pass a file path, never a secret on the command line.

## Docker Compose / Linux VM

Run `Install.ps1 -Hosting Docker`. It writes protected `.local` environment files and prepares the DBA script. After SQL authorization, start from the repository root:

```powershell
docker compose --env-file .local/images.env up -d
```

Docker Compose **2.30+** is needed for raw env-file values, preserving `$`, quotes and semicolons in credentials. DAB owns the network namespace; Caddy joins it. The only published port is **127.0.0.1:8080**. Port 5000 is never published.

Use an existing host-level HTTPS reverse proxy with a publicly trusted certificate. Forward `/mcp` and its subpaths unchanged to `http://127.0.0.1:8080`, preserving `X-API-Key`, streaming responses and MCP session headers. Do not point SRE Agent at localhost, expose Docker port 5000, or publish port 8080 to all interfaces.

For an Azure VM managed identity, assign the intended identity to the VM and use a supported SQL managed-identity connection string. Otherwise use a dedicated SQL reader login, not a DBA login. VM certificate trust/private CA, OS patching, backups, logs, restart policy and secret rotation remain your responsibility.

## What about App Service or on-premises?

The same containers can be hosted elsewhere, but multi-container loopback networking, ingress/authentication and persistent MCP sessions must be configured and tested on that platform. This release intentionally does not advertise an untested App Service deployment button. Docker on existing Linux infrastructure is the portable alternative.

Private SQL does not require public SQL exposure: only the MCP host needs SQL connectivity. A private **MCP** endpoint is a separate choice and needs a verified SRE Agent network path. Remote OAuth in SRE Agent has additional public-HTTPS requirements; see Microsoft's connector documentation.
