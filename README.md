# Connect Azure SRE Agent to SQL

Give your agent **read-only live SQL diagnostics**: requests, waits, sessions, transactions and locks. Runs Microsoft's SQL MCP Server (Data API builder), not a custom SQL execution server.

**Three steps: deploy a host, authorize one database, connect SRE Agent.** Existing Azure SQL Database and SQL Server 2019+ on Azure VMs are supported targets. SQL Managed Instance is not included.

> Community starter, not a Microsoft product deployment. Infrastructure deployment is not proof of SQL readiness. See [validation status](docs/validation.md) before production use.

## 1. Choose where to host

| Hosting | Choose this when | You provide |
|---|---|---|
| **Azure Container Apps (recommended)** | You want managed hosting and HTTPS with the fewest setup steps | An approved SQL network path |
| **Existing AKS / Kubernetes** | Your team already operates Kubernetes | Ingress controller, HTTPS certificate, DNS, SQL network path and identity/secret management |
| **Docker Compose on a Linux VM** | You prefer a VM or existing Docker infrastructure | Docker Compose 2.30+, HTTPS reverse proxy, DNS, SQL network path and identity/secret management |

Same diagnostic contract and pinned public images on every host. No customer ACR, image builds, Python, or DAB installation. Kubernetes and VM hosting involve more customer-operated infrastructure; they are not one-click equivalents to ACA. [Hosting details](docs/hosting.md).

### Container Apps: click to deploy

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fpuneetg1983%2Fsql-mcp-sre-starter%2Fv0.1.0%2Finfra%2Fazuredeploy.json/createUIDefinitionUri/https%3A%2F%2Fraw.githubusercontent.com%2Fpuneetg1983%2Fsql-mcp-sre-starter%2Fv0.1.0%2Finfra%2FcreateUiDefinition.json)

Select your subscription, resource group and region. Supply the SQL hostname/database, authentication choice, and a random **32-128 character API key** saved in your password manager.

**Private SQL:** select an existing SQL-connected Container Apps environment, or supply an approved dedicated subnet delegated to `Microsoft.App/environments`. The template does not alter your SQL firewall, DNS, routing, or existing subnets. Without either network option, only an already-approved public SQL path will work. Do not enable "allow all Azure services" to bypass this.

Use **managed identity** for Azure SQL. For a SQL VM, use a dedicated SQL reader login unless SQL Server 2022+ Entra authentication is already configured. Never supply SQL administrator credentials. Managed identity for SQL and the API key used by SRE Agent are separate.

After deployment, open **Outputs** and save `endpoint` and `readerName`. With SQL-login authentication, use your supplied login name instead of `readerName`.

### Prefer a guided command, or another host?

Clone the repository at release **v0.1.0**, review its scripts, then run in PowerShell 7.2+:

```powershell
git clone --branch v0.1.0 https://github.com/puneetg1983/sql-mcp-sre-starter.git
cd sql-mcp-sre-starter
pwsh ./scripts/Install.ps1
```

Choose **ACA**, **Kubernetes**, or **Docker**. ACA requires Azure CLI signed into the intended subscription (`az login`). The installer deploys ACA or generates the Kubernetes/Compose files; it never silently applies a Kubernetes manifest or starts a VM workload. It prints the exact next action.

Secrets are kept out of command arguments and console output. Generated files live in access-restricted, git-ignored `.local`; some contain plaintext credentials. Protect them, do not upload them, and remove them when no longer needed.

## 2. Authorize the database, then verify

The guided installer generates **`.local/setup.sql`**. For a portal deployment, clone the repo and generate it using the deployment output:

```powershell
pwsh ./scripts/New-DatabaseSetup.ps1 -Database Orders -ReaderName '<readerName>'
```

For SQL-login authentication, add `-SqlAuthentication sql-login` and use the pre-provisioned dedicated login name. Have your DBA review and run the generated script **in the target database**, using SSMS or another approved SQL client. The script installs diagnostic objects and narrow object grants; it does not change application tables or execute workload transactions.

SQL VM setup additionally requires instance-level diagnostic grants. Azure SQL visibility varies by service tier. Neither database ownership nor administrator credentials are acceptable workarounds. [DBA permissions and visibility check](docs/permissions.md).

After the host has started, verify it:

```powershell
pwsh ./scripts/Test-Mcp.ps1 -Endpoint 'https://<host>/mcp' -Database Orders -ReaderName '<readerName>'
```

For a portal deployment, enter the API key at the hidden prompt. For an installer deployment, omit the arguments to use the protected local handoff. The check rejects missing/wrong keys, verifies the tool/entity allow-lists, reads all diagnostic objects, and checks runtime identity and selected privileges. It does **not** create an order or deliberately block SQL.

An empty requests list is normal on an idle database, but **not proof that other sessions are visible**. Complete the [independent session check](docs/permissions.md#prove-cross-session-visibility) before relying on blocking diagnostics.

## 3. Connect SRE Agent

In [Azure SRE Agent](https://sre.azure.com), open **Build + setup > Extensions > Connectors > Add MCP server**:

| Field | Value |
|---|---|
| Transport | **Streamable-HTTP** |
| URL | The full deployment `endpoint`, ending in `/mcp` |
| Authentication | Custom header **`X-API-Key`**, using your saved API key |
| Tools | `describe_entities`, `read_records`, `execute_entity` |

If the UI separates authentication and headers, select **No authentication** and add the header; the gateway still enforces the key. Save, wait for **Connected**, select the tools, then start a new chat:

> Use my SQL diagnostics connector. Read ConnectionInfo and confirm the database and reader identity. Inspect current requests, sessions, transactions and locks. Explain any blocking chain with session IDs and observation times. Do not modify SQL. Say when evidence or visibility is insufficient.

[Connection fields and troubleshooting](docs/connect-sre-agent.md).

## What this does not do

This is live evidence, not incident history. Keep Azure Monitor, application telemetry and Query Store. The reader has no intended business-table access, writes, arbitrary-SQL tool or session-termination capability. Diagnostics are still sensitive; review inherited grants and your organization's policies.

The API key is a shared credential, not per-user authorization. HTTPS is mandatory off-machine. Use your existing secret-management/rotation process. One replica avoids process-local MCP session routing issues. ACA compute, monitoring and any new networking resources incur Azure charges.

## More detail

[Hosting](docs/hosting.md) | [DBA permissions](docs/permissions.md) | [SRE connection](docs/connect-sre-agent.md) | [Operations](docs/operations.md) | [Advanced original guide](docs/advanced-reference.md) | [Validation](docs/validation.md)

## Remove the starter

Remove only the dedicated resources you deployed after reviewing their scope. Do not delete a shared resource group, network or Container Apps environment. Stop Compose with `docker compose --env-file .local/images.env down`, or remove only the generated Kubernetes resources after reviewing the manifest. Have the DBA review removal of `sre_sql` objects and the dedicated reader; this package never drops the workload database.
