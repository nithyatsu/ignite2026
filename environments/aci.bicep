extension radius

param subscriptionId string

param azureResourceGroup string = 'nsi-aci'

@description('resource-types-contrib commit the ACI recipes are pinned to. 0.61.0/latest names Azure resources by resource group only, so two containers resources in one group collide.')
param aciRecipesVersion string = '9f5f20a6b3c2b624e21d9e1a429b08bd109961d0'

resource votingAciRecipePack 'Radius.Core/recipePacks@2025-08-01-preview' = {
  name: 'voting-aci'
  location: 'global'
  properties: {
    recipes: {
      'Radius.Compute/containers': {
        kind: 'bicep'
        source: 'ghcr.io/radius-project/azure-aci-recipes/containers:${aciRecipesVersion}'
        parameters: {
          desiredCount: 1
        }
      }
      'Radius.Compute/persistentVolumes': {
        kind: 'bicep'
        source: 'ghcr.io/radius-project/azure-aci-recipes/persistentvolumes:${aciRecipesVersion}'
      }
      'Radius.Security/secrets': {
        kind: 'bicep'
        source: 'ghcr.io/radius-project/azure-aci-recipes/secrets:${aciRecipesVersion}'
      }
      'Radius.Data/postgreSqlDatabases': {
        kind: 'bicep'
        source: 'mcr.microsoft.com/bicep/avm/res/db-for-postgre-sql/flexible-server:0.15.2'
        parameters: {
          name: 'pgsql-{{context.azure.resourceNameHash}}'
          administratorLogin: '{{context.resource.properties.username}}'
          administratorLoginPassword: '{{context.resource.properties.password}}'
          authConfig: {
            activeDirectoryAuth: 'Enabled'
            passwordAuth: 'Enabled'
          }
          skuName: 'Standard_D2ds_v5'
          tier: 'GeneralPurpose'
          databases: [
            {
              name: '{{context.resource.properties.database}}'
            }
          ]
          version: '16'
          availabilityZone: -1
          highAvailability: 'Disabled'
          geoRedundantBackup: 'Disabled'
          storageSizeGB: 32
          publicNetworkAccess: 'Enabled'
          firewallRules: [
            {
              name: 'allow-all'
              startIpAddress: '0.0.0.0'
              endIpAddress: '255.255.255.255'
            }
          ]
          enableAdvancedThreatProtection: false
          enableTelemetry: false
          lock: {
            kind: 'None'
          }
          configurations: [
            {
              name: 'require_secure_transport'
              source: 'user-override'
              value: '{{context.resource.properties.tls == "optional" ? "OFF" : "ON"}}'
            }
          ]
        }
        outputs: {
          host: 'fqdn'
        }
      }
    }
  }
}

resource aciEnvironment 'Radius.Core/environments@2025-08-01-preview' = {
  name: 'aci'
  location: 'global'
  properties: {
    providers: {
      kubernetes: {
        namespace: 'voting-aci'
      }
      azure: {
        subscriptionId: subscriptionId
        resourceGroupName: azureResourceGroup
      }
    }
    recipePacks: [
      votingAciRecipePack.id
    ]
  }
}
