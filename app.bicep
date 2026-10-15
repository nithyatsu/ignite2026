extension radius

param environment string

@description('Tag of the vote/result/worker images. Default is the amd64 build used by ACI and the CCE policy; use the -arm64 tag on Apple Silicon kind.')
param imageTag string = '047c81d1f93c53cad6074db9ad525bf37a541178'

@secure()
param postgresPassword string

@description('Redis sidecar image. Default is the amd64 mirror pinned in the CCE policy.')
param redisImage string = 'ghcr.io/nithyatsu/redis@sha256:ca0acbb137c1dc3339c8b147a58fd6f42775d4599327b50e7b116c23de501af2'

resource votingApp 'Radius.Core/applications@2025-08-01-preview' = {
  name: 'example-voting-app'
  properties: {
    environment: environment
  }
}

resource postgresDb 'Radius.Data/postgreSqlDatabases@2025-08-01-preview' = {
  name: 'db'
  properties: {
    environment: environment
    application: votingApp.id
    username: 'myadmin'
    password: postgresPassword
    database: 'votes'
    size: 'S'
    codeReference: 'https://github.com/nithyatsu/example-voting-app/blob/main/result/server.js#L23'
  }
}

resource voteContainer 'Radius.Compute/containers@2025-08-01-preview' = {
  name: 'vote'
  properties: {
    environment: environment
    application: votingApp.id
    containers: {
      redis: {
        image: redisImage
      }
      vote: {
        image: 'ghcr.io/nithyatsu/example-voting-app-vote:${imageTag}'
        ports: {
          web: {
            containerPort: 80
          }
        }
        env: {
          REDIS_HOST: {
            value: 'localhost'
          }
          REDIS_PORT: {
            value: '6379'
          }
        }
      }
      worker: {
        image: 'ghcr.io/nithyatsu/example-voting-app-worker:${imageTag}'
        env: {
          REDIS_HOST: {
            value: 'localhost'
          }
          REDIS_PORT: {
            value: '6379'
          }
          POSTGRES_HOST: {
            value: postgresDb.properties.host
          }
          POSTGRES_PORT: {
            value: '5432'
          }
          POSTGRES_USER: {
            value: 'myadmin'
          }
          POSTGRES_PASSWORD: {
            value: postgresPassword
          }
          POSTGRES_DB: {
            value: 'votes'
          }
          POSTGRES_SSLMODE: {
            value: 'prefer'
          }
        }
      }
    }
    connections: {
      postgresdb: {
        disableDefaultEnvVars: true
        source: postgresDb.id
      }
    }
    platformOptions: {
      confidentialComputeProperties: {
        ccePolicy: loadTextContent('cce/vote-ccepolicy.b64')
      }
      sku: 'Confidential'
    }
    codeReference: 'https://github.com/nithyatsu/example-voting-app/blob/main/vote/app.py#L15'
  }
}

resource resultContainer 'Radius.Compute/containers@2025-08-01-preview' = {
  name: 'result'
  properties: {
    environment: environment
    application: votingApp.id
    containers: {
      result: {
        image: 'ghcr.io/nithyatsu/example-voting-app-result:${imageTag}'
        ports: {
          web: {
            containerPort: 80
          }
        }
        env: {
          PORT: {
            value: '80'
          }
          POSTGRES_HOST: {
            value: postgresDb.properties.host
          }
          POSTGRES_PORT: {
            value: '5432'
          }
          POSTGRES_USER: {
            value: 'myadmin'
          }
          POSTGRES_PASSWORD: {
            value: postgresPassword
          }
          POSTGRES_DB: {
            value: 'votes'
          }
          POSTGRES_SSLMODE: {
            value: 'prefer'
          }
        }
      }
    }
    connections: {
      postgresdb: {
        source: postgresDb.id
      }
    }
    platformOptions: {
      sku: 'Standard'
    }
    codeReference: 'https://github.com/nithyatsu/example-voting-app/blob/main/result/server.js#L89'
  }
}
