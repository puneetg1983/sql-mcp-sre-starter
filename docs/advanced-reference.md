# Advanced reference: the original manual SQL observability guide

> **Start with the [three-step quickstart](../README.md), not these manual deployment steps.** This archived article explains the design, historical telemetry and disposable blocking test. Its hand-built gateway, image-build commands, object names and configuration examples predate the starter. They are an alternative manual implementation, not instructions to combine with the generated starter. The current supported files are `config/`, `sql/setup.sql`, and `infra/`; see [validation status](validation.md).

## Preparing SQL for Azure SRE Agent

An application starts timing out, but database CPU looks normal. Is a query waiting for a lock? Is the owner of that lock a sleeping session with an open transaction? Or did the application exhaust its connection pool before a request reached SQL?

Those questions are not answered by giving an AI agent a larger prompt. They are answered by giving it the right evidence. The goal is to make the same evidence useful to both an agent and a human engineer.

This article prepares **Azure SQL Database and SQL Server running on an Azure IaaS VM** for **reader-only investigation through Microsoft's SQL MCP Server**, then connects that server to **Azure SRE Agent**. Your administrators deploy the infrastructure and diagnostic objects. The agent reads evidence and recommends a response; your team decides whether and how to make changes.

**One article covers both platforms.** The MCP configuration, hosting, connector setup and investigation workflow are shared. Networking, database authentication and diagnostic permissions have separate platform-specific instructions. Here, "Azure SQL" means **Azure SQL Database**, not Azure SQL Managed Instance; do not apply Database-specific permission instructions to Managed Instance.

> **Scope and validation:** This is a customer-facing starter, not a Microsoft product deployment template or a promise of identical DMV visibility on every SQL edition. The API-key gateway pattern and official DAB 2.1.5 backend have been exercised against a private Azure SQL Database, including cross-session blocking and read-only permission checks. The generalized examples below still need the acceptance test on your database, SQL version, network and SRE Agent. The SQL-on-VM and native-Entra alternatives are not presented as end-to-end tested deployments.

<a id="how-it-works"></a>
## How the agent sees SQL

Three different pieces are involved:

| Component | What it does | What it does not do |
|---|---|---|
| **Azure SRE Agent** | Reasons about an incident and calls selected tools | Does not automatically become a SQL administrator |
| **SQL MCP Server, included in Microsoft Data API builder (DAB)** | Publishes configured database objects as MCP tools | Is not an LLM and does not accept arbitrary natural-language-generated SQL |
| **SQL database engine** | Supplies diagnostic state and enforces SQL permissions | Does not automatically send all diagnostic state to Azure Monitor |

The agent has two complementary sources of evidence:

| Source | Best for |
|---|---|
| **Azure Monitor, Log Analytics and application telemetry** | Historical trends, alerts, application timeouts, resource changes and correlation |
| **SQL MCP** | Current requests, waits, sessions, transactions and locks |

MCP does not replace telemetry collection. A live lock can disappear before an investigation starts. A deadlock victim might already have been rolled back. Keep historical evidence as well as a live diagnostic connection.

The hosting pattern in this guide has a public, authenticated HTTPS MCP endpoint and a private connection from its host to SQL. Azure SRE Agent calls the MCP endpoint; **only the MCP host needs direct network access to SQL**.

## What Azure gives you by default, and what you add

Azure SQL Database exposes platform metrics and management-plane information. SQL Server on a VM has VM platform metrics, but those metrics are not a view inside the SQL engine. Azure Reader access alone is not a SQL login and is not permission to inspect database sessions.

| Question | Evidence to prepare |
|---|---|
| Are application requests failing before or during a SQL call? | Application dependency telemetry, exception codes and connection-pool instrumentation |
| Is SQL under CPU, I/O or capacity pressure? | Azure SQL metrics, or VM/guest/SQL performance telemetry |
| Who is blocking whom right now? | Requests, sessions, transactions and locks through MCP |
| What happened earlier? | Query Store, appropriately retained logs and, when needed, Extended Events |
| What changed? | Deployment records, Azure Activity Log and separately configured SQL auditing |

**Start with a small diagnostic contract.** Do not expose every table or install a generic `execute_sql` tool just to investigate timeouts.

<a id="overview"></a>
## The setup at a glance

The steps below assume an existing pilot database. They do not create or migrate the workload's database.

| Step | What you set up |
|---|---|
| [1. Choose a network path](#s1) | Container Apps can reach private SQL; SRE Agent can reach HTTPS MCP |
| [2. Create the database identity](#s2) | Managed identity for Azure SQL; supported Entra or dedicated SQL authentication for a VM |
| [3. Create diagnostic objects](#s3) | Three views, one lock-reading procedure and a connection-information view |
| [4. Grant and verify permissions](#s4) | Platform/version-specific state visibility, not database-owner access |
| [5. Configure Microsoft's package](#s5) | An explicit read-only MCP contract, with caching disabled |
| [6. Host it in Container Apps](#s6) | Official DAB image, a small authentication gateway and protected secrets |
| [7. Connect Azure SRE Agent](#s7) | Exact endpoint, transport, authentication and tool-selection steps |
| [8. Teach the agent your environment](#s8) | A short evidence map and an investigation prompt |
| [9. Prove the complete path](#s9) | A disposable blocking test, visibility checks and cleanup |
| [10. Operate it safely](#s10) | History, cost, privacy, rotation and failure diagnosis |

**Prerequisites:** Azure CLI with Bicep and Container Apps support; permission to deploy the monitoring resources; an approved SQL administrator connection for setup; an active Azure SRE Agent; and an existing Azure Container Apps environment with the required SQL network path. The examples use PowerShell 7. Local Docker, Python and a local DAB/.NET installation are not required: ACR builds the small gateway image, and Microsoft's DAB image already contains its runtime.

The VM examples target SQL Server 2019 and supported newer releases. Review older-engine compatibility separately; the scripts use `CREATE OR ALTER`, which requires SQL Server 2016 SP1 or later. Keep both the engine and client/package versions within their supported lifecycles.

<a id="s1"></a>
## 1. Choose the network path first

**Why it matters:** a successful MCP handshake does not prove that the host can connect to SQL.

Use an Azure Container Apps environment integrated with a VNet that can reach your database. It can be the database's VNet or a connected network with the required routing and DNS.

If you do not already have that environment, have your network administrator allocate a dedicated, correctly sized subnet for a **workload-profiles environment**, with the required `Microsoft.App/environments` delegation. Do not reuse the SQL private-endpoint or VM subnet. Create the environment against that approved subnet:

```powershell
az containerapp env create --resource-group '<monitoring-resource-group>' `
  --name '<environment-name>' --location '<environment-region>' `
  --enable-workload-profiles true `
  --infrastructure-subnet-resource-id '<approved-dedicated-subnet-resource-id>'
```

The CLI may provision a monitoring workspace if you do not supply an existing destination; review that choice and its ingestion costs. Record the environment resource ID. Use the same region for the Container App, even if the resource group's metadata location differs.

| Azure SQL Database | SQL Server on an Azure VM |
|---|---|
| Prefer a private endpoint and correctly linked private DNS | Use the VM's private address or an appropriate private SQL listener |
| Connect using `<server>.database.windows.net`, not a substituted private IP | Use a DNS name that matches the SQL TLS certificate |
| Resolve the normal SQL hostname to its private endpoint through the configured DNS path | Configure TCP and a known listener port; do not assume every named instance uses 1433 |
| Account for the configured SQL connection policy and any required redirect ports, not just the initial 1433 connection | Allow only the host network's required traffic through NSGs and the guest firewall |

Keep SQL public access disabled where your architecture allows it. Do not enable "allow all Azure services" or expose VM port 1433 to the internet as a shortcut.

The host also needs access to its container registry, Key Vault and any identity endpoints it uses. A private Key Vault requires its own working DNS and network path. [Azure SQL connection policies](https://learn.microsoft.com/azure/azure-sql/database/connectivity-architecture) and [Container Apps networking](https://learn.microsoft.com/azure/container-apps/networking) describe the relevant platform requirements.

The examples expose **only MCP over HTTPS** through Container Apps ingress. If your organization requires a private MCP endpoint, establish and verify the SRE Agent-to-endpoint network path before changing ingress. A private SQL connection and a private MCP connection are two different requirements.

<a id="s2"></a>
## 2. Create a dedicated database identity

**Why it matters:** the agent's inbound identity and the server's database identity are separate.

For the starter, create a user-assigned managed identity named `sql-mcp-reader`. It is attached to the Container App. Record its **resource ID**, **client ID** and **principal/object ID**; these identifiers are not interchangeable.

```powershell
az identity create --resource-group '<monitoring-resource-group>' --name sql-mcp-reader
```

### Azure SQL Database: use managed identity

Configure a Microsoft Entra administrator for the logical server. Connect as that administrator to the **target database**, using your normal SQL administration client:

```sql
CREATE USER [sql-mcp-reader] FROM EXTERNAL PROVIDER;
```

This creation path requires the appropriate directory lookup permissions and a uniquely resolvable identity. If your organization uses explicit object-ID/SID creation, follow its supported procedure instead; do not guess the SID from an unrelated GUID. Check an existing principal's identity rather than recreating or overwriting it blindly.

The connection string stored for the host is:

```text
Server=tcp:<server>.database.windows.net,1433;Database=<database>;Encrypt=True;TrustServerCertificate=False;Authentication=Active Directory Managed Identity;User Id=<reader-managed-identity-client-id>;Application Name=SreSqlMcp;
```

There is no SQL password in this connection string.

### SQL Server on a VM: choose a supported authentication path

**Managed identity is not automatically supported because SQL happens to run on an Azure VM.** Microsoft's documented Entra setup for SQL Server on Azure VMs requires SQL Server 2022 or later, registration with the SQL IaaS Agent extension and the necessary identity/directory configuration. Follow [Enable Microsoft Entra authentication for SQL Server on Azure VMs](https://learn.microsoft.com/azure/azure-sql/virtual-machines/windows/configure-azure-ad-authentication-for-sql-vm) before choosing that path.

With Entra authentication configured, the administrator creates the external login in `master`, then maps it in the target database:

```sql
-- Run in master on the SQL Server instance.
CREATE LOGIN [sql-mcp-reader] FROM EXTERNAL PROVIDER;
GO
-- Reconnect to the target database before running this statement.
CREATE USER [sql-mcp-reader] FROM LOGIN [sql-mcp-reader];
GO
```

Use the managed-identity connection string above, replacing the server/port with the VM's private SQL DNS name and actual listener port.

For older versions or environments without configured Entra support, ask your DBA to provision a **dedicated, policy-compliant SQL login** through your approved secret-management process. Map it to a user in the target database:

```sql
-- Run in the target database, after the DBA has created this login.
CREATE USER [sql_mcp_reader] FROM LOGIN [sql_mcp_reader];
```

Its connection-string shape is:

```text
Server=tcp:<private-sql-dns-name>,<port>;Database=<database>;Encrypt=True;TrustServerCertificate=False;User ID=sql_mcp_reader;Password=<secret-managed-password>;Application Name=SreSqlMcp;
```

**Store the real value in Key Vault, not a source file or command argument.** Enabling mixed-mode authentication or restarting SQL is a separate DBA decision, not an automatic step in this guide. Windows integrated authentication also needs an intentionally designed host/domain configuration; do not assume a Linux Container App can use the VM administrator's Windows login.

For VM-hosted SQL, configure a trusted SQL TLS certificate and a matching hostname. If it uses a private CA, prepare the container's trust appropriately. Do not fix a certificate error by changing `TrustServerCertificate` to `True`.

<a id="s3"></a>
## 3. Create a small diagnostic contract

**Why it matters:** SQL MCP publishes configured tables, views and stored procedures. It does not come with a complete DBA diagnostic schema.

Create the following objects **once, in the target database**, as an administrator. Save this as `diagnostics.sql` and execute it using a SQL client that understands `GO`. Review existing objects before using `CREATE OR ALTER` in an established environment.

The views intentionally omit raw SQL text and login names. Those can contain sensitive information; add them only after review. They still provide the identifiers needed to correlate a live blocking chain.

<details>
<summary><b>Show diagnostics.sql</b></summary>

```sql
IF SCHEMA_ID(N'sre_sql') IS NULL
    EXEC(N'CREATE SCHEMA sre_sql AUTHORIZATION dbo');
GO
CREATE OR ALTER VIEW sre_sql.Requests AS
SELECT r.session_id AS SessionId, r.request_id AS RequestId,
       r.blocking_session_id AS BlockingSessionId,
       r.status AS Status, r.wait_type AS WaitType,
       r.wait_time AS WaitTimeMs, r.wait_resource AS WaitResource,
       r.cpu_time AS CpuTimeMs, r.total_elapsed_time AS ElapsedTimeMs,
       r.transaction_id AS TransactionId,
       SYSUTCDATETIME() AS ObservedAtUtc
FROM sys.dm_exec_requests AS r
WHERE r.database_id = DB_ID();
GO
CREATE OR ALTER VIEW sre_sql.Sessions AS
SELECT s.session_id AS SessionId, s.status AS Status,
       s.open_transaction_count AS OpenTransactionCount,
       s.program_name AS ProgramName,
       s.last_request_start_time AS LastRequestStartedAt,
       s.last_request_end_time AS LastRequestEndedAt,
       SYSUTCDATETIME() AS ObservedAtUtc
FROM sys.dm_exec_sessions AS s
WHERE s.is_user_process = 1
  AND (s.database_id = DB_ID() OR EXISTS (
       SELECT 1 FROM sys.dm_exec_requests AS r
       WHERE r.database_id = DB_ID()
         AND r.blocking_session_id = s.session_id));
GO
CREATE OR ALTER VIEW sre_sql.Transactions AS
SELECT st.session_id AS SessionId, st.transaction_id AS TransactionId,
       a.transaction_begin_time AS BeganAt,
       a.transaction_type AS TransactionType,
       a.transaction_state AS TransactionState,
       SYSUTCDATETIME() AS ObservedAtUtc
FROM sys.dm_tran_session_transactions AS st
JOIN sys.dm_tran_active_transactions AS a
  ON a.transaction_id = st.transaction_id
JOIN sys.dm_tran_database_transactions AS d
  ON d.transaction_id = st.transaction_id
WHERE d.database_id = DB_ID();
GO
CREATE OR ALTER PROCEDURE sre_sql.ReadLocks @SessionId int = NULL AS
BEGIN
    SET NOCOUNT ON;
    SELECT request_session_id AS SessionId,
           resource_type AS ResourceType,
           resource_associated_entity_id AS ResourceEntityId,
           resource_description AS ResourceDescription,
           request_mode AS LockMode, request_status AS LockStatus,
           request_owner_type AS OwnerType, request_owner_id AS OwnerId,
           SYSUTCDATETIME() AS ObservedAtUtc
    FROM sys.dm_tran_locks
    WHERE resource_database_id = DB_ID()
      AND (@SessionId IS NULL OR request_session_id = @SessionId);
END;
GO
CREATE OR ALTER VIEW sre_sql.ConnectionInfo AS
SELECT @@SPID AS SessionId, DB_NAME() AS DatabaseName,
       USER_NAME() AS DatabaseUser,
       IS_ROLEMEMBER(N'db_owner') AS IsDbOwner,
       HAS_PERMS_BY_NAME(DB_NAME(), N'DATABASE', N'CONTROL') AS CanControlDatabase,
       HAS_PERMS_BY_NAME(DB_NAME(), N'DATABASE', N'CREATE TABLE') AS CanCreateTable,
       SYSUTCDATETIME() AS ObservedAtUtc;
GO
```

</details>

The lock reader is a procedure because a live lock row has no convenient, stable pagination key. **`execute_entity` is safe here because this specific procedure only reads state**, not because all stored procedures are inherently read-only.

These are current observations, not an atomic snapshot across tool calls. Session IDs can be reused; correlate timestamps and transaction IDs as well. Cross-database blocking on a SQL instance may require additional reviewed diagnostic objects: this starter is not a complete instance-wide blocking-chain implementation.

<a id="s4"></a>
## 4. Grant the right visibility, then prove it

**Why it matters:** seeing your own connection is not the same as seeing the workload's connections.

Run the object grants in the target database. Replace the user name with `sql_mcp_reader` for the SQL-login alternative:

```sql
GRANT SELECT, VIEW DEFINITION ON OBJECT::sre_sql.Requests TO [sql-mcp-reader];
GRANT SELECT, VIEW DEFINITION ON OBJECT::sre_sql.Sessions TO [sql-mcp-reader];
GRANT SELECT, VIEW DEFINITION ON OBJECT::sre_sql.Transactions TO [sql-mcp-reader];
GRANT SELECT, VIEW DEFINITION ON OBJECT::sre_sql.ConnectionInfo TO [sql-mcp-reader];
GRANT EXECUTE, VIEW DEFINITION ON OBJECT::sre_sql.ReadLocks TO [sql-mcp-reader];
```

Object grants alone do not guarantee permission to read the underlying dynamic management views (DMVs).

### Azure SQL Database

Start with the database-level grant in the target database:

```sql
GRANT VIEW DATABASE STATE TO [sql-mcp-reader];
```

Required visibility varies with the DMV and service tier. Microsoft's [Azure SQL DMV guide](https://learn.microsoft.com/azure/azure-sql/database/monitoring-with-dmvs) describes logical-server diagnostic roles, including `##MS_ServerStateReader##`; Microsoft's individual DMV pages also document restrictions, including Azure SQL-specific request visibility.

**Do not treat this grant, or a role name, as a universal guarantee.** If the reader cannot see the two test sessions in [step 9](#s9), have your DBA review the exact DMV, tier and supported principal/role configuration. A logical-server role requires an appropriately provisioned login in `master`, not merely a contained user in the workload database, and can broaden access across databases that login can access. Grant it only after that review.

Do not substitute an administrator connection when a narrower reader cannot obtain the required evidence. If cross-session visibility cannot be approved, document the limitation and use approved collected evidence instead of advertising full blocking diagnostics.

### SQL Server on a VM

For the instance-level diagnostic objects in this starter, grant the version-appropriate state permission to the **login**, not merely the database user:

```sql
-- SQL Server 2019 and earlier: run at instance scope.
GRANT VIEW SERVER STATE TO [sql-mcp-reader];
```

```sql
-- SQL Server 2022 and later: run at instance scope instead of the previous grant.
GRANT VIEW SERVER PERFORMANCE STATE TO [sql-mcp-reader];
```

Use the SQL login's actual name for SQL authentication. Check each additional DMV before expanding this starter; newer versions separate performance and security state permissions.

These grants expose diagnostic information at instance scope to the service login. Filtering the published views limits **MCP output**, but does not turn an instance-wide SQL grant into a database-scoped grant. For stricter isolation, have your DBA design and review signed diagnostic modules rather than casually granting broader access or enabling `TRUSTWORTHY`.

Do not grant `sysadmin`, `db_owner`, business-table write access, schema-change permissions or session-termination capabilities. Inspect inherited roles too. **Read-only is not the same as non-sensitive**: diagnostics can reveal workload and infrastructure details.

<a id="s5"></a>
## 5. Configure Microsoft's SQL MCP package

**Why it matters:** the JSON is the agent-facing contract, not just a database connection setting.

Microsoft distributes SQL MCP as part of Data API builder. Use the official image; do not write a Python MCP implementation or a free-form SQL execution endpoint. This example pins the previously exercised **2.1.5 non-root image**, not a claim about the latest release. Review and validate upgrades through your normal process.

Save the following as `dab-config.json`. The inbound authentication is deliberately handled by the gateway in step 6. **Do not expose this unauthenticated DAB listener directly.**

<details>
<summary><b>Show the five-entity, read-only DAB configuration</b></summary>

```json
{
  "$schema": "https://github.com/Azure/data-api-builder/releases/download/v2.1.5/dab.draft.schema.json",
  "data-source": {
    "database-type": "mssql",
    "connection-string": "@env('SQL_CONNECTION_STRING')",
    "options": { "set-session-context": false }
  },
  "runtime": {
    "host": {
      "mode": "production",
      "authentication": { "provider": "Unauthenticated" }
    },
    "rest": { "enabled": false },
    "graphql": { "enabled": false },
    "cache": { "enabled": false },
    "mcp": {
      "enabled": true,
      "path": "/mcp",
      "description": "Read current SQL diagnostic state for this database. Correlate timestamps, sessions and transactions. Never modify SQL.",
      "dml-tools": {
        "describe-entities": true,
        "read-records": true,
        "execute-entity": true,
        "create-record": false,
        "update-record": false,
        "delete-record": false,
        "aggregate-records": false
      }
    }
  },
  "entities": {
    "Requests": {
      "source": { "type": "view", "object": "sre_sql.Requests" },
      "fields": [
        { "name": "SessionId", "primary-key": true },
        { "name": "RequestId", "primary-key": true },
        { "name": "BlockingSessionId" }, { "name": "Status" },
        { "name": "WaitType" }, { "name": "WaitTimeMs" },
        { "name": "WaitResource" }, { "name": "CpuTimeMs" },
        { "name": "ElapsedTimeMs" }, { "name": "TransactionId" },
        { "name": "ObservedAtUtc" }
      ],
      "description": "Current requests and waits in the target database, subject to SQL visibility permissions.",
      "permissions": [{ "role": "anonymous", "actions": ["read"] }],
      "cache": { "enabled": false }
    },
    "Sessions": {
      "source": { "type": "view", "object": "sre_sql.Sessions" },
      "fields": [
        { "name": "SessionId", "primary-key": true },
        { "name": "Status" }, { "name": "OpenTransactionCount" },
        { "name": "ProgramName" }, { "name": "LastRequestStartedAt" },
        { "name": "LastRequestEndedAt" }, { "name": "ObservedAtUtc" }
      ],
      "description": "Database sessions and directly referenced blockers, including sleeping owners of open transactions.",
      "permissions": [{ "role": "anonymous", "actions": ["read"] }],
      "cache": { "enabled": false }
    },
    "Transactions": {
      "source": { "type": "view", "object": "sre_sql.Transactions" },
      "fields": [
        { "name": "SessionId", "primary-key": true },
        { "name": "TransactionId", "primary-key": true },
        { "name": "BeganAt" }, { "name": "TransactionType" },
        { "name": "TransactionState" }, { "name": "ObservedAtUtc" }
      ],
      "description": "Current transactions in the target database and their owning sessions.",
      "permissions": [{ "role": "anonymous", "actions": ["read"] }],
      "cache": { "enabled": false }
    },
    "ReadLocks": {
      "source": {
        "type": "stored-procedure",
        "object": "sre_sql.ReadLocks",
        "parameters": [{ "name": "SessionId", "required": false, "default": null }]
      },
      "description": "Read current database lock modes and grant/wait states, optionally filtered by SessionId.",
      "permissions": [{ "role": "anonymous", "actions": ["execute"] }],
      "cache": { "enabled": false }
    },
    "ConnectionInfo": {
      "source": { "type": "view", "object": "sre_sql.ConnectionInfo" },
      "fields": [
        { "name": "SessionId", "primary-key": true },
        { "name": "DatabaseName" }, { "name": "DatabaseUser" },
        { "name": "IsDbOwner" }, { "name": "CanControlDatabase" },
        { "name": "CanCreateTable" }, { "name": "ObservedAtUtc" }
      ],
      "description": "Actual runtime database context and selected privilege checks; not a complete permission audit.",
      "permissions": [{ "role": "anonymous", "actions": ["read"] }],
      "cache": { "enabled": false }
    }
  }
}
```

</details>

Two useful details:

- Views need declared keys so DAB can page results. `SessionId` plus `RequestId` identifies a current request; a timestamp does not make a DMV row a durable record.
- Caching is disabled globally and per entity. A cached answer about a lock that no longer exists is a bad starting point for mitigation.

This common contract intentionally excludes Azure SQL's `sys.dm_db_resource_stats`, which is not a drop-in SQL Server-on-VM view. Add a reviewed `ResourceStats` entity for Azure SQL if useful; use appropriate SQL/guest/VM metrics for a VM instead of presenting unrelated counters as equivalent.

<a id="s6"></a>
## 6. Host the package in Azure Container Apps

**Why it matters:** the host should be straightforward to deploy and have an explicit authentication boundary.

The reference host runs two containers in one replica:

| Container | Role |
|---|---|
| **Official DAB image** | SQL MCP, on loopback port 5000 |
| **Small Caddy gateway image** | Checks the API key and forwards only MCP routes on port 8080 |

Container Apps provides HTTPS and its managed certificate. The gateway is a compatibility/authentication boundary, not a custom SQL MCP server. There is no Python server and no custom DAB image.

### Prepare the resources and secrets

Use an existing VNet-integrated Container Apps environment. Create or select an ACR for the gateway image and a **dedicated Key Vault** for the two monitoring secrets. Enable Key Vault RBAC.

If you need new resources, these commands create the registry and vault in an existing monitoring resource group. Choose globally unique names and review your organization's vault network, soft-delete and purge-protection policy:

```powershell
az acr create --resource-group '<monitoring-resource-group>' `
  --name '<unique-registry-name>' --sku Basic --admin-enabled false

az keyvault create --resource-group '<monitoring-resource-group>' `
  --name '<unique-dedicated-vault-name>' --location '<environment-region>' `
  --enable-rbac-authorization true
```

In the Key Vault portal, create:

Your operator needs data-plane permission to create secrets, such as an approved **Key Vault Secrets Officer** assignment. Azure resource Owner alone is not a Key Vault data-plane grant. This setup permission is separate from the host's read-only **Key Vault Secrets User** assignment below.

| Secret | Value |
|---|---|
| `sql-mcp-api-key` | A cryptographically random API key |
| `sql-mcp-connection` | The platform-appropriate complete connection string from step 2 |

For a Windows operator, this creates a random value and copies it without printing it:

```powershell
$bytes = [System.Security.Cryptography.RandomNumberGenerator]::GetBytes(32)
$key = [Convert]::ToBase64String($bytes)
Set-Clipboard -Value $key
Remove-Variable key, bytes
```

Paste it into the secret-value field. Later, copy the same protected value into the SRE connector through your approved process. Clear the clipboard afterwards. Do not paste keys or database credentials into a chat, a screenshot or an article.

Give the Container App's managed identity **Key Vault Secrets User** on this dedicated vault and **AcrPull** on the gateway registry. These are host permissions, separate from its SQL grants:

```powershell
az role assignment create --assignee-object-id '<reader-principal-id>' `
  --assignee-principal-type ServicePrincipal --role 'Key Vault Secrets User' `
  --scope '<dedicated-key-vault-resource-id>'

az role assignment create --assignee-object-id '<reader-principal-id>' `
  --assignee-principal-type ServicePrincipal --role AcrPull `
  --scope '<registry-resource-id>'
```

Use narrower approved scopes where appropriate. Do not grant access to a shared vault full of unrelated application credentials.

The registry example assumes ACR's standard registry RBAC mode. An existing ABAC-enabled registry requires its documented repository permissions rather than assuming `AcrPull` is sufficient.

### Build the gateway

Save this as `Caddyfile`:

```caddyfile
{
    admin off
    auto_https off
}

:8080 {
    handle /health {
        rewrite * /
        reverse_proxy 127.0.0.1:5000 {
            @healthy status 200
            handle_response @healthy {
                respond "ok" 200
            }
            handle_response {
                respond "unhealthy" 503
            }
        }
    }

    @authorized {
        path /mcp /mcp/*
        header X-API-Key {$MCP_API_KEY}
    }
    handle @authorized {
        reverse_proxy 127.0.0.1:5000 {
            header_up Host 127.0.0.1:5000
            header_up -X-API-Key
            header_up -Authorization
            header_up -X-MS-*
        }
    }

    handle {
        respond "Unauthorized" 401
    }
}
```

`/health` reports only basic service health, not database names or diagnostic rows. All other non-MCP routes are denied.

Save this as `Dockerfile.gateway`. It uses an official Caddy base image, removes its privileged-port capability, runs non-root and refuses to start without a key:

```dockerfile
FROM caddy:2.11.7-alpine
RUN setcap -r /usr/bin/caddy
RUN mkdir -p /data/caddy /config/caddy && chown -R 10001:10001 /data /config
COPY Caddyfile /etc/caddy/Caddyfile
ENV HOME=/config
USER 10001:10001
RUN MCP_API_KEY=build-validation-only caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
ENTRYPOINT ["/bin/sh", "-c", "test -n \"$MCP_API_KEY\" || { echo 'MCP_API_KEY is required' >&2; exit 1; }; exec caddy run --config /etc/caddy/Caddyfile --adapter caddyfile"]
```

Use a clean build directory containing only these gateway inputs. In particular, do not send files containing secrets as an ACR build context:

```powershell
az acr build --registry '<registry-name>' --image sql-mcp/gateway:v1 `
  --file .\Dockerfile.gateway .

az acr repository show --name '<registry-name>' --image sql-mcp/gateway:v1 `
  --query digest --output tsv
```

Use the resulting `<registry-login-server>/sql-mcp/gateway@sha256:<digest>` in the deployment, rather than a mutable tag.

### Deploy the Container App

Save this as `sql-mcp.bicep`, beside `dab-config.json`. Key Vault URI parameters contain **references**, not secret values. Use your vault's secret URIs for the two secret parameters.

<details>
<summary><b>Show the Container Apps deployment template</b></summary>

```bicep
param location string = resourceGroup().location
param appName string
param environmentId string
param readerIdentityId string
param registryServer string
param gatewayImage string
param apiKeySecretUri string
param connectionSecretUri string

var dabImage = 'mcr.microsoft.com/azure-databases/data-api-builder@sha256:3b16893b676cc87cf1b17ff4b3bc184ac5ed0ae7a4b41497b5d571cb24cd278c'
var dabConfig = string(loadJsonContent('dab-config.json'))

resource app 'Microsoft.App/containerApps@2025-01-01' = {
  name: appName
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${readerIdentityId}': {} }
  }
  properties: {
    managedEnvironmentId: environmentId
    workloadProfileName: 'Consumption'
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: {
        external: true
        allowInsecure: false
        targetPort: 8080
        transport: 'auto'
      }
      registries: [{ server: registryServer, identity: readerIdentityId }]
      secrets: [
        { name: 'mcp-api-key', keyVaultUrl: apiKeySecretUri, identity: readerIdentityId }
        { name: 'sql-connection', keyVaultUrl: connectionSecretUri, identity: readerIdentityId }
        { name: 'dab-config', value: dabConfig }
      ]
    }
    template: {
      containers: [
        {
          name: 'gateway'
          image: gatewayImage
          env: [{ name: 'MCP_API_KEY', secretRef: 'mcp-api-key' }]
          resources: { cpu: json('0.25'), memory: '0.5Gi' }
          probes: [
            {
              type: 'Startup'
              httpGet: { path: '/health', port: 8080 }
              periodSeconds: 5
              failureThreshold: 60
              timeoutSeconds: 3
            }
            {
              type: 'Readiness'
              httpGet: { path: '/health', port: 8080 }
              periodSeconds: 10
              failureThreshold: 3
              timeoutSeconds: 3
            }
            {
              type: 'Liveness'
              httpGet: { path: '/health', port: 8080 }
              periodSeconds: 20
              failureThreshold: 6
              timeoutSeconds: 3
            }
          ]
        }
        {
          name: 'dab'
          image: dabImage
          args: ['--ConfigFileName', '/config/dab-config.json']
          env: [
            { name: 'SQL_CONNECTION_STRING', secretRef: 'sql-connection' }
            { name: 'ASPNETCORE_URLS', value: 'http://127.0.0.1:5000' }
            { name: 'DOTNET_EnableDiagnostics', value: '0' }
            { name: 'DAB_CONFIG_REVISION', value: uniqueString(dabConfig) }
          ]
          resources: { cpu: json('0.5'), memory: '1Gi' }
          volumeMounts: [{ volumeName: 'dab-config', mountPath: '/config' }]
        }
      ]
      volumes: [
        {
          name: 'dab-config'
          storageType: 'Secret'
          secrets: [{ secretRef: 'dab-config', path: 'dab-config.json' }]
        }
      ]
      scale: { minReplicas: 1, maxReplicas: 1 }
    }
  }
}

output endpoint string = 'https://${app.properties.configuration.ingress.fqdn}/mcp'
```

</details>

The existing environment must have a Consumption workload profile. This example uses **one active revision and one always-running replica** because MCP sessions can be process-local. A production highly available design needs separately validated session handling; do not assume that increasing the replica count is transparent.

Before deploying, check the compact configuration fits the 4096-byte Container Apps secret-value limit:

```powershell
$config = Get-Content -LiteralPath .\dab-config.json -Raw | ConvertFrom-Json -AsHashtable
$compact = ConvertTo-Json -InputObject $config -Depth 100 -Compress
if ([Text.Encoding]::UTF8.GetByteCount($compact) -gt 4096) {
    throw 'Configuration exceeds the secret-volume limit. Use a supported larger file mount.'
}

az bicep build --file .\sql-mcp.bicep --stdout | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Bicep compilation failed' }

az deployment group create --resource-group '<monitoring-resource-group>' `
  --name sql-mcp --template-file .\sql-mcp.bicep `
  --parameters location='<environment-region>' appName='<app-name>' `
    environmentId='<environment-resource-id>' `
    readerIdentityId='<reader-managed-identity-resource-id>' `
    registryServer='<registry-login-server>' gatewayImage='<gateway-image-with-digest>' `
    apiKeySecretUri='<key-vault-api-key-secret-uri>' `
    connectionSecretUri='<key-vault-connection-secret-uri>'

if ($LASTEXITCODE -ne 0) { throw 'Container App deployment failed' }
```

If a larger contract needs another mount mechanism or a small configuration-only DAB image wrapper, use one deliberately. Do not remove fields or permissions just to squeeze a configuration into the limit.

Check that the **latest revision is ready**, not merely that an older revision still serves `/health`:

```powershell
az containerapp show --resource-group '<monitoring-resource-group>' --name '<app-name>' `
  --query '{latest:properties.latestRevisionName,ready:properties.latestReadyRevisionName}'
```

The two revision names must match. Basic health still does not prove SQL visibility: continue to connector setup and the acceptance test.

### Can I remove the gateway and use Entra instead?

Yes, **when you have a supported inbound token-acquisition path for your SRE Agent connector**. DAB supports native Entra JWT validation. That can reduce hosting to one official container.

Do not confuse three separate things:

| Capability | What it means |
|---|---|
| DAB managed identity to SQL | Outbound database authentication |
| DAB `EntraID` JWT validation | Inbound validation of a token acquired by a client |
| SRE Agent connector OAuth/managed identity | How the client actually acquires and renews that token |

The current [SRE Agent MCP connector documentation](https://learn.microsoft.com/azure/sre-agent/mcp-connectors#authentication) documents managed identity for stdio connectors and spec-compliant OAuth for remote connectors. **Do not assume every Streamable-HTTP connector can request a managed-identity token for an arbitrary DAB audience.** Check the options and supported behavior in your deployed SRE Agent.

For a supported remote managed-identity path, register an API, configure its token version/issuer/audience, create an application role such as `reader`, and assign that role to the **SRE Agent's** managed identity. Configure DAB entity permissions for `reader` and send `X-MS-API-ROLE: reader`. The role must be in the token; the header is not a grant of access.

The requested API resource and the token's actual `aud` are not necessarily identical strings. For v2 tokens the audience is commonly the API client GUID; validate the actual token claims locally without publishing the token. Follow [DAB Entra configuration](https://learn.microsoft.com/azure/data-api-builder/concept/security/authenticate-entra).

Selecting **OAuth** in the connector is not equivalent to configuring DAB JWT validation. Remote OAuth requires the server/identity architecture to support the MCP OAuth discovery and authorization flow expected by the client. Likewise, pasting a short-lived token into a header is a diagnostic test, not an unattended production renewal strategy.

Use the gateway baseline until the alternative is proven end to end. Keep SQL authentication independent of that inbound choice: a SQL-login backend can still sit behind an Entra-authenticated MCP endpoint.

<a id="s7"></a>
## 7. Connect this MCP to Azure SRE Agent

**Why it matters:** connecting the endpoint and selecting tools are two different steps.

The following steps use the API-key gateway deployed above. Portal wording can vary by release; the endpoint, transport and header do not.

1. Open **https://sre.azure.com** and select your SRE Agent.
2. Go to **Build + setup > Extensions > Connectors**.
3. Select **Add connector**, then **MCP Server** or **Add MCP server**.
4. Enter:

| Field | Value |
|---|---|
| **Name** | A meaningful name such as `orders-sql-diagnostics` |
| **Transport / connection type** | **Streamable-HTTP**, not stdio or legacy SSE |
| **URL** | The deployment's complete `https://<app-fqdn>/mcp` output |
| **Authentication** | **Custom headers**; if the UI separates these fields, choose **No authentication** and add the custom header below |
| **Header name** | `X-API-Key` |
| **Header value** | The protected value of `sql-mcp-api-key` |

Do not use the SQL hostname, the Container App root URL, a connection string or the Key Vault secret URI as the MCP endpoint/header value. **No authentication** in this UI means no client-generated authentication scheme; Caddy still checks the key.

5. Select **Add** and wait for **Connected**. If it fails, inspect the reported error before changing permissions.
6. In **Select tools**, or by choosing **Edit > MCP Tools** afterwards, select only:

| Tool | Use |
|---|---|
| `describe_entities` | Discover the approved diagnostic objects and their fields |
| `read_records` | Read the diagnostic views |
| `execute_entity` | Execute only the configured `ReadLocks` procedure |

7. Select **Done/Save**. The tools may appear with the connection name as a prefix. You do not need a custom agent merely to make them available in the main conversation.
8. Open a **new chat** and run this initial check:

> Use only the orders-sql-diagnostics connector. Describe its available entities, then read ConnectionInfo. Report the database name, actual database user, ObservedAtUtc, IsDbOwner, CanControlDatabase and CanCreateTable. Do not modify SQL or infer that a successful connection proves visibility of other sessions.

Expect the intended database and reader, a current UTC timestamp, and `0` for the three privilege checks. A null/unknown result needs explanation, not an assumption that it means denied. This is a useful check, not a complete permission audit.

**Azure Reader RBAC is not the security boundary for an external MCP tool.** Enforce read-only behavior in the database principal, DAB contract and selected tools. Review the agent's other connectors and native write tools separately; a read-only SQL connector does not make every capability of the agent read-only.

For the native-Entra alternative, replace the API-key fields with the supported token-acquisition method and `X-MS-API-ROLE: reader`, after validating the role assignment and token audience. Do not select that method simply because the database uses managed identity.

<a id="s8"></a>
## 8. Teach the agent the evidence map

**Why it matters:** a short map is better than hoping the agent guesses the right database and interprets every wait correctly.

Give the agent a small, nonsecret document containing the application-to-database mapping, connector name, telemetry workspaces, normal latency and operational ownership. Do not include passwords, API keys, fault-injection scripts or remediation credentials.

An example:

```text
The orders API uses OrdersDb on the primary SQL endpoint.
Use orders-sql-diagnostics for current SQL state.
Requests identifies waiting requests and their BlockingSessionId.
Sessions can show a sleeping blocker; sleeping does not mean harmless.
Transactions supplies the owner and start time of an open transaction.
ReadLocks supplies current grant/wait states.
ConnectionInfo checks the actual runtime database context.
Application dependency telemetry supplies SQL duration and timeout errors.
Azure/guest metrics supply capacity trends; MCP is not historical monitoring.
The operations team reviews and executes remediation.
```

Test with an investigation prompt:

> Investigate current orders API SQL timeouts. Use the SQL diagnostic connector and the application's dependency telemetry. Correlate waiting requests, their blocking sessions, open transactions and granted/waiting locks. Cite UTC timestamps and the evidence behind each claim. Distinguish confirmed findings from missing evidence. Do not kill sessions, change schema or data, restart services, or recommend a mitigation without explaining its impact.

Set a meaningful `Application Name` in application connection strings so `ProgramName` can identify workloads. It is a helpful client-provided label, not trustworthy authentication evidence.

Attach appropriate Azure Monitor alerts to an SRE Agent response plan through your existing incident process. **Adding an MCP connector does not create alerts or automatically start investigations.** Start with elevated dependency failures/latency and sustained resource pressure, and keep a human escalation path.

<a id="s9"></a>
## 9. Prove it with a disposable blocking test

**Why it matters:** "Connected" proves protocol connectivity, not permission to diagnose another SQL session.

Run this only in a **disposable pilot database named `SreMcpLab`**, configured with the same reader and connector contract. The guard intentionally rejects a production database. Your team performs the test; SRE Agent only reads it.

First, as an administrator, create a dedicated test object. An existing object causes a failure rather than being overwritten:

```sql
IF DB_NAME() <> N'SreMcpLab'
    THROW 51000, 'Use only the disposable SreMcpLab database.', 1;
IF OBJECT_ID(N'dbo.SreMcpProbe') IS NOT NULL
    THROW 51000, 'Test object already exists; inspect it before proceeding.', 1;
CREATE TABLE dbo.SreMcpProbe (Id int NOT NULL PRIMARY KEY, Value int NOT NULL);
INSERT dbo.SreMcpProbe (Id, Value) VALUES (1, 10);
```

Open two administrator/test-writer SQL sessions to **that same database**. Do not give the MCP reader write permission for the test.

**Session A: hold a transaction for two minutes, then roll it back.**

```sql
IF DB_NAME() <> N'SreMcpLab'
    THROW 51000, 'Use only the disposable SreMcpLab database.', 1;
IF @@TRANCOUNT > 0
    THROW 51000, 'Start with a session that has no existing transaction.', 1;
SELECT @@SPID AS BlockingSessionId;
BEGIN TRY
    BEGIN TRANSACTION;
    UPDATE dbo.SreMcpProbe SET Value = 11 WHERE Id = 1;
    WAITFOR DELAY '00:02:00';
    ROLLBACK TRANSACTION;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    THROW;
END CATCH;
```

**Session B: request a locking read while A is holding the update.**

```sql
IF DB_NAME() <> N'SreMcpLab'
    THROW 51000, 'Use only the disposable SreMcpLab database.', 1;
SELECT @@SPID AS WaitingSessionId;
SET LOCK_TIMEOUT 150000;
SELECT Value FROM dbo.SreMcpProbe WITH (READCOMMITTEDLOCK) WHERE Id = 1;
```

The explicit read-lock hint is confined to the disposable test. It makes the test useful even when read-committed snapshot isolation would otherwise allow a versioned read.

While B is waiting, ask the SRE Agent to investigate the two session IDs. It should show:

| Check | Required evidence |
|---|---|
| Waiting request | B appears in `Requests`, with a lock-related wait and A as its blocker |
| Owner | A appears in `Sessions`; it need not be sleeping in this WAITFOR test |
| Open transaction | `Transactions` associates A with its current transaction |
| Lock evidence | `ReadLocks` shows appropriate granted and waiting lock requests |
| Freshness | UTC observation timestamps correspond to the active test |
| Permissions | The actual MCP principal is not a database owner and has no approved business writes |

A result containing only the MCP connection's own session is a **failed visibility test**. Record this explicitly and revisit permissions. Also test a separate **sleeping transaction owner** in your controlled lab: have the test writer leave its transaction open without a running batch, then explicitly roll it back. Assign a human owner to that test; the automated WAITFOR rollback above is preferable for the first acceptance run.

**Do not just press Cancel in Session A.** A client cancellation can bypass `TRY/CATCH` and leave its transaction open. If the test is interrupted, run `IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;` in that same session, or disconnect the test connection and confirm rollback completed. The SRE Agent should not terminate the session.

After A rolls back, B should complete with `Value = 10`. Confirm no open test transaction remains. Close the test sessions, then remove only the known disposable table:

```sql
IF DB_NAME() <> N'SreMcpLab'
    THROW 51000, 'Use only the disposable SreMcpLab database.', 1;
DROP TABLE dbo.SreMcpProbe;
```

Additional acceptance checks:

- A missing or incorrect API key returns `401`, and no diagnostic rows.
- REST and GraphQL are not exposed; the public health response contains no diagnostic details.
- The three expected tools and five configured entities are available, with no arbitrary SQL or write tool.
- Your DBA verifies the reader cannot create/alter objects, update a representative workload table or act as an administrator, using the actual runtime identity/credentials. Do not substitute an admin connection as proof.
- The active revision runs the recorded image digests, and credential rotation/reconnection works.

If the narrow reader cannot meet the acceptance checks, the setup is not ready for the advertised investigation scope.

<a id="s10"></a>
## 10. Operate it safely: history, cost and troubleshooting

### Keep historical evidence

Query Store can help explain runtime and plan regressions. Check its current state, capture policy, retention and storage budget before changing it. It is not a historical archive of all blocking chains or deadlock graphs.

On SQL Server, appropriately configured Extended Events can retain deadlock and blocking evidence. A local `.xel` file is not automatically readable by SRE Agent or shipped by this MCP server. Azure SQL Database has different event/session options; do not assume SQL Server's instance-level `system_health` setup is portable. Configure approved collection or a narrowly reviewed historical-reader surface when needed.

For a VM, collect guest and SQL performance telemetry in addition to platform metrics. For Azure SQL, configure the diagnostic categories and destinations you actually use. Do not assume diagnostic settings automatically provide every SQL error or query detail.

### Keep the diagnostic service economical

One always-running replica consumes resources even between incidents. Budget for Container Apps, the gateway registry, Key Vault, logging, monitoring and SRE Agent usage. No figure in this article is a price guarantee.

Keep tool reads bounded and focused on the current database and incident. Sample repeated observations thoughtfully; avoid polling every session/lock every second. Monitor SQL overhead and MCP latency in the pilot. Add an appropriate logging destination for the Container Apps environment and retain operational logs without recording keys or sensitive payloads.

### Keep the boundary explicit

Use a separate endpoint/reader per approved scope rather than a tenant-wide administrator connection. Review SQL text, session labels and identifiers under your data-classification policy before expanding the contract.

For key/password rotation, update Key Vault, ensure the active replicas pick up the new environment values, update the connector's API key when required, reconnect and repeat an authenticated read. Updating a secret alone is not proof that a process's existing environment or connection pool refreshed. Coordinate rotation so the old credential can be retired after verification.

A single replica is a starter availability tradeoff. Secure public HTTPS is also an explicit architectural choice; it is not a requirement to expose the database publicly.

### Troubleshoot the failing layer

| Symptom | Check first |
|---|---|
| Connector returns `401` | Correct `/mcp` URL, custom-header name/value, gateway secret refresh |
| Native-Entra variant returns `401`/`403` | Supported token flow, issuer/audience/expiry, assigned role and `X-MS-API-ROLE` |
| Deployment cannot resolve Key Vault secrets | Host identity assignment, Secrets User scope, vault networking/DNS and secret URI |
| Gateway cannot pull its image | Registry login server, digest, host identity and AcrPull |
| Host is healthy but SQL reads fail | SQL DNS/routing/port, TLS trust, actual database user and object/DMV permissions |
| Only the reader's own session appears | Cross-session DMV visibility on the exact version/tier |
| Blocking evidence disappears | Transaction already ended, stale context, cached data or an incorrect database |
| Tool exists but chat cannot call it | Connector status and tool selection for the intended main/custom agent |
| New configuration seems ignored | Latest versus ready revision, mounted configuration and active image |
| Past incident cannot be explained | Missing historical telemetry; live MCP cannot reconstruct evidence never retained |

## Wrapping up

**You do not need to give an agent control of SQL to make its investigations useful. You need a safe, explicit route to the right evidence.**

The common MCP layer is the same for Azure SQL Database and SQL Server on a VM: Microsoft's package, a small approved diagnostic contract, a dedicated service identity and an authenticated connection from SRE Agent. The platform-specific work is in networking, identity support, state permissions and historical telemetry.

Start with one database and the disposable blocking test. Expand the contract only when a real investigation identifies missing evidence. If an agent cannot see a blocker, fix the evidence or document the limitation rather than granting it database-owner access.

An additional article is useful for **advanced SQL-specific evidence**--Query Store analysis, Extended Events, deadlocks, plan regressions and history collection--not for repeating the same MCP setup separately for each hosting platform.

---

### References

- [Microsoft SQL MCP Server overview](https://learn.microsoft.com/azure/data-api-builder/mcp/overview)
- [SQL MCP data-manipulation tools](https://learn.microsoft.com/azure/data-api-builder/mcp/data-manipulation-language-tools)
- [Configure DAB Microsoft Entra authentication](https://learn.microsoft.com/azure/data-api-builder/concept/security/authenticate-entra)
- [MCP connectors and authentication in Azure SRE Agent](https://learn.microsoft.com/azure/sre-agent/mcp-connectors)
- [Connect an MCP server and select tools in Azure SRE Agent](https://learn.microsoft.com/azure/sre-agent/mcp-connector)
- [Monitor Azure SQL Database with DMVs](https://learn.microsoft.com/azure/azure-sql/database/monitoring-with-dmvs)
- [Azure SQL Database logical-server roles](https://learn.microsoft.com/azure/azure-sql/database/security-server-roles)
- [SQL Server sys.dm_exec_requests](https://learn.microsoft.com/sql/relational-databases/system-dynamic-management-views/sys-dm-exec-requests-transact-sql)
- [SQL Server sys.dm_exec_sessions](https://learn.microsoft.com/sql/relational-databases/system-dynamic-management-views/sys-dm-exec-sessions-transact-sql)
- [SQL Server sys.dm_tran_locks](https://learn.microsoft.com/sql/relational-databases/system-dynamic-management-views/sys-dm-tran-locks-transact-sql)
- [Enable Entra authentication for SQL Server on Azure VMs](https://learn.microsoft.com/azure/azure-sql/virtual-machines/windows/configure-azure-ad-authentication-for-sql-vm)
- [Azure SQL connection architecture](https://learn.microsoft.com/azure/azure-sql/database/connectivity-architecture)
- [Container Apps networking](https://learn.microsoft.com/azure/container-apps/networking)
- [Container Apps secrets and Key Vault references](https://learn.microsoft.com/azure/container-apps/manage-secrets)
- [Understand and resolve SQL Server blocking](https://learn.microsoft.com/troubleshoot/sql/database-engine/performance/understand-resolve-blocking)
