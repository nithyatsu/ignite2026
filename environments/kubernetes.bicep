extension radius

@description('kube-recipes tag. Pinned because :latest moves with every release.')
param kubeRecipesVersion string = '0.61.0'

resource votingKubernetesRecipePack 'Radius.Core/recipePacks@2025-08-01-preview' = {
  name: 'voting-kubernetes'
  location: 'global'
  properties: {
    recipes: {
      'Radius.Compute/containers': {
        kind: 'bicep'
        source: 'ghcr.io/radius-project/kube-recipes/containers:${kubeRecipesVersion}'
      }
      'Radius.Compute/persistentVolumes': {
        kind: 'bicep'
        source: 'ghcr.io/radius-project/kube-recipes/persistentvolumes:${kubeRecipesVersion}'
      }
      'Radius.Security/secrets': {
        kind: 'bicep'
        source: 'ghcr.io/radius-project/kube-recipes/secrets:${kubeRecipesVersion}'
      }
      'Radius.Data/postgreSqlDatabases': {
        kind: 'bicep'
        source: 'ghcr.io/radius-project/kube-recipes/postgresqldatabases:${kubeRecipesVersion}'
      }
    }
  }
}

resource kubernetesEnvironment 'Radius.Core/environments@2025-08-01-preview' = {
  name: 'kubernetes'
  location: 'global'
  properties: {
    providers: {
      kubernetes: {
        namespace: 'voting-k8s'
      }
    }
    recipePacks: [
      votingKubernetesRecipePack.id
    ]
  }
}
