#requires -Version 7.2
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateLength(1,128)][string]$Database,
    [Parameter(Mandatory)][ValidateLength(1,128)][string]$ReaderName,
    [ValidateSet('managed-identity','sql-login')][string]$SqlAuthentication = 'managed-identity'
)
. (Join-Path $PSScriptRoot 'Common.ps1')
$template = Get-Content -Raw (Join-Path $script:StarterRoot 'sql\setup.sql')
$template = $template.Replace('__DATABASE__', $Database.Replace("'", "''")).
    Replace('__READER__', $ReaderName.Replace("'", "''")).
    Replace('__AUTHENTICATION__', $SqlAuthentication)
$path = Write-PrivateText 'setup.sql' $template
Write-Host "DBA action: review $path and execute it in [$Database]."
Write-Host 'Azure SQL: connect as an approved Entra administrator for managed identity setup.'
Write-Host 'SQL VM: provision the dedicated login first; managed identity additionally needs configured SQL 2022+ Entra support.'
Write-Host 'This does not execute SQL. No administrator credential is sent to the MCP host.'
