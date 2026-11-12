# Connect Azure SRE Agent to SQL in three steps

Your application is timing out. Database CPU looks normal. Is SQL waiting on a lock, or is a sleeping session holding an open transaction?

Azure metrics help explain resource pressure, but not every live database question. **Microsoft's SQL MCP Server, included in Data API builder, gives Azure SRE Agent a controlled way to read current SQL evidence.** It complements Azure Monitor, application telemetry and Query Store; it does not replace them.

You should not need to write a server, build a container image or follow pages of deployment commands. This [open-source starter](https://github.com/puneetg1983/sql-mcp-sre-starter) packages the configuration and deployment steps.

**The customer workflow is: deploy to Azure Container Apps, authorize one database, connect SRE Agent.** This guide uses **Azure Container Apps (recommended)** as the only hosting path and covers Azure SQL Database and SQL Server 2019+ on Azure VMs. Managed Instance is outside this starter's scope.

> This is a community starter, not a Microsoft product deployment. Review its [validation status](https://github.com/puneetg1983/sql-mcp-sre-starter/blob/v0.1.1/docs/validation.md) before production use. SQL permissions and private-network approval remain administrator decisions; no button can safely skip them.

## Before you start

Have the SQL hostname/database, permission to deploy hosting, an active SRE Agent, and a DBA available to authorize a dedicated reader.

For private SQL, use an existing SQL-connected Container Apps environment or an approved dedicated subnet. The host needs working SQL DNS, routing and certificate trust. **Only the MCP host needs SQL connectivity; SRE Agent connects to the HTTPS MCP endpoint.** Do not open SQL to the internet to shorten setup.

## 1. Deploy to Azure Container Apps

**Azure Container Apps (recommended)** provides managed hosting and HTTPS. You do not need to build images or install a container runtime.

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fpuneetg1983%2Fsql-mcp-sre-starter%2Fv0.1.1%2Finfra%2Fazuredeploy.json/createUIDefinitionUri/https%3A%2F%2Fraw.githubusercontent.com%2Fpuneetg1983%2Fsql-mcp-sre-starter%2Fv0.1.1%2Finfra%2FcreateUiDefinition.json)

Select your subscription, resource group and region; enter your SQL hostname/database and network option. Save a random 32-128 character API key in your password manager.

Use **managed identity for Azure SQL**. For a SQL VM, use a dedicated SQL reader login unless SQL Server 2022+ Entra authentication is already configured. Never enter SQL administrator credentials. After deployment, save the `endpoint` and `readerName` outputs; SQL-login users use their supplied login name.

## 2. Authorize the database and verify

Clone the release, then generate one DBA script in PowerShell 7.2+:

```powershell
git clone --branch v0.1.1 https://github.com/puneetg1983/sql-mcp-sre-starter.git
cd sql-mcp-sre-starter
pwsh ./scripts/New-DatabaseSetup.ps1 -Database Orders -ReaderName '<readerName>'
```

For SQL-login authentication, add `-SqlAuthentication sql-login`. Your DBA reviews and executes `.local/setup.sql` in the target database. **The starter never runs administrator SQL for you.**

The script exposes requests, sessions, transactions, locks and connection identity, not business tables or arbitrary SQL. SQL VM diagnostic grants are instance scoped; Azure SQL visibility varies by tier. The [DBA reference](https://github.com/puneetg1983/sql-mcp-sre-starter/blob/v0.1.1/docs/permissions.md) explains both.

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
