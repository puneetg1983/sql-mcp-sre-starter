# Connect Azure SRE Agent to SQL

Give your agent **read-only live SQL diagnostics**: requests, waits, sessions, transactions and locks. Runs Microsoft's SQL MCP Server (Data API builder), not a custom SQL execution server.

**Three steps: deploy to Azure Container Apps, authorize one database, connect SRE Agent.** This quickstart uses **Azure Container Apps (recommended)** as its only hosting path. Existing Azure SQL Database and SQL Server 2019+ on Azure VMs are supported targets. SQL Managed Instance is not included.

> Community starter, not a Microsoft product deployment. Infrastructure deployment is not proof of SQL readiness. See [validation status](docs/validation.md) before production use.

## 1. Deploy to Azure Container Apps

Managed hosting and HTTPS, with no customer ACR, image builds, Python, or DAB installation. You provide an approved SQL network path.

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fpuneetg1983%2Fsql-mcp-sre-starter%2Fv0.1.1%2Finfra%2Fazuredeploy.json/createUIDefinitionUri/https%3A%2F%2Fraw.githubusercontent.com%2Fpuneetg1983%2Fsql-mcp-sre-starter%2Fv0.1.1%2Finfra%2FcreateUiDefinition.json)

Select your subscription, resource group and region. Supply the SQL hostname/database, authentication choice, and a random **32-128 character API key** saved in your password manager.

**Private SQL:** select an existing SQL-connected Container Apps environment, or supply an approved dedicated subnet delegated to `Microsoft.App/environments`. The template does not alter your SQL firewall, DNS, routing, or existing subnets. Without either network option, only an already-approved public SQL path will work. Do not enable "allow all Azure services" to bypass this.

Use **managed identity** for Azure SQL. For a SQL VM, use a dedicated SQL reader login unless SQL Server 2022+ Entra authentication is already configured. Never supply SQL administrator credentials. Managed identity for SQL and the API key used by SRE Agent are separate.

After deployment, open **Outputs** and save `endpoint` and `readerName`. With SQL-login authentication, use your supplied login name instead of `readerName`.

## 2. Authorize the database, then verify

Clone release **v0.1.1**, then generate one DBA script in PowerShell 7.2+ using your deployment output. Replace `Orders` with your database name in both commands below:

```powershell
git clone --branch v0.1.1 https://github.com/puneetg1983/sql-mcp-sre-starter.git
cd sql-mcp-sre-starter
pwsh ./scripts/New-DatabaseSetup.ps1 -Database Orders -ReaderName '<readerName>'
```

For SQL-login authentication, add `-SqlAuthentication sql-login` and use the pre-provisioned dedicated login name. Have your DBA review and run **`.local/setup.sql` in the target database**, using SSMS or another approved SQL client. The script installs diagnostic objects and narrow object grants; it does not change application tables or execute workload transactions.

SQL VM setup additionally requires instance-level diagnostic grants. Azure SQL visibility varies by service tier. Neither database ownership nor administrator credentials are acceptable workarounds. [DBA permissions and visibility check](docs/permissions.md).

After the host has started, verify it:

```powershell
pwsh ./scripts/Test-Mcp.ps1 -Endpoint 'https://<host>/mcp' -Database Orders -ReaderName '<readerName>'
```

Enter your saved API key at the hidden prompt. The check rejects missing/wrong keys, verifies the tool/entity allow-lists, reads all diagnostic objects, and checks runtime identity and selected privileges. It does **not** create an order or deliberately block SQL.

Generated files live in access-restricted, git-ignored `.local`. Protect them, do not upload them, and remove them when no longer needed.

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

[DBA permissions](docs/permissions.md) | [SRE connection](docs/connect-sre-agent.md) | [Operations](docs/operations.md) | [Validation](docs/validation.md)

## License

Templates, scripts and documentation are [MIT licensed](LICENSE). Referenced container images retain their respective licenses.

## Remove the starter

Remove only the dedicated Azure resources you deployed after reviewing their scope. Do not delete a shared resource group, network or Container Apps environment. Have the DBA review removal of `sre_sql` objects and the dedicated reader; this package never drops the workload database.
