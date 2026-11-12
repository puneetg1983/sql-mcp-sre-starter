targetScope = 'resourceGroup'

@description('Use the same region as an existing Container Apps environment, if supplied.')
param location string = resourceGroup().location
@minLength(2)
@maxLength(20)
param name string = 'sql-mcp'
@description('Existing environment resource ID, or leave empty to create one.')
param environmentId string = ''
@description('For a new environment: approved dedicated, delegated subnet ID with SQL connectivity. Leave empty only for an approved public SQL path.')
param infrastructureSubnetId string = ''
@description('Normal TLS SQL hostname, not a private IP or connection string.')
param sqlServer string
param sqlDatabase string
@minValue(1)
@maxValue(65535)
param sqlPort int = 1433
@allowed(['managed-identity', 'sql-login'])
param sqlAuthentication string = 'managed-identity'
@description('SQL-login mode only: pre-provisioned dedicated reader login. Never use an administrator.')
param sqlUser string = ''
@description('SQL-login mode only: dedicated reader password. TLS encryption and certificate verification are always enabled.')
@secure()
param sqlPassword string = ''
@description('Keep in your password manager; use at least 32 random URL-safe characters. Sent by SRE Agent as X-API-Key.')
@secure()
@minLength(32)
@maxLength(128)
param apiKey string

var images = loadJsonContent('../config/images.json')
var suffix = uniqueString(resourceGroup().id, name)
var config = string(loadJsonContent('../config/dab-config.json'))
var gatewayConfig = loadTextContent('../config/Caddyfile')
var readerName = '${name}-reader-${suffix}'

resource reader 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: readerName
  location: location
}
resource environment 'Microsoft.App/managedEnvironments@2025-01-01' = if (empty(environmentId)) {
  name: '${name}-env'
  location: location
  properties: {
    workloadProfiles: [{ name: 'Consumption', workloadProfileType: 'Consumption' }]
    appLogsConfiguration: { destination: 'azure-monitor' }
    vnetConfiguration: empty(infrastructureSubnetId) ? null : {
      infrastructureSubnetId: infrastructureSubnetId
      internal: false
    }
  }
}
resource app 'Microsoft.App/containerApps@2025-01-01' = {
  name: name
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${reader.id}': {} }
  }
  properties: {
    managedEnvironmentId: empty(environmentId) ? environment!.id : environmentId
    workloadProfileName: 'Consumption'
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: { external: true, allowInsecure: false, targetPort: 8080, transport: 'auto' }
      secrets: [
        { name: 'mcp-api-key', value: apiKey }
        { name: 'dab-config', value: config }
        { name: 'gateway-config', value: gatewayConfig }
        {
          name: 'sql-connection'
          value: sqlAuthentication == 'managed-identity'
            ? 'Server="tcp:${replace(sqlServer, '"', '""')},${sqlPort}";Database="${replace(sqlDatabase, '"', '""')}";Encrypt=True;TrustServerCertificate=False;Authentication=Active Directory Managed Identity;User Id=${reader.properties.clientId};Application Name=SqlMcp.Diagnostics;'
            : 'Server="tcp:${replace(sqlServer, '"', '""')},${sqlPort}";Database="${replace(sqlDatabase, '"', '""')}";Encrypt=True;TrustServerCertificate=False;User ID="${replace(sqlUser, '"', '""')}";Password="${replace(sqlPassword, '"', '""')}";Application Name=SqlMcp.Diagnostics;'
        }
      ]
    }
    template: {
      containers: [
        {
          name: 'gateway'
          image: images.gateway
          command: ['caddy']
          args: ['run', '--config', '/etc/caddy/Caddyfile', '--adapter', 'caddyfile']
          env: [{ name: 'MCP_API_KEY', secretRef: 'mcp-api-key' }]
          volumeMounts: [{ volumeName: 'gateway-config', mountPath: '/etc/caddy' }]
          resources: { cpu: json('0.25'), memory: '0.5Gi' }
        }
        {
          name: 'dab'
          image: images.dab
          args: ['--ConfigFileName', '/config/dab-config.json']
          env: [
            { name: 'SQL_CONNECTION_STRING', secretRef: 'sql-connection' }
            { name: 'ASPNETCORE_URLS', value: 'http://127.0.0.1:5000' }
            { name: 'DOTNET_EnableDiagnostics', value: '0' }
          ]
          volumeMounts: [{ volumeName: 'dab-config', mountPath: '/config' }]
          resources: { cpu: json('0.5'), memory: '1Gi' }
        }
      ]
      volumes: [
        { name: 'dab-config', storageType: 'Secret', secrets: [{ secretRef: 'dab-config', path: 'dab-config.json' }] }
        { name: 'gateway-config', storageType: 'Secret', secrets: [{ secretRef: 'gateway-config', path: 'Caddyfile' }] }
      ]
      scale: { minReplicas: 1, maxReplicas: 1 }
    }
  }
}
output endpoint string = 'https://${app.properties.configuration.ingress.fqdn}/mcp'
output readerName string = sqlAuthentication == 'managed-identity' ? reader.name : sqlUser
output readerClientId string = reader.properties.clientId
output readerPrincipalId string = reader.properties.principalId
output appId string = app.id
output nextStep string = 'Run scripts/New-DatabaseSetup.ps1 with the database, readerName above and -SqlAuthentication ${sqlAuthentication}. Then run scripts/Test-Mcp.ps1. Host deployment is not SQL readiness.'
