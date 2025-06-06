targetScope = 'resourceGroup'

// ------------------
//    PARAMETERS
// ------------------

@description('The location where the resources will be created.')
param location string = resourceGroup().location

@description('The name of the container registry.')
param containerRegistryName string

@description('Optional. The tags to be assigned to the created resources.')
param tags object = {}

@description('Required. Whether to enable deplotment telemetry.')
param enableTelemetry bool

@description('Optional. The resource ID of the Hub Virtual Network.')
param hubVNetResourceId string = ''

@description('The resource ID of the VNet to which the private endpoint will be connected.')
param spokeVNetResourceId string

@description('The resource id of the subnet in the VNet to which the private endpoint will be connected.')
param spokePrivateEndpointSubnetResourceId string

@description('Optional. The name of the private endpoint to be created for Azure Container Registry. If left empty, it defaults to "<resourceName>-pep')
param containerRegistryPrivateEndpointName string = 'acr-pep'

@description('The name of the user assigned identity to be created to pull image from Azure Container Registry.')
param containerRegistryUserAssignedIdentityName string

@description('Required. Resource ID of the diagnostic log analytics workspace.')
param diagnosticWorkspaceId string

@description('Optional, default value is true. If true, any resources that support AZ will be deployed in all three AZ. However if the selected region is not supporting AZ, this parameter needs to be set to false.')
param deployZoneRedundantResources bool = true

@description('Optional. Deploy the agent pool for the container registry. Default value is true.')
param deployAgentPool bool = true

// ------------------
// VARIABLES
// ------------------

var acrDnsZoneName = 'privatelink.azurecr.io'
var containerRegistryPullRoleGuid = '7f951dda-4ed3-4680-a7ca-43fe172d538d'
var virtualNetworkLinks = concat(
  [
    {
      virtualNetworkResourceId: spokeVNetResourceId
      registrationEnabled: false
    }
  ],
  (!empty(hubVNetResourceId))
    ? [
        {
          virtualNetworkResourceId: hubVNetResourceId
          registrationEnabled: false
        }
      ]
    : []
)
// ------------------
// RESOURCES
// ------------------
module acrUserAssignedIdentity 'br/public:avm/res/managed-identity/user-assigned-identity:0.4.0' = {
  name: containerRegistryUserAssignedIdentityName
  params: {
    name: containerRegistryUserAssignedIdentityName
    location: location
    tags: tags
    enableTelemetry: enableTelemetry
  }
}

module acrdnszone 'br/public:avm/res/network/private-dns-zone:0.7.0' = {
  name: 'acrDnsZoneDeployment-${uniqueString(resourceGroup().id)}'
  params: {
    name: acrDnsZoneName
    location: 'global'
    tags: tags
    enableTelemetry: enableTelemetry
    virtualNetworkLinks: virtualNetworkLinks
  }
}

module acr 'br/public:avm/res/container-registry/registry:0.6.0' = {
  name: 'containerRegistry-${uniqueString(resourceGroup().id)}'
  params: {
    name: containerRegistryName
    location: location
    tags: tags
    enableTelemetry: enableTelemetry
    acrSku: 'Premium'
    publicNetworkAccess: 'Disabled'
    acrAdminUserEnabled: false
    networkRuleBypassOptions: 'AzureServices'
    zoneRedundancy: deployZoneRedundantResources ? 'Enabled' : 'Disabled'
    trustPolicyStatus: 'enabled'
    diagnosticSettings: [
      {
        name: 'acr-log-analytics'
        logCategoriesAndGroups: [
          {
            categoryGroup: 'allLogs'
          }
        ]
        metricCategories: [
          {
            category: 'AllMetrics'
          }
        ]
        workspaceResourceId: diagnosticWorkspaceId
      }
    ]
    privateEndpoints: [
      {
        name: containerRegistryPrivateEndpointName
        privateDnsZoneGroup: {
          privateDnsZoneGroupConfigs: [
            {
              privateDnsZoneResourceId: acrdnszone.outputs.resourceId
            }
          ]
        }
        subnetResourceId: spokePrivateEndpointSubnetResourceId
      }
    ]
    quarantinePolicyStatus: 'enabled'
    roleAssignments: [
      {
        principalId: acrUserAssignedIdentity.outputs.principalId
        principalType: 'ServicePrincipal'
        roleDefinitionIdOrName: containerRegistryPullRoleGuid
      }
    ]
    softDeletePolicyDays: 7
    softDeletePolicyStatus: 'disabled'
  }
}

resource agentPool 'Microsoft.ContainerRegistry/registries/agentPools@2019-06-01-preview' = if (deployAgentPool) {
  name: '${containerRegistryName}/agentpool'
  location: location
  properties: {
    count: 2
    virtualNetworkSubnetResourceId: spokePrivateEndpointSubnetResourceId
    os: 'Linux'
    tier: 'S2'
  }
  dependsOn: [acr]
}

// ------------------
// OUTPUTS
// ------------------

@description('The resource ID of the container registry.')
output containerRegistryId string = acr.outputs.resourceId

@description('The name of the container registry.')
output containerRegistryName string = acr.outputs.name

@description('The name of the container registry login server.')
output containerRegistryLoginServer string = acr.outputs.loginServer

@description('The name of the internal agent pool for the container registry.')
output containerRegistryAgentPoolName string = (deployAgentPool) ? agentPool.name : ''

@description('The resource ID of the user assigned managed identity for the container registry to be able to pull images from it.')
output containerRegistryUserAssignedIdentityId string = acrUserAssignedIdentity.outputs.resourceId
