# DBA setup and visibility

Use a dedicated principal per database/deployment. Only a DBA runs setup. SRE Agent never receives the DBA connection.

`New-DatabaseSetup.ps1` produces one database-specific script, quoting database/principal literals. Review it before execution. It refuses system databases, SQL Managed Instance, pre-2019 SQL Server, and an existing unrecognized `sre_sql` schema. Repeat runs update only this starter's marked diagnostic schema.

## Azure SQL Database

For managed identity, configure an Entra administrator and connect as an approved administrator. The generated script creates a contained external user using the deployment's `readerName`; Entra directory lookup must be permitted and the name uniquely resolvable. Verify an existing principal maps to the intended identity rather than relying on its display name alone.

The script grants object-level SELECT/VIEW DEFINITION on four views, EXECUTE/VIEW DEFINITION on the lock reader, and VIEW DATABASE STATE. It does not grant db_owner, business-table reads, DDL, writes or KILL.

**This is not a universal cross-session permission recipe.** Azure SQL DMV visibility varies by DMV and service tier. Basic/S0/S1 and elastic pools can have additional restrictions. Review [Azure SQL DMVs](https://learn.microsoft.com/azure/azure-sql/database/monitoring-with-dmvs) and the specific DMV documentation. Logical-server diagnostic roles such as `##MS_ServerStateReader##` need an appropriately provisioned login in master, not merely a contained user, and broaden visibility. They are intentionally not auto-granted.

If your DBA cannot approve the required visibility, use approved collected telemetry and state that limitation. Do not run MCP as the SQL administrator.

SQL-login mode requires the DBA to provision the login through the organization's password policy, then map it in the target database. Never reuse an application writer or administrator.

## SQL Server on an Azure VM

The dedicated login must already exist before the generated script is run:

- SQL Server 2019: instance-level `VIEW SERVER STATE`.
- SQL Server 2022+: instance-level `VIEW SERVER PERFORMANCE STATE`.

The script chooses by engine version. These grants are **instance scoped**, even though published results are filtered to the selected database. Review that diagnostic disclosure. Signed modules are a separate DBA-designed option where narrower rights are mandatory; do not enable TRUSTWORTHY as a shortcut.

Managed identity additionally requires configured [Entra support on SQL Server 2022+ VMs](https://learn.microsoft.com/azure/azure-sql/virtual-machines/windows/configure-azure-ad-authentication-for-sql-vm). Running SQL on an Azure VM does not enable it automatically. For older engines or unconfigured Entra, use a dedicated SQL login.

## Prove cross-session visibility

After `Test-Mcp.ps1` passes its baseline checks:

1. In a separate approved SQL client, connect to the target database as a representative non-MCP principal. Run `SELECT @@SPID AS WitnessSessionId, DB_NAME() AS DatabaseName;` and keep that same physical connection open.
2. Run `pwsh ./scripts/Test-Mcp.ps1 -Endpoint 'https://<host>/mcp' -Database Orders -ReaderName '<reader>' -WitnessSessionId 123`, replacing 123 with that actual session ID.
3. Keep the witness connection open until verification completes. Close it afterwards. No table, lock or transaction is created by this check.

The verifier requires that independent session in Sessions. A successful discovery, health response or empty requests list is not accepted as that proof. Session IDs are reused, so perform the check immediately and verify the intended database/client.

This confirms one independent session is visible; it is **not** a full blocking/transaction visibility certification. Before production, run a DBA-approved disposable two-session blocking test on a non-production database and correlate owner, waiter, transaction and lock. Do not deliberately block workload tables. Cancellation can leave a transaction open: explicitly roll back or disconnect, then verify cleanup. See the [advanced reference](advanced-reference.md).

## Boundaries

No raw SQL text or login names are published by default. Program names, wait resources and database identity can still be sensitive. Read-only does not mean non-sensitive.

ConnectionInfo checks only db_owner, database CONTROL and CREATE TABLE; it is not a complete inherited-grant audit. Review server roles, database roles, direct/inherited object grants and ownership. SQL grants, the DAB allow-list and gateway authentication are separate boundaries.
