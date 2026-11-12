-- Generated values must be reviewed by the DBA. Connect to the target database first.
-- No workload tables, credentials, or workload transactions are modified.
SET NOCOUNT ON;
SET XACT_ABORT ON;
DECLARE @ExpectedDatabase sysname = N'__DATABASE__';
DECLARE @Reader sysname = N'__READER__';
DECLARE @Authentication nvarchar(32) = N'__AUTHENTICATION__';
DECLARE @Engine int = CONVERT(int, SERVERPROPERTY('EngineEdition'));
DECLARE @Major int = CONVERT(int, SERVERPROPERTY('ProductMajorVersion'));
DECLARE @Command nvarchar(max);
IF DB_NAME() <> @ExpectedDatabase OR DB_NAME() IN (N'master', N'model', N'msdb', N'tempdb')
    THROW 51000, 'Connect to the intended user database before running setup.', 1;
IF @Engine <> 5 AND (@Engine = 8 OR @Major < 15)
    THROW 51001, 'This starter supports Azure SQL Database and SQL Server 2019 or later, not Managed Instance.', 1;
IF @Authentication NOT IN (N'managed-identity', N'sql-login')
    THROW 51002, 'Generate setup.sql using the installer; authentication is not configured.', 1;
IF SCHEMA_ID(N'sre_sql') IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM sys.extended_properties
    WHERE class = 3 AND major_id = SCHEMA_ID(N'sre_sql')
      AND name = N'SqlMcpStarter' AND CONVERT(nvarchar(128), value) = N'1')
    THROW 51003, 'An unrecognized sre_sql schema exists. Review it rather than overwriting it.', 1;
IF @Reader IN (N'dbo', N'guest', N'INFORMATION_SCHEMA', N'sys')
    THROW 51004, 'Use a dedicated non-administrator reader principal.', 1;

BEGIN TRANSACTION;
IF SCHEMA_ID(N'sre_sql') IS NULL
BEGIN
    EXEC(N'CREATE SCHEMA sre_sql AUTHORIZATION dbo;');
    EXEC sys.sp_addextendedproperty @name=N'SqlMcpStarter', @value=N'1',
        @level0type=N'SCHEMA', @level0name=N'sre_sql';
END;
IF DATABASE_PRINCIPAL_ID(@Reader) IS NULL
BEGIN
    IF @Authentication = N'managed-identity'
    BEGIN
        IF @Engine <> 5 AND @Major < 16
            THROW 51005, 'SQL Server managed identity requires configured Entra support on SQL Server 2022 or later.', 1;
        IF @Engine = 5
            SET @Command = N'CREATE USER ' + QUOTENAME(@Reader) + N' FROM EXTERNAL PROVIDER;';
        ELSE
            SET @Command = N'CREATE USER ' + QUOTENAME(@Reader) + N' FROM LOGIN ' + QUOTENAME(@Reader) + N';';
    END
    ELSE
        SET @Command = N'CREATE USER ' + QUOTENAME(@Reader) + N' FROM LOGIN ' + QUOTENAME(@Reader) + N';';
    EXEC sys.sp_executesql @Command;
END;
IF IS_ROLEMEMBER(N'db_owner', @Reader) = 1 OR EXISTS (
    SELECT 1 FROM sys.schemas WHERE principal_id = DATABASE_PRINCIPAL_ID(@Reader))
    THROW 51006, 'Reader is a database owner or owns a schema. Use a new dedicated principal.', 1;

EXEC(N'CREATE OR ALTER VIEW sre_sql.Requests AS
SELECT r.session_id AS SessionId, r.request_id AS RequestId,
       r.blocking_session_id AS BlockingSessionId, r.status AS Status,
       r.wait_type AS WaitType, r.wait_time AS WaitTimeMs, r.wait_resource AS WaitResource,
       r.cpu_time AS CpuTimeMs, r.total_elapsed_time AS ElapsedTimeMs,
       r.transaction_id AS TransactionId, SYSUTCDATETIME() AS ObservedAtUtc
FROM sys.dm_exec_requests AS r WHERE r.database_id = DB_ID();');
EXEC(N'CREATE OR ALTER VIEW sre_sql.Sessions AS
SELECT s.session_id AS SessionId, s.status AS Status,
       s.open_transaction_count AS OpenTransactionCount, s.program_name AS ProgramName,
       s.last_request_start_time AS LastRequestStartedAt,
       s.last_request_end_time AS LastRequestEndedAt, SYSUTCDATETIME() AS ObservedAtUtc
FROM sys.dm_exec_sessions AS s
WHERE s.is_user_process = 1 AND (s.database_id = DB_ID() OR EXISTS (
    SELECT 1 FROM sys.dm_exec_requests AS r
    WHERE r.database_id = DB_ID() AND r.blocking_session_id = s.session_id));');
EXEC(N'CREATE OR ALTER VIEW sre_sql.Transactions AS
SELECT DISTINCT st.session_id AS SessionId, st.transaction_id AS TransactionId,
       a.transaction_begin_time AS BeganAt, a.transaction_type AS TransactionType,
       a.transaction_state AS TransactionState, SYSUTCDATETIME() AS ObservedAtUtc
FROM sys.dm_tran_session_transactions AS st
JOIN sys.dm_tran_active_transactions AS a ON a.transaction_id = st.transaction_id
JOIN sys.dm_tran_database_transactions AS d ON d.transaction_id = st.transaction_id
WHERE d.database_id = DB_ID();');
EXEC(N'CREATE OR ALTER PROCEDURE sre_sql.ReadLocks @SessionId int = NULL AS
BEGIN
    SET NOCOUNT ON;
    SELECT request_session_id AS SessionId, resource_type AS ResourceType,
           resource_associated_entity_id AS ResourceEntityId,
           resource_description AS ResourceDescription, request_mode AS LockMode,
           request_status AS LockStatus, request_owner_type AS OwnerType,
           request_owner_id AS OwnerId, SYSUTCDATETIME() AS ObservedAtUtc
    FROM sys.dm_tran_locks WHERE resource_database_id = DB_ID()
      AND (@SessionId IS NULL OR request_session_id = @SessionId);
END;');
EXEC(N'CREATE OR ALTER VIEW sre_sql.ConnectionInfo AS
SELECT @@SPID AS SessionId, DB_NAME() AS DatabaseName, USER_NAME() AS DatabaseUser,
       IS_ROLEMEMBER(N''db_owner'') AS IsDbOwner,
       HAS_PERMS_BY_NAME(DB_NAME(), N''DATABASE'', N''CONTROL'') AS CanControlDatabase,
       HAS_PERMS_BY_NAME(DB_NAME(), N''DATABASE'', N''CREATE TABLE'') AS CanCreateTable,
       SYSUTCDATETIME() AS ObservedAtUtc;');

DECLARE @Grant nvarchar(max) = N'';
SELECT @Grant += N'GRANT SELECT, VIEW DEFINITION ON OBJECT::sre_sql.' + QUOTENAME(v.name)
    + N' TO ' + QUOTENAME(@Reader) + N';'
FROM (VALUES (N'Requests'), (N'Sessions'), (N'Transactions'), (N'ConnectionInfo')) AS v(name);
SET @Grant += N'GRANT EXECUTE, VIEW DEFINITION ON OBJECT::sre_sql.ReadLocks TO ' + QUOTENAME(@Reader) + N';';
EXEC(@Grant);
IF @Engine = 5
BEGIN
    SET @Command = N'GRANT VIEW DATABASE STATE TO ' + QUOTENAME(@Reader) + N';';
    EXEC sys.sp_executesql @Command;
END
ELSE
BEGIN
    -- Instance-wide diagnostic visibility: DBA approval is required.
    SET @Grant = N'USE master; GRANT '
        + CASE WHEN @Major >= 16 THEN N'VIEW SERVER PERFORMANCE STATE' ELSE N'VIEW SERVER STATE' END
        + N' TO ' + QUOTENAME(@Reader) + N';';
    EXEC(@Grant);
END;
COMMIT;
SELECT N'Diagnostic objects installed. Validate using the runtime reader identity.' AS SetupStatus;
IF @Engine = 5
    PRINT N'Azure SQL DMV visibility varies by tier. A successful setup does not prove cross-session visibility; run the documented visibility check.';
