# Connect Azure SRE Agent to SQL in three steps

Your application is timing out. Database CPU looks normal. Is SQL waiting on a lock, or is a sleeping session holding an open transaction?

Azure metrics help explain resource pressure, but not every live database question. **Microsoft's SQL MCP Server, included in Data API builder, gives Azure SRE Agent a controlled way to read current SQL evidence.** It complements Azure Monitor, application telemetry and Query Store; it does not replace them.

You should not need to write a server, build a container image or follow pages of deployment commands. This [open-source starter](https://github.com/puneetg1983/sql-mcp-sre-starter) packages the configuration and deployment steps.

**The customer workflow is: deploy to Azure Container Apps, authorize one database, connect SRE Agent.** This guide uses **Azure Container Apps (recommended)** as the only hosting path and covers Azure SQL Database and SQL Server 2019+ on Azure VMs. Managed Instance is outside this starter's scope.

> This is a community starter, not a Microsoft product deployment. Review its [validation status](https://github.com/puneetg1983/sql-mcp-sre-starter/blob/v0.1.1/docs/validation.md) before production use. SQL permissions and private-network approval remain administrator decisions; no button can safely skip them.

## Under the hood: SQL MCP and Data API builder

We use **Microsoft's SQL MCP Server, built into [Data API builder (DAB)](https://learn.microsoft.com/azure/data-api-builder/mcp/overview)**, not a custom MCP implementation. DAB is an open-source engine that exposes configured database objects as APIs and MCP tools.

The template starts two containers in one Container App:

- **DAB:** runs Microsoft's prebuilt image with a mounted `dab-config.json`. That file enables `/mcp`, connects to your SQL database, and exposes only four diagnostic views and the read-only `ReadLocks` procedure installed in Step 2. There is no separate MCP package to install or Python server to run.
- **Caddy gateway:** checks the `X-API-Key` header before forwarding requests to DAB over private loopback. Container Apps provides the external HTTPS endpoint.

**Request path:** SRE Agent → HTTPS/API-key gateway → DAB SQL MCP → SQL diagnostics.

This starter disables REST, GraphQL, write tools and caching. `execute_entity` is enabled only for the configured read-only lock procedure, not arbitrary SQL. DAB configuration and the dedicated reader's SQL grants constrain access. See the [DAB source](https://github.com/Azure/data-api-builder) for the engine; this repository supplies deployment, configuration and DBA setup.

## Before you start

Have the SQL hostname/database, permission to deploy hosting, an active SRE Agent, and a DBA available to authorize a dedicated reader.

For private SQL, use an existing SQL-connected Container Apps environment or an approved dedicated subnet. The host needs working SQL DNS, routing and certificate trust. **Only the MCP host needs SQL connectivity; SRE Agent connects to the HTTPS MCP endpoint.** Do not open SQL to the internet to shorten setup.

## 1. Deploy to Azure Container Apps

**Azure Container Apps (recommended)** provides managed hosting and HTTPS. You do not need to build images or install a container runtime.

[![Deploy to Azure](https://raw.githubusercontent.com/puneetg1983/sql-mcp-sre-starter/main/docs/assets/deploy-azure.svg)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fpuneetg1983%2Fsql-mcp-sre-starter%2Fv0.1.1%2Finfra%2Fazuredeploy.json/createUIDefinitionUri/https%3A%2F%2Fraw.githubusercontent.com%2Fpuneetg1983%2Fsql-mcp-sre-starter%2Fv0.1.1%2Finfra%2FcreateUiDefinition.json)
[![Bicep template](https://raw.githubusercontent.com/puneetg1983/sql-mcp-sre-starter/main/docs/assets/bicep.svg)](https://github.com/puneetg1983/sql-mcp-sre-starter/blob/v0.1.1/infra/main.bicep)
[![ARM JSON template](https://raw.githubusercontent.com/puneetg1983/sql-mcp-sre-starter/main/docs/assets/arm.svg)](https://github.com/puneetg1983/sql-mcp-sre-starter/blob/v0.1.1/infra/azuredeploy.json)
[![Terraform template](https://raw.githubusercontent.com/puneetg1983/sql-mcp-sre-starter/main/docs/assets/terraform.svg)](https://github.com/puneetg1983/sql-mcp-sre-starter/tree/main/infra/terraform)

Prefer infrastructure as code? Bicep and ARM provide the same deployment as the button; Terraform wraps the committed ARM template. Use Bicep from the full `v0.1.1` checkout because it loads `config` files, or follow the [Terraform setup](https://github.com/puneetg1983/sql-mcp-sre-starter/tree/main/infra/terraform) from a `main` checkout. ARM JSON embeds its configuration. All use the SQL/network settings below. Terraform secrets are stored in state/plans; use an access-controlled, encrypted backend.

Select your **subscription, resource group and region**. If reusing a Container Apps environment, select its region. Then fill in **SQL and networking** as follows:

| Form field | What to enter |
|---|---|
| **MCP app name** | Keep `sql-mcp`. |
| **SQL TLS hostname** | E.g. `orders-sql.database.windows.net` or the VM's certificate-matching DNS name. No URL, IP, port or `\instance`. |
| **Database name** | Existing database, e.g. `Orders`; use the same name in Step 2. |
| **SQL TCP port** | `1433` for Azure SQL; your DBA's configured TCP port for a VM. |
| **MCP host to SQL authentication** | **Managed identity** for Azure SQL; **Dedicated SQL reader login** for a VM unless SQL 2022+ Entra is configured. |
| **Dedicated reader login name / password** | SQL-login only: an existing DBA-provisioned reader and its password. Never administrator/application credentials. |
| **Existing environment resource ID (optional)** | Full ID of a SQL-connected environment in this region with a `Consumption` workload profile; otherwise blank. |
| **New environment's subnet resource ID (optional)** | For private SQL: dedicated Container Apps subnet delegated to `Microsoft.App/environments`, not the SQL endpoint subnet. See below. |
| **MCP API key** | Save a random 32-128 character key using letters, digits, `_` or `-`. SRE Agent sends it as `X-API-Key`. |

**Choose exactly one network path:**

| Your situation | Existing environment field | New environment's subnet field |
|---|---|---|
| You already have a SQL-connected Container Apps environment | Paste its resource ID | Leave empty; the field is hidden |
| You need a new environment for private SQL | Leave empty | Paste the approved subnet resource ID |
| SQL already has an approved public access path | Leave empty | Leave empty; your network/DBA team must still approve connectivity from the new host |

To find an existing environment's ID, open that resource in the Azure portal and copy **Resource ID** from **Properties** or **JSON View**. For a subnet, ask your network team for its resource ID. The formats are:

```text
Environment: /subscriptions/<subscription-id>/resourceGroups/<resource-group>/providers/Microsoft.App/managedEnvironments/<environment-name>
Subnet: /subscriptions/<subscription-id>/resourceGroups/<network-resource-group>/providers/Microsoft.Network/virtualNetworks/<vnet-name>/subnets/<subnet-name>
```

**Optional does not mean private networking is automatic.** The template does not create SQL, private endpoints, VNet peering, DNS links or SQL firewall rules, and it does not modify existing subnets. Your network team must ensure the host resolves the SQL hostname correctly, reaches SQL over the required network path and trusts its TLS certificate. Do not enable "allow all Azure services" or expose private SQL just to make deployment work. The MCP endpoint itself is public HTTPS protected by your API key; private SQL connectivity does not make the MCP endpoint private.

Select **Review + create**, then **Create**. After deployment, open **Outputs** and save `endpoint` and `readerName`; SQL-login users use their supplied login name. Continue to Step 2: successful host deployment alone does not grant SQL access.

## 2. Authorize the database and verify

Clone the release, then generate one DBA script in PowerShell 7.2+:

```powershell
git clone --branch v0.1.1 https://github.com/puneetg1983/sql-mcp-sre-starter.git
cd sql-mcp-sre-starter
pwsh ./scripts/New-DatabaseSetup.ps1 -Database Orders -ReaderName '<readerName>'
```

For SQL-login authentication, add `-SqlAuthentication sql-login`. Your DBA reviews and executes `.local/setup.sql` in the target database. **The starter never runs administrator SQL for you.**

**What `New-DatabaseSetup.ps1` does:**

- Generates `.local/setup.sql` for your database, reader and authentication mode; **does not execute SQL**.
- When run by the DBA, the generated SQL creates or updates four diagnostic views and the read-only `ReadLocks` procedure in `sre_sql`.
- Creates the database reader user if missing; SQL-login mode requires an existing server login.
- Grants access to those objects plus database-state visibility on Azure SQL or instance-level diagnostic visibility on SQL Server.
- Rejects the wrong database, unsupported versions, an unrecognized existing schema and readers with database ownership or schema ownership.
- Does not modify application tables, create SQL logins/passwords or send administrator credentials to MCP.

Azure SQL visibility varies by tier. See the [DBA reference](https://github.com/puneetg1983/sql-mcp-sre-starter/blob/v0.1.1/docs/permissions.md) for grants and visibility requirements.

Check the real endpoint, supplying your saved key at its hidden prompt:

```powershell
pwsh ./scripts/Test-Mcp.ps1 -Endpoint 'https://<host>/mcp' -Database Orders -ReaderName '<readerName>'
```

This checks authentication, tool exposure, all diagnostic objects and the actual reader. A healthy container alone is not proof. Complete the documented independent-session check before relying on blocking investigations.

## 3. Connect Azure SRE Agent

In [SRE Agent](https://sre.azure.com), open **Build + setup > Extensions > Connectors > Add MCP server**.

| Setting | Value |
|---|---|
| Transport | Streamable-HTTP |
| URL | Your full `https://<host>/mcp` endpoint |
| Custom header | `X-API-Key`, with your saved key |
| Tools | `describe_entities`, `read_records`, `execute_entity` |

If authentication and headers are separate, choose **No authentication** and add the header; the gateway still requires it. Save, wait for **Connected**, select the tools and open a new chat:

> Use my SQL diagnostics connector. Confirm the database and reader identity, then inspect current requests, sessions, transactions and locks. Explain blocking with session IDs and observation times. Do not modify SQL. Say when evidence is insufficient.

The agent receives read-only live evidence, not permission to fix the database. Keep secrets out of chat and retain your existing telemetry. For deeper investigation, operating guidance and limitations, follow the starter's references rather than adding more steps to this quickstart.
