$ErrorActionPreference = 'Stop'
$script:StarterRoot = Split-Path $PSScriptRoot -Parent

function Get-LocalDirectory {
    $path = Join-Path $script:StarterRoot '.local'
    if (-not (Test-Path $path)) { New-Item -ItemType Directory -Path $path | Out-Null }
    if ($IsWindows) {
        $acl = Get-Acl -LiteralPath $path
        $acl.SetAccessRuleProtection($true, $false)
        foreach ($rule in @($acl.Access)) { $null = $acl.RemoveAccessRuleSpecific($rule) }
        $user = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
        $acl.SetOwner($user)
        foreach ($sid in @($user, [System.Security.Principal.SecurityIdentifier]::new('S-1-5-18'))) {
            $rule = [System.Security.AccessControl.FileSystemAccessRule]::new(
                $sid, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
            $acl.AddAccessRule($rule)
        }
        [System.IO.FileSystemAclExtensions]::SetAccessControl([System.IO.DirectoryInfo]::new($path), $acl)
    } else {
        & chmod 700 -- $path
        if ($LASTEXITCODE -ne 0) { throw 'Could not protect .local directory.' }
    }
    return $path
}

function Write-PrivateText([string]$Name, [string]$Text) {
    $path = Join-Path (Get-LocalDirectory) $Name
    [System.IO.File]::WriteAllText($path, $Text, [System.Text.UTF8Encoding]::new($false))
    if (-not $IsWindows) {
        & chmod 600 -- $path
        if ($LASTEXITCODE -ne 0) { throw "Could not protect $Name." }
    }
    return $path
}

function Read-SecretText([string]$Prompt) {
    $value = Read-Host $Prompt -AsSecureString
    return [System.Net.NetworkCredential]::new('', $value).Password
}

function Get-ApiKey {
    $path = Join-Path (Get-LocalDirectory) 'api-key.txt'
    if (Test-Path $path) {
        $key = [System.IO.File]::ReadAllText($path).Trim()
    } else {
        $key = [Convert]::ToHexString([System.Security.Cryptography.RandomNumberGenerator]::GetBytes(32)).ToLowerInvariant()
        $null = Write-PrivateText 'api-key.txt' $key
    }
    if ($key -cnotmatch '^[A-Za-z0-9_-]{32,128}$') { throw 'API key must be 32-128 URL-safe characters.' }
    return $key
}

function Get-ReaderConnection([string]$ConnectionStringFile = '') {
    $value = if ($ConnectionStringFile) {
        [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $ConnectionStringFile)).TrimEnd("`r", "`n")
    } else {
        Read-SecretText 'Dedicated reader connection string (never an administrator)'
    }
    if ($value -match '[\r\n]') { throw 'Connection string must be one line.' }
    $builder = [System.Data.Common.DbConnectionStringBuilder]::new()
    $builder.set_ConnectionString($value)
    if (-not $builder.ContainsKey('Encrypt') -or "$($builder['Encrypt'])" -notin @('true', 'mandatory', 'strict')) {
        throw 'Connection string must explicitly specify Encrypt=True (or Mandatory/Strict).'
    }
    if (-not $builder.ContainsKey('TrustServerCertificate') -or "$($builder['TrustServerCertificate'])" -ne 'false') {
        throw 'Connection string must explicitly specify TrustServerCertificate=False.'
    }
    return $value
}

function Invoke-AzJson([string[]]$Arguments) {
    $output = & az @Arguments --only-show-errors --output json
    if ($LASTEXITCODE -ne 0) { throw "Azure CLI failed: $($Arguments[0..1] -join ' '). Review the Azure error above." }
    return ($output -join "`n") | ConvertFrom-Json
}
