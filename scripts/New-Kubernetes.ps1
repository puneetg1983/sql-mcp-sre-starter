#requires -Version 7.2
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[a-z0-9][a-z0-9.-]+$')][string]$Hostname,
    [Parameter(Mandatory)][ValidatePattern('^[a-z0-9][a-z0-9.-]*$')][string]$TlsSecretName,
    [ValidatePattern('^[a-z0-9][a-z0-9.-]*$')][string]$IngressClass = 'nginx',
    [ValidatePattern('^[a-z0-9][a-z0-9-]*$')][string]$Namespace = 'sql-mcp',
    [string]$WorkloadIdentityClientId = '',
    [string]$ConnectionStringFile
)
. (Join-Path $PSScriptRoot 'Common.ps1')
$connection = Get-ReaderConnection $ConnectionStringFile
$key = Get-ApiKey
$images = Get-Content -Raw (Join-Path $script:StarterRoot 'config\images.json') | ConvertFrom-Json
$labels = @{ app = 'sql-mcp' }
$serviceAccount = @{ apiVersion = 'v1'; kind = 'ServiceAccount'; metadata = @{ name = 'sql-mcp'; namespace = $Namespace } }
$podLabels = @{ app = 'sql-mcp' }
if ($WorkloadIdentityClientId) {
    $null = [guid]::Parse($WorkloadIdentityClientId)
    $serviceAccount.metadata.annotations = @{ 'azure.workload.identity/client-id' = $WorkloadIdentityClientId }
    $podLabels['azure.workload.identity/use'] = 'true'
}
$resources = @(
    @{ apiVersion = 'v1'; kind = 'Namespace'; metadata = @{ name = $Namespace } },
    $serviceAccount,
    @{
        apiVersion = 'v1'; kind = 'ConfigMap'; metadata = @{ name = 'sql-mcp'; namespace = $Namespace }
        data = @{
            'dab-config.json' = Get-Content -Raw (Join-Path $script:StarterRoot 'config\dab-config.json')
            'Caddyfile' = Get-Content -Raw (Join-Path $script:StarterRoot 'config\Caddyfile')
        }
    },
    @{
        apiVersion = 'v1'; kind = 'Secret'; metadata = @{ name = 'sql-mcp'; namespace = $Namespace }
        type = 'Opaque'; stringData = @{ SQL_CONNECTION_STRING = $connection; MCP_API_KEY = $key }
    },
    @{
        apiVersion = 'apps/v1'; kind = 'Deployment'; metadata = @{ name = 'sql-mcp'; namespace = $Namespace }
        spec = @{
            replicas = 1; strategy = @{ type = 'Recreate' }; selector = @{ matchLabels = $labels }
            template = @{
                metadata = @{ labels = $podLabels }
                spec = @{
                    serviceAccountName = 'sql-mcp'
                    securityContext = @{ runAsNonRoot = $true; fsGroup = 1654; seccompProfile = @{ type = 'RuntimeDefault' } }
                    containers = @(
                        @{
                            name = 'dab'; image = $images.dab
                            args = @('--ConfigFileName', '/etc/sqlmcp/dab-config.json')
                            securityContext = @{ runAsUser = 1654; allowPrivilegeEscalation = $false; capabilities = @{ drop = @('ALL') } }
                            env = @(
                                @{ name = 'SQL_CONNECTION_STRING'; valueFrom = @{ secretKeyRef = @{ name = 'sql-mcp'; key = 'SQL_CONNECTION_STRING' } } },
                                @{ name = 'ASPNETCORE_URLS'; value = 'http://127.0.0.1:5000' },
                                @{ name = 'DOTNET_EnableDiagnostics'; value = '0' }
                            )
                            resources = @{ requests = @{ cpu = '250m'; memory = '512Mi' }; limits = @{ cpu = '1'; memory = '1Gi' } }
                            volumeMounts = @(@{ name = 'config'; mountPath = '/etc/sqlmcp'; readOnly = $true })
                        },
                        @{
                            name = 'gateway'; image = $images.gateway
                            command = @('caddy'); args = @('run', '--config', '/etc/sqlmcp/Caddyfile', '--adapter', 'caddyfile')
                            securityContext = @{ runAsUser = 10001; allowPrivilegeEscalation = $false; capabilities = @{ drop = @('ALL') } }
                            env = @(@{ name = 'MCP_API_KEY'; valueFrom = @{ secretKeyRef = @{ name = 'sql-mcp'; key = 'MCP_API_KEY' } } })
                            ports = @(@{ containerPort = 8080; name = 'http' })
                            readinessProbe = @{ httpGet = @{ path = '/health'; port = 8080 }; periodSeconds = 10 }
                            resources = @{ requests = @{ cpu = '100m'; memory = '64Mi' }; limits = @{ cpu = '500m'; memory = '256Mi' } }
                            volumeMounts = @(@{ name = 'config'; mountPath = '/etc/sqlmcp'; readOnly = $true })
                        }
                    )
                    volumes = @(@{ name = 'config'; configMap = @{ name = 'sql-mcp' } })
                }
            }
        }
    },
    @{
        apiVersion = 'v1'; kind = 'Service'; metadata = @{ name = 'sql-mcp'; namespace = $Namespace }
        spec = @{ type = 'ClusterIP'; selector = $labels; ports = @(@{ port = 8080; targetPort = 8080 }) }
    },
    @{
        apiVersion = 'networking.k8s.io/v1'; kind = 'Ingress'
        metadata = @{ name = 'sql-mcp'; namespace = $Namespace }
        spec = @{
            ingressClassName = $IngressClass
            tls = @(@{ hosts = @($Hostname); secretName = $TlsSecretName })
            rules = @(@{
                host = $Hostname
                http = @{ paths = @(@{
                    path = '/mcp'; pathType = 'Prefix'
                    backend = @{ service = @{ name = 'sql-mcp'; port = @{ number = 8080 } } }
                }) }
            })
        }
    }
)
$path = Write-PrivateText 'kubernetes.json' (@{ apiVersion = 'v1'; kind = 'List'; items = $resources } | ConvertTo-Json -Depth 40)
Write-Host "Generated $path. Contains credentials: do not commit, attach or share it."
Write-Host "After DBA setup and TLS/ingress provisioning: kubectl apply -f `"$path`""
Write-Host "Endpoint: https://$Hostname/mcp"
Write-Host 'For AKS workload identity, configure the cluster OIDC issuer and federated credential before applying.'
