#requires -Version 7.2
[CmdletBinding()]
param(
    [uri]$Endpoint,
    [string]$Database,
    [string]$ReaderName,
    [string]$ApiKeyFile,
    [ValidateRange(1,32767)][int]$WitnessSessionId,
    [switch]$AllowLoopbackHttp
)
. (Join-Path $PSScriptRoot 'Common.ps1')
$handoffPath = Join-Path $script:StarterRoot '.local\connection.json'
if (Test-Path $handoffPath) {
    $handoff = Get-Content -Raw $handoffPath | ConvertFrom-Json
    if (-not $Endpoint) { $Endpoint = [uri]$handoff.endpoint }
    if (-not $Database) { $Database = $handoff.database }
    if (-not $ReaderName) { $ReaderName = $handoff.reader }
}
if (-not $Endpoint -or -not $Database -or -not $ReaderName) {
    throw 'Specify -Endpoint https://host/mcp -Database name -ReaderName principal, or run Install.ps1 first.'
}
if ($Endpoint.AbsolutePath.TrimEnd('/') -ne '/mcp' -or $Endpoint.UserInfo -or $Endpoint.Query -or $Endpoint.Fragment) {
    throw 'Use an MCP endpoint ending in /mcp, without credentials, query string or fragment.'
}
if ($Endpoint.Scheme -ne 'https' -and -not ($AllowLoopbackHttp -and $Endpoint.IsLoopback -and $Endpoint.Scheme -eq 'http')) {
    throw 'HTTPS with certificate validation is required. HTTP is allowed only for explicit loopback tests.'
}
if (-not $ApiKeyFile) { $ApiKeyFile = Join-Path $script:StarterRoot '.local\api-key.txt' }
if (Test-Path $ApiKeyFile) {
    $key = [System.IO.File]::ReadAllText((Resolve-Path $ApiKeyFile)).Trim()
} else {
    $key = Read-SecretText 'MCP API key (not the SQL password)'
}
if ($key -cnotmatch '^[A-Za-z0-9_-]{32,128}$') { throw 'Expected a 32-128 character URL-safe API key.' }
$handler = [System.Net.Http.HttpClientHandler]::new()
$handler.AllowAutoRedirect = $false
$client = [System.Net.Http.HttpClient]::new($handler)
$client.Timeout = [timespan]::FromSeconds(60)
$session = ''
$protocol = '2025-03-26'
$requestId = 0

function Send-Mcp([hashtable]$Payload, [string]$Credential = $key) {
    $request = [System.Net.Http.HttpRequestMessage]::new('POST', $Endpoint)
    $request.Headers.TryAddWithoutValidation('Accept', 'application/json, text/event-stream') | Out-Null
    if ($Credential) { $request.Headers.TryAddWithoutValidation('X-API-Key', $Credential) | Out-Null }
    if ($script:session) { $request.Headers.TryAddWithoutValidation('Mcp-Session-Id', $script:session) | Out-Null }
    $request.Headers.TryAddWithoutValidation('MCP-Protocol-Version', $script:protocol) | Out-Null
    $request.Content = [System.Net.Http.StringContent]::new(($Payload | ConvertTo-Json -Depth 20 -Compress),
        [System.Text.Encoding]::UTF8, 'application/json')
    try {
        $response = $client.SendAsync($request).GetAwaiter().GetResult()
        try {
            $code = [int]$response.StatusCode
            if ($code -ge 300 -and $code -lt 400) { throw 'Redirect rejected; API key was not forwarded.' }
            if ($response.Headers.Contains('Mcp-Session-Id')) {
                $script:session = @($response.Headers.GetValues('Mcp-Session-Id'))[0]
            }
            $text = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            return @{ Code = $code; Text = $text; Type = "$($response.Content.Headers.ContentType)" }
        } finally { $response.Dispose() }
    } finally { $request.Dispose() }
}

function Invoke-Mcp([string]$Method, [hashtable]$Parameters) {
    $script:requestId++
    $reply = Send-Mcp @{ jsonrpc = '2.0'; id = $script:requestId; method = $Method; params = $Parameters }
    if ($reply.Code -ne 200) { throw "MCP $Method failed (HTTP $($reply.Code)). Check SQL setup, container logs and credentials; no response body printed." }
    if ($reply.Type -like 'text/event-stream*') {
        $message = $null
        foreach ($event in ($reply.Text -split '\r?\n\r?\n')) {
            $data = (($event -split '\r?\n' | Where-Object { $_ -like 'data:*' }) |
                ForEach-Object { $_.Substring(5).TrimStart() }) -join "`n"
            if ($data) {
                $candidate = $data | ConvertFrom-Json
                if ($candidate.id -eq $script:requestId) { $message = $candidate }
            }
        }
        if (-not $message) { throw "MCP $Method returned no matching SSE response." }
    } else {
        $message = $reply.Text | ConvertFrom-Json
    }
    if ($message.id -ne $script:requestId -or $message.error -or -not $message.PSObject.Properties['result']) {
        throw "MCP $Method returned an invalid response or JSON-RPC error."
    }
    return $message.result
}

function Invoke-Tool([string]$Name, [hashtable]$Arguments) {
    $result = Invoke-Mcp 'tools/call' @{ name = $Name; arguments = $Arguments }
    if ($result.isError) { throw "Tool $Name reported an error. Inspect host logs using your approved process." }
    if ($result.structuredContent) { $data = $result.structuredContent }
    else {
        $texts = @($result.content | Where-Object { $_.type -eq 'text' })
        if ($texts.Count -ne 1) { throw "Tool $Name did not return one structured JSON result." }
        $data = $texts[0].text | ConvertFrom-Json
    }
    if ($data.status -and $data.status -ne 'success') { throw "Tool $Name did not report success." }
    return $data
}

try {
    $initialize = @{ jsonrpc = '2.0'; id = 0; method = 'initialize'; params = @{
        protocolVersion = $protocol; capabilities = @{}; clientInfo = @{ name = 'sql-mcp-starter-check'; version = '0.1.0' }
    } }
    foreach ($credential in @('', ('0' * 64))) {
        $denied = Send-Mcp $initialize $credential
        if ($denied.Code -ne 401) { throw "Missing or incorrect API key was not denied (HTTP $($denied.Code)). Do not connect this host." }
    }
    Write-Host 'PASS: missing and incorrect API keys rejected.'
    $started = Invoke-Mcp 'initialize' $initialize.params
    if (-not $started.protocolVersion) { throw 'Server did not negotiate an MCP protocol.' }
    $script:protocol = $started.protocolVersion
    $notification = Send-Mcp @{ jsonrpc = '2.0'; method = 'notifications/initialized' }
    if ($notification.Code -notin @(200,202,204)) { throw 'Server rejected the initialized notification.' }
    $tools = Invoke-Mcp 'tools/list' @{}
    $names = @($tools.tools | ForEach-Object { $_.name } | Sort-Object)
    if (($names -join ',') -ne 'describe_entities,execute_entity,read_records') {
        throw 'Tool allow-list mismatch. Expected only describe_entities, execute_entity and read_records.'
    }
    $metadata = Invoke-Tool 'describe_entities' @{}
    $entities = @($metadata.entities | ForEach-Object { $_.name } | Sort-Object)
    if (($entities -join ',') -ne 'ConnectionInfo,ReadLocks,Requests,Sessions,Transactions') { throw 'Diagnostic entity allow-list mismatch.' }
    $info = Invoke-Tool 'read_records' @{ entity = 'ConnectionInfo'; first = 1 }
    $rows = @($info.result.value)
    if ($rows.Count -ne 1 -or -not $rows[0]) { throw 'ConnectionInfo did not return one live identity row.' }
    $row = $rows[0]
    if ($row.DatabaseName -cne $Database -or $row.DatabaseUser -cne $ReaderName) { throw 'Runtime SQL database or principal differs from the expected reader.' }
    foreach ($permission in @('IsDbOwner','CanControlDatabase','CanCreateTable')) {
        if ($null -eq $row.$permission -or "$($row.$permission)" -ne '0') { throw "Reader permission $permission is elevated or unknown. Do not connect this host." }
    }
    $observed = if ($row.ObservedAtUtc -is [datetime]) {
        $timestamp = $row.ObservedAtUtc
        if ($timestamp.Kind -eq [DateTimeKind]::Unspecified) {
            $timestamp = [DateTime]::SpecifyKind($timestamp, [DateTimeKind]::Utc)
        }
        [DateTimeOffset]::new($timestamp.ToUniversalTime())
    } else {
        [DateTimeOffset]::Parse($row.ObservedAtUtc, [cultureinfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::AssumeUniversal)
    }
    if ([Math]::Abs(([DateTimeOffset]::UtcNow - $observed).TotalSeconds) -gt 120) { throw 'ConnectionInfo timestamp is not current.' }
    foreach ($entity in @('Requests','Sessions','Transactions')) {
        $read = Invoke-Tool 'read_records' @{ entity = $entity; first = 1000 }
        if (-not $read.PSObject.Properties['result'] -or -not $read.result.PSObject.Properties['value']) { throw "$entity returned no row collection." }
        if ($entity -eq 'Sessions' -and $WitnessSessionId -and -not @($read.result.value | Where-Object { $_.SessionId -eq $WitnessSessionId }).Count) {
            throw 'The independent witness session was not visible. Review tier-specific SQL state permissions.'
        }
    }
    $locks = Invoke-Tool 'execute_entity' @{ entity = 'ReadLocks'; parameters = @{} }
    if (-not $locks.PSObject.Properties['value']) { throw 'ReadLocks did not return its row collection.' }
    Write-Host "PASS: authenticated MCP discovery and all five diagnostic objects; runtime database [$Database], reader [$ReaderName]."
    Write-Host 'PASS: selected runtime owner/DDL checks denied. This is not a full inherited-permission audit.'
    if ($WitnessSessionId) {
        Write-Host 'PASS: independently identified workload session is visible. This does not certify every blocking-chain case.'
    } else {
        Write-Warning 'Cross-session visibility NOT verified. Follow docs/permissions.md before advertising full blocking diagnostics.'
    }
    Write-Host 'READY TO CONNECT: use docs/connect-sre-agent.md. Container health alone was not used as proof.'
} finally {
    $client.Dispose()
    $handler.Dispose()
}
