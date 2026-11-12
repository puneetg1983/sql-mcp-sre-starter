#requires -Version 7.2
[CmdletBinding()]
param(
    [ValidateSet('ACA','Kubernetes','Docker')][string]$Hosting,
    [string]$ResourceGroup,
    [string]$Location,
    [ValidatePattern('^[a-z][a-z0-9-]{0,18}[a-z0-9]$')][string]$Name = 'sql-mcp',
    [string]$EnvironmentId = '',
    [string]$InfrastructureSubnetId = '',
    [string]$SqlServer,
    [ValidateLength(1,128)][string]$Database,
    [ValidateRange(1,65535)][int]$SqlPort = 1433,
    [ValidateSet('managed-identity','sql-login')][string]$SqlAuthentication = 'managed-identity',
    [ValidateLength(1,128)][string]$ReaderName,
    [string]$Hostname,
    [string]$TlsSecretName,
    [string]$IngressClass = 'nginx',
    [string]$WorkloadIdentityClientId = ''
)
. (Join-Path $PSScriptRoot 'Common.ps1')
if (-not $Hosting) {
    Write-Host '1. Azure Container Apps (recommended: managed HTTPS and hosting)'
    Write-Host '2. Existing Kubernetes / AKS (bring ingress, TLS and SQL networking)'
    Write-Host '3. Docker / Linux VM (bring an HTTPS reverse proxy and SQL networking)'
    $choice = Read-Host 'Choose 1, 2 or 3'
    $Hosting = switch ($choice) { '1' { 'ACA' } '2' { 'Kubernetes' } '3' { 'Docker' } default { throw 'Choose 1, 2 or 3.' } }
}
if (-not $PSBoundParameters.ContainsKey('SqlAuthentication')) {
    $default = if ($Hosting -eq 'ACA') { 'managed-identity' } else { 'sql-login' }
    $answer = Read-Host "SQL authentication: managed-identity or sql-login (Enter for $default)"
    $SqlAuthentication = if ($answer) { $answer } else { $default }
    if ($SqlAuthentication -notin @('managed-identity','sql-login')) { throw 'Choose managed-identity or sql-login.' }
}
if (-not $Database) { $Database = Read-Host 'Target database name' }
if ([string]::IsNullOrWhiteSpace($Database) -or $Database.Length -gt 128) { throw 'A database name of 1-128 characters is required.' }
$key = Get-ApiKey
$endpoint = ''
if ($Hosting -eq 'ACA') {
    $account = Invoke-AzJson @('account', 'show')
    Write-Host "Deploying into subscription $($account.name) [$($account.id)]. No SQL or firewall changes will be made."
    if (-not $ResourceGroup) { $ResourceGroup = Read-Host 'Deployment resource group (new or existing)' }
    if (-not $Location) { $Location = Read-Host 'Azure region (same as your existing environment, if used)' }
    if (-not $SqlServer) { $SqlServer = Read-Host 'SQL TLS hostname' }
    if ($SqlServer -notmatch '^[a-zA-Z0-9][a-zA-Z0-9.-]+$') { throw 'Use a SQL hostname, not a URL or connection string.' }
    if (-not $EnvironmentId -and -not $InfrastructureSubnetId) {
        $EnvironmentId = Read-Host 'Existing SQL-connected Container Apps environment resource ID (Enter to create one)'
        if (-not $EnvironmentId) {
            $InfrastructureSubnetId = Read-Host 'Approved dedicated subnet resource ID (Enter only for an approved public SQL path)'
            if (-not $InfrastructureSubnetId -and (Read-Host 'No private network will be configured. Type PUBLIC to confirm your SQL path is already approved') -cne 'PUBLIC') {
                throw 'Private SQL needs a connected environment or an approved delegated subnet.'
            }
        }
    }
    if ($EnvironmentId) {
        $environment = Invoke-AzJson @('resource', 'show', '--ids', $EnvironmentId)
        if ($environment.location.Replace(' ', '') -ine $Location.Replace(' ', '')) { throw 'Location must match the existing environment.' }
    }
    $password = ''
    if ($SqlAuthentication -eq 'sql-login') {
        if (-not $ReaderName) { $ReaderName = Read-Host 'Pre-provisioned dedicated SQL login name' }
        $password = Read-SecretText 'Dedicated reader SQL password (never an administrator)'
        if (-not $password) { throw 'A reader password is required for SQL-login mode.' }
    }
    $null = Invoke-AzJson @('group', 'create', '--name', $ResourceGroup, '--location', $Location)
    $parameters = @{
        '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
        contentVersion = '1.0.0.0'
        parameters = @{
            name = @{ value = $Name }; location = @{ value = $Location }
            environmentId = @{ value = $EnvironmentId }; infrastructureSubnetId = @{ value = $InfrastructureSubnetId }
            sqlServer = @{ value = $SqlServer }; sqlDatabase = @{ value = $Database }; sqlPort = @{ value = $SqlPort }
            sqlAuthentication = @{ value = $SqlAuthentication }; sqlUser = @{ value = "$ReaderName" }; sqlPassword = @{ value = $password }
            apiKey = @{ value = $key }
        }
    }
    $parameterFile = Write-PrivateText 'deploy.parameters.json' ($parameters | ConvertTo-Json -Depth 8)
    try {
        Write-Host 'Deploying the host (often several minutes; private environment creation can take longer)...'
        Write-Host 'SQL may remain unavailable until the DBA completes setup. Deployment success is not SQL readiness.'
        $deployment = Invoke-AzJson @('deployment', 'group', 'create', '--name', "$Name-starter", '--resource-group', $ResourceGroup,
            '--template-file', (Join-Path $script:StarterRoot 'infra\azuredeploy.json'), '--parameters', "@$parameterFile")
    } finally {
        Remove-Item -LiteralPath $parameterFile
    }
    $outputs = $deployment.properties.outputs
    $endpoint = $outputs.endpoint.value
    if ($SqlAuthentication -eq 'managed-identity') { $ReaderName = $outputs.readerName.value }
    Write-Host "HOST DEPLOYED: $endpoint"
} else {
    if (-not $ReaderName) { $ReaderName = Read-Host 'Dedicated reader principal name' }
    if ($Hosting -eq 'Kubernetes') {
        if (-not $Hostname) { $Hostname = Read-Host 'Existing HTTPS ingress hostname' }
        if (-not $TlsSecretName) { $TlsSecretName = Read-Host 'Existing TLS secret name in the sql-mcp namespace' }
        & (Join-Path $PSScriptRoot 'New-Kubernetes.ps1') -Hostname $Hostname -TlsSecretName $TlsSecretName -IngressClass $IngressClass -WorkloadIdentityClientId $WorkloadIdentityClientId
        $endpoint = "https://$Hostname/mcp"
    } else {
        $connection = Get-ReaderConnection
        $images = Get-Content -Raw (Join-Path $script:StarterRoot 'config\images.json') | ConvertFrom-Json
        $null = Write-PrivateText 'images.env' "DAB_IMAGE=$($images.dab)`nGATEWAY_IMAGE=$($images.gateway)`n"
        $null = Write-PrivateText 'runtime.env' "SQL_CONNECTION_STRING=$connection`n"
        $null = Write-PrivateText 'gateway.env' "MCP_API_KEY=$key`n"
        if (-not $Hostname) { $Hostname = Read-Host 'HTTPS hostname of your existing reverse proxy' }
        if ($Hostname -notmatch '^[a-zA-Z0-9][a-zA-Z0-9.-]+$') { throw 'Enter a DNS hostname, not a URL.' }
        $endpoint = "https://$Hostname/mcp"
        Write-Host 'Files prepared. After DBA setup, run from the repository root:'
        Write-Host 'docker compose --env-file .local/images.env up -d'
        Write-Host 'Docker Compose 2.30+ is required. Only 127.0.0.1:8080 is published.'
        Write-Host 'Configure your HTTPS reverse proxy to forward /mcp unchanged to http://127.0.0.1:8080.'
        Write-Host 'For managed identity, the VM must have the intended identity assigned; use its supported SQL connection string.'
    }
}
if ([string]::IsNullOrWhiteSpace($ReaderName) -or $ReaderName.Length -gt 128) { throw 'A reader name of 1-128 characters is required.' }
& (Join-Path $PSScriptRoot 'New-DatabaseSetup.ps1') -Database $Database -ReaderName $ReaderName -SqlAuthentication $SqlAuthentication
$null = Write-PrivateText 'connection.json' (@{ endpoint = $endpoint; database = $Database; reader = $ReaderName; hosting = $Hosting } | ConvertTo-Json)
Write-Host ''
Write-Host 'NEXT: DBA runs .local/setup.sql, then run: pwsh ./scripts/Test-Mcp.ps1'
Write-Host 'SRE connector: Streamable-HTTP; header X-API-Key; key is in protected .local/api-key.txt.'
Write-Host 'Not ready for investigation until verification succeeds. No secrets have been printed.'
