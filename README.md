# Ignite 2026: one app, two Radius environments (ACI + Kubernetes)

The Docker voting app ([nithyatsu/example-voting-app](https://github.com/nithyatsu/example-voting-app)) deploys with one unchanged `app.bicep` to:

| Radius environment | Radius group | Defined in | Where the app runs |
| --- | --- | --- | --- |
| `aci` | `voting-aci` | `environments/aci.bicep` | `vote` (vote + worker + redis) on **Confidential ACI**, `result` on **standard ACI**, `db` on **Azure Database for PostgreSQL Flexible Server**, all in Azure resource group `nsi-aci` |
| `kubernetes` | `voting-k8s` | `environments/kubernetes.bicep` | Deployments/Services on a **local kind cluster** (`kind-ignite`, Apple Silicon/arm64), `db` as in-cluster Postgres. No confidential containers. |

Each environment has its own Radius control plane and `rad` workspace:

| `rad` workspace | Kube context | Radius runs on | Used in |
| --- | --- | --- | --- |
| `ignite` | `nsi-aks` | AKS `nsi-aks` (Azure) | Part 1 (ACI) |
| `ignite-kind` | `kind-ignite` | local kind cluster `ignite` | Part 2 (Kubernetes) |

`rad` commands use the current workspace (`rad workspace show`). Switch with `rad workspace switch <name>`, or add `-w <name>` to a single command.

Follow the steps in order. Every step ends with a **Check** that should pass before you move on.

## Project files

| File | What it is |
| --- | --- |
| `app.bicep` | The application: `vote`, `result`, `db`. Same file for both environments. |
| `environments/aci.bicep` | Recipe pack `voting-aci` (ACI containers pinned to recipe commit `9f5f20a`, volumes, Key Vault secrets, Azure Postgres `Standard_D2ds_v5`) + environment `aci`. |
| `environments/kubernetes.bicep` | Recipe pack `voting-kubernetes` (kube-recipes pinned to `0.61.0`) + environment `kubernetes`. |
| `cce/vote-template.json` | ARM template that mirrors what the ACI recipe deploys for `vote`. Input for the confidential policy. |
| `cce/vote-ccepolicy.b64` | The generated confidential container (CCE) policy. `app.bicep` loads it with `loadTextContent`. |
| `.github/workflows/cce-policy.yaml` | GitHub Action that generates the policy with `az confcom` (it does not run on macOS). |
| `bicepconfig.json` | Registers the `radius` Bicep extension (0.61). |
| `.env.local` | Your variables, created in Step 1. Gitignored; never commit it. |

Each environment file holds its recipe pack and the environment together, so one `rad deploy` creates both.

## Azure layout

| Azure resource group | Contains |
| --- | --- |
| `nsi` (exists) | AKS cluster `nsi-aks` running the Radius control plane. **Never delete it.** |
| `nsi-aci` (new) | Everything Radius creates for the `aci` environment |

## App shape

```
vote (containers) ──► db (postgreSqlDatabases) ◄── result (containers)
 ├─ vote   :80   (Flask)
 ├─ worker       (.NET, redis → postgres)
 └─ redis        (sidecar on localhost:6379)
```

- **Redis is a sidecar.** The ACI recipe gives each containers resource its own VNet and public load balancer, so there is no private network between resources. Containers in one resource share localhost.
- **Postgres is a Radius resource.** The recipe pack decides what it becomes. `POSTGRES_SSLMODE=prefer` lets the same image use TLS to Azure and plaintext in-cluster.
- **`platformOptions`** selects Confidential or Standard ACI and carries the CCE policy. The Kubernetes recipe ignores it.
- **All images are public on GHCR**, including a mirror of `redis` (see [Images](#images-and-the-ghcr-redis-mirror)). ACI cannot reliably pull from Docker Hub.
- **Images are parameters.** `imageTag` and `redisImage` default to the amd64 images that ACI and the CCE policy use. On kind (arm64) Step 11 passes the `-arm64` images instead. The app definition itself is the same.

---

## Prerequisites

| You need | Why |
| --- | --- |
| **Owner** (or **User Access Administrator**) on the subscription | Step 3 creates a custom role and assigns it at subscription scope. Contributor cannot do that. |
| `az`, `kubectl`, `jq`, `gh` (logged in), `openssl` | Used by the steps below. |
| `docker` with `buildx` (logged in to `ghcr.io`) | Only to re-create the redis mirror or change images. |
| A region with Confidential ACI and Postgres `Standard_D2ds_v5` | `eastus2` is verified. Burstable `B1ms` is **not** available there for this subscription. |
| Kube context `nsi-aks` | The AKS cluster that hosts Radius for Part 1. |
| Docker Desktop (running) and `kind` (v0.31 verified) | Part 2 runs on a local kind cluster. |

## Step 0. Tools

The files target Radius **0.61**. An edge/dev `rad` build behaves differently, so pin the CLI.

```bash
cd ~/ignite2026

curl -fsSL https://raw.githubusercontent.com/radius-project/radius/main/deploy/install.sh | /bin/bash -s 0.61.1
which -a rad          # if more than one, put the 0.61.1 one first in PATH (see Step 1)

az login
az account set -s <your-subscription-id>
kubectl config use-context nsi-aks
```

**Check:** `rad version` prints `0.61.x`; `az account show --query id -o tsv` prints the subscription; `kubectl get nodes` works.

## Step 1. Variables (saved to `.env.local`)

Create this **once**. Re-run only `source .env.local` in every new terminal. Do not regenerate `PG_PASSWORD` after Postgres exists: the server keeps the first one.

```bash
cat > .env.local <<EOF
export SUB=<your-subscription-id>
export LOC=eastus2
export PG_PASSWORD="Vt-$(openssl rand -hex 12)"   # Azure rule: 8+ chars, 3 character classes
# export PATH="\$HOME/.radius/ai-extensions/bin:\$PATH"   # uncomment if another rad shadows 0.61.1
# arm64 images for the kind cluster (Part 2)
export KIND_IMAGE_TAG=047c81d1f93c53cad6074db9ad525bf37a541178-arm64
export KIND_REDIS_IMAGE=ghcr.io/nithyatsu/redis@sha256:7e180df929e2aa87c71fd61838e7775ebab7e7e7a08e438045fbeaa123960320
EOF
chmod 600 .env.local
source .env.local
```

**Check:** `echo $SUB $LOC $PG_PASSWORD` prints three values.

## Step 2. Install Radius on nsi-aks

```bash
rad install kubernetes --kubecontext nsi-aks
kubectl get pods -n radius-system          # wait until all pods are Running

rad workspace create kubernetes ignite --context nsi-aks --force
rad workspace switch ignite

rad group create voting-aci

# Radius.Core environments need their Kubernetes namespace to exist first
kubectl --context nsi-aks create namespace voting-aci
```

**Check:** `rad workspace show` shows `ignite` / `nsi-aks`; `rad group list` shows `voting-aci`; `kubectl --context nsi-aks get ns voting-aci` works.

---

## Part 1: ACI environment

All Part 1 `rad` commands run in workspace `ignite` (Radius on `nsi-aks`). If you come back after Part 2, run `rad workspace switch ignite` first.

### Step 3. Azure resource group, providers, service principal, permissions

Radius deploys to Azure as a service principal (SP). It needs **two** role assignments:

| Scope | Role | Why |
| --- | --- | --- |
| Resource group `nsi-aci` | **Owner** | Create, change, and delete everything the recipes deploy. Contributor would work for this app; Owner also covers recipes that create role assignments (for example the Key Vault-backed secrets recipe). |
| Subscription | **Radius ACI operation reader** (custom; only `Microsoft.ContainerInstance/locations/*/read`) | ACI NGroups reports deployment progress at a subscription-level URL (`/subscriptions/<sub>/providers/Microsoft.ContainerInstance/locations/<region>/nGroupsOperations/<id>`), outside the resource group. Without it, Azure creates the containers but Radius cannot poll them and marks `vote`/`result` **Failed** with `AuthorizationFailed`. It is far narrower than built-in Reader. |

```bash
az group create -n nsi-aci -l $LOC

# New subscriptions may not have these providers registered
for p in Microsoft.ContainerInstance Microsoft.Network Microsoft.DBforPostgreSQL; do
  az provider register -n $p --wait
done

# 1) SP with Owner on nsi-aci
az ad sp create-for-rbac \
  --name radius-ignite-sp \
  --role Owner \
  --scopes /subscriptions/$SUB/resourceGroups/nsi-aci \
  -o json > sp.json

export SP_CLIENT_ID=$(jq -r .appId sp.json)
export SP_SECRET=$(jq -r .password sp.json)
export SP_TENANT=$(jq -r .tenant sp.json)
export SP_OBJECT_ID=$(az ad sp show --id $SP_CLIENT_ID --query id -o tsv)
echo "export SP_CLIENT_ID=$SP_CLIENT_ID" >> .env.local
echo "export SP_TENANT=$SP_TENANT"       >> .env.local

# 2) Custom role at subscription scope (skipped if it already exists)
cat > aci-op-reader.json <<EOF
{
  "Name": "Radius ACI operation reader",
  "IsCustom": true,
  "Description": "Read ACI location-scoped operation status so Radius recipes can poll NGroups deployments.",
  "Actions": ["Microsoft.ContainerInstance/locations/*/read"],
  "NotActions": [],
  "AssignableScopes": ["/subscriptions/$SUB"]
}
EOF
az role definition list --custom-role-only --name "Radius ACI operation reader" --query "[0].roleName" -o tsv | grep -q . \
  || az role definition create --role-definition @aci-op-reader.json
rm aci-op-reader.json
sleep 30   # new role definitions take a moment to replicate

# --assignee-object-id avoids a Graph lookup race right after the SP is created
az role assignment create \
  --assignee-object-id $SP_OBJECT_ID --assignee-principal-type ServicePrincipal \
  --role "Radius ACI operation reader" --scope /subscriptions/$SUB
```

**Check:**
```bash
az role assignment list --assignee $SP_CLIENT_ID --all --query "[].{role:roleDefinitionName,scope:scope}" -o table
# Owner                        /subscriptions/<sub>/resourceGroups/nsi-aci
# Radius ACI operation reader  /subscriptions/<sub>
```
If the second `az role assignment create` fails with "role not found", wait 30 seconds and run it again.

### Step 4. Register the credential with Radius

```bash
rad credential register azure sp \
  --client-id $SP_CLIENT_ID \
  --client-secret $SP_SECRET \
  --tenant-id $SP_TENANT

rm sp.json                                # it contains the secret
```

**Check:** `rad credential show azure` shows a ServicePrincipal with your client ID.

### Step 5. Check the images are public

ACI and kind pull images anonymously, so every image must be public. This checks the `app.bicep` defaults (ACI) and the kind images from `.env.local`:

```bash
TAG=$(grep -oE "^param imageTag string = '[^']+'" app.bicep | cut -d"'" -f2)
REDIS=$(grep -oE "^param redisImage string = '[^']+'" app.bicep | cut -d"'" -f2)
for img in $REDIS $KIND_REDIS_IMAGE \
  $(for t in $TAG $KIND_IMAGE_TAG; do for s in vote result worker; do echo ghcr.io/nithyatsu/example-voting-app-$s:$t; done; done); do
  repo=${img#ghcr.io/}; repo=${repo%%[@:]*}; ref=${img##*[@:]}; [[ $img == *@* ]] && ref=sha256:${img##*sha256:}
  tok=$(curl -s "https://ghcr.io/token?scope=repository:$repo:pull" | jq -r .token)
  code=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $tok" \
    -H "Accept: application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json" \
    "https://ghcr.io/v2/$repo/manifests/$ref")
  echo "$code  $img"
done
```

**Check:** all 8 lines start with `200`. A `401`/`403` means the package is private. Open `https://github.com/users/nithyatsu/packages/container/<name>/settings` → **Change visibility** → **Public**. The fork `nithyatsu/example-voting-app` must also stay public.

#### Images and the GHCR redis mirror

| Image | Source |
| --- | --- |
| `ghcr.io/nithyatsu/example-voting-app-{vote,result,worker}:047c81d…` | Built from the fork |
| `ghcr.io/nithyatsu/redis@sha256:ca0acbb1…` | **Mirror** of Docker Hub `redis` (linux/amd64), identical digest |
| `ghcr.io/nithyatsu/example-voting-app-{vote,result,worker}:047c81d…-arm64` | Same commit built for linux/arm64, for kind on Apple Silicon (Part 2) |
| `ghcr.io/nithyatsu/redis@sha256:7e180df9…` (tag `7.4.11-arm64`) | Mirror of Docker Hub `redis:7.4.11` linux/arm64, for kind |

Why the mirror: ACI repeatedly failed to pull `redis` from Docker Hub with `AzureContainerInstance/RegistryErrorResponse … 'docker.io' … Please retry later` (anonymous pull limits). Copying by digest keeps the exact same image bytes, so nothing about the container changes. Re-create it (one time, or for another Docker Hub image) with:

```bash
echo $GITHUB_TOKEN | docker login ghcr.io -u <github-user> --password-stdin   # token needs write:packages
docker buildx imagetools create --tag ghcr.io/nithyatsu/redis:ignite-amd64 \
  docker.io/library/redis@sha256:ca0acbb137c1dc3339c8b147a58fd6f42775d4599327b50e7b116c23de501af2
# New packages are private: make it public (see Check above)
```

Pin images by digest (`@sha256:`) or immutable tag. The confidential policy in Step 6 is tied to the exact image refs.

### Step 6. Confidential container (CCE) policy for `vote`

`vote` runs on **Confidential ACI**: an AMD SEV-SNP enclave whose memory Azure operators cannot read. The enclave only starts containers that match a **CCE policy**, an allowlist of images (by digest/tag), commands, env vars, and mounts. Attestation can prove that only that policy's code runs.

- Azure **rejects an empty policy** for the Confidential SKU (`InvalidBase64CcePolicy`), and the Radius ACI recipe does not generate one. It passes through `platformOptions.confidentialComputeProperties.ccePolicy`, which `app.bicep` loads from `cce/vote-ccepolicy.b64`.
- The policy is generated from `cce/vote-template.json`, an ARM template that mirrors exactly what the recipe deploys for `vote` (same containers, images, ports, env, cpu 1 / memory 1 GB each).
- Env vars that are template **parameters** become wildcards (`.*`) in the policy: `POSTGRES_PASSWORD` (so no secret is in the policy) and `POSTGRES_HOST` (so the policy works with any Postgres server name). All other env values are pinned.
- `vote`'s Postgres connection has `disableDefaultEnvVars: true`. Otherwise the recipe adds `CONNECTION_*` env vars that the policy does not allow.
- `result` is Standard ACI and needs no policy.

**The committed policy already matches `app.bicep`. You do not need to regenerate it** unless you change `vote` (images, env names/values, ports, command, containers).

**Check that the policy matches `app.bicep`** (resolves the `imageTag`/`redisImage` defaults, which are what ACI deploys):
```bash
TAG=$(grep -oE "^param imageTag string = '[^']+'" app.bicep | cut -d"'" -f2)
REDIS=$(grep -oE "^param redisImage string = '[^']+'" app.bicep | cut -d"'" -f2)
awk '/^resource voteContainer/,/^resource resultContainer/' app.bicep | grep -oE "image: .+" |
  sed -e "s|^image: redisImage$|$REDIS|" -e "s|^image: '||" -e "s|'$||" -e "s|\${imageTag}|$TAG|" |
while read img; do
  base64 -d < cce/vote-ccepolicy.b64 | grep -q "\"id\":\"$img\"" && echo "OK       $img" || echo "MISSING  $img"
done
```
All 3 lines (redis, vote, worker) must say `OK`.

**To regenerate** (after changing `vote`). `az confcom` only runs on Linux/Windows, so a GitHub Action does it:
1. Make the same change in `cce/vote-template.json` that you made in `app.bicep`: same images, env names and values, ports. Keep `POSTGRES_PASSWORD`/`POSTGRES_HOST` as `[parameters(...)]`.
2. Make sure every image is public (Step 5). The workflow pulls them.
3. Push. The workflow runs automatically on changes to `cce/vote-template.json`, or run it with `gh workflow run cce-policy.yaml`.
4. Download the result and commit it:
   ```bash
   RUN=$(gh run list --workflow cce-policy.yaml -L 1 --json databaseId --jq '.[0].databaseId')
   gh run watch $RUN --exit-status
   rm -rf /tmp/pol && gh run download $RUN -n vote-ccepolicy -D /tmp/pol
   tr -d '\n' < /tmp/pol/vote-ccepolicy.b64 > cce/vote-ccepolicy.b64
   git add cce/vote-ccepolicy.b64 && git commit -m "Regenerate vote CCE policy" && git push
   ```
5. Run the policy check again.
6. If `vote` is **already deployed**, re-run Step 8 and then replace the running instance. NGroups updates its profile but does **not** roll instances that already exist:
   ```bash
   VOTE_CG=$(az container list -g nsi-aci --query "[?sku=='Confidential'].name | [0]" -o tsv)
   az container delete -g nsi-aci -n $VOTE_CG -y     # NGroups recreates it from the new profile in ~1-2 minutes
   ```

If the policy doesn't match, the deployment can succeed but the blocked container never starts. Look for policy/denied messages in `az container logs` or `az container show ... --query containers[].instanceView`.

### Step 7. Create the `aci` environment and its recipe pack

```bash
rad deploy environments/aci.bicep -g voting-aci -p subscriptionId=$SUB
```

**Check:** `rad env show aci -g voting-aci --preview -o json` shows the Azure scope (`nsi-aci`) and recipe pack `voting-aci`.

### Step 8. Deploy the app to ACI (about 10–15 minutes, mostly Postgres)

```bash
rad workspace switch ignite
rad deploy app.bicep -g voting-aci --environment aci \
  -p postgresPassword="$PG_PASSWORD"
```

Do **not** pass `imageTag` or `redisImage` here. The defaults are the amd64 images that the CCE policy allows.

**Check:** the output ends with `Deployment Complete` and lists `vote`, `result`, `db`, `example-voting-app`.

### Step 9. Verify the ACI deployment

```bash
az container list -g nsi-aci --query "[].{name:name, sku:sku, state:provisioningState}" -o table
# One Confidential group (vote) and one Standard group (result)

VOTE_CG=$(az container list -g nsi-aci --query "[?sku=='Confidential'].name | [0]" -o tsv)
az container show -g nsi-aci -n $VOTE_CG --query "containers[].{name:name, state:instanceView.currentState.state, restarts:instanceView.restartCount}" -o table
# redis, vote, worker: Running, 0 restarts

RESULT_IP=$(rad resource show Radius.Compute/containers result -g voting-aci -o json | jq -r '.properties.hosts.result')
VOTE_IP=$(az network public-ip list -g nsi-aci --query "[?starts_with(name,'inboundPIP')].ipAddress" -o tsv | grep -v "$RESULT_IP")
echo "vote:   http://$VOTE_IP"
echo "result: http://$RESULT_IP"
curl -s -o /dev/null -w "vote %{http_code}\n"   http://$VOTE_IP/
curl -s -o /dev/null -w "result %{http_code}\n" http://$RESULT_IP/

az container logs -g nsi-aci -n $VOTE_CG --container-name worker | tail -5   # "Connected to db", "Processing vote ..."
```

**Check:** both URLs return `200`. Vote in the browser, and the result page updates within a few seconds.

`vote` has no `hosts` value because its first container (redis) exposes no port. That's why its IP comes from the `inboundPIP-*` public IPs.

---

## Part 2: Kubernetes environment (local kind)

Part 2 uses its own Radius install on a local kind cluster. It does not touch `nsi-aks` or Azure.

### Step 10. Create the kind cluster, install Radius, create the `kubernetes` environment

```bash
source .env.local
kind create cluster --name ignite            # creates and switches to context kind-ignite
kubectl config use-context kind-ignite

rad install kubernetes --kubecontext kind-ignite
kubectl get pods -n radius-system -w         # wait until all 6 pods are Running (about 2 minutes), then Ctrl+C

rad workspace create kubernetes ignite-kind --context kind-ignite --force
rad workspace switch ignite-kind
rad group create voting-k8s
rad group switch voting-k8s
kubectl create namespace voting-k8s          # must exist before the environment

rad deploy environments/kubernetes.bicep -g voting-k8s
```

**Check:**
- `rad workspace show` shows `ignite-kind` / `kind-ignite` / `voting-k8s`.
- `rad env show kubernetes -g voting-k8s --preview -o json` shows `provisioningState: Succeeded`, namespace `voting-k8s` and recipe pack `voting-kubernetes`.

The recipe pack pins kube-recipes to `0.61.0` (the recipe-packs README recommends a version tag over `:latest`). The containers recipe ignores `platformOptions`, so `vote` runs as an ordinary pod here.

### Step 11. Deploy the same app.bicep with the arm64 images

The kind node is arm64 (Apple Silicon). The default images are amd64-only, and the node would ignore them, so pass the `-arm64` images from `.env.local`:

```bash
rad deploy app.bicep -g voting-k8s --environment kubernetes \
  -p postgresPassword="$PG_PASSWORD" \
  -p imageTag="$KIND_IMAGE_TAG" \
  -p redisImage="$KIND_REDIS_IMAGE"
```

**Check:** the output ends with `Deployment Complete` and lists `vote`, `result`, `db`, `example-voting-app`. It takes about 1 minute.

How the arm64 images were made (only needed if you change the app):
- **vote/result/worker:** the fork has a manual workflow, `.github/workflows/publish-arm64-images.yaml`, that builds on GitHub's arm runners and pushes `<sha>-arm64` tags. Run `gh workflow run publish-arm64-images.yaml -R nithyatsu/example-voting-app -f ref=<full-sha>`. A local `docker buildx build --platform linux/arm64 --provenance=false -t <tag> --push <dir>` also works if your network can reach PyPI, npm and NuGet (corporate filters such as Global Secure Access may block them).
- **redis:** `docker buildx imagetools create --tag ghcr.io/nithyatsu/redis:7.4.11-arm64 docker.io/library/redis:7.4.11@<linux/arm64 manifest digest>`.

### Step 12. Verify the Kubernetes deployment

```bash
kubectl get pods,svc -n voting-k8s       # db 1/1, result 1/1, vote 3/3 Running
kubectl logs -n voting-k8s deploy/vote -c worker --tail=5   # "Connected to db", "Found redis at 127.0.0.1"

kubectl -n voting-k8s port-forward svc/vote-vote 8080:80 &
kubectl -n voting-k8s port-forward svc/result-result 8081:80 &
open http://localhost:8080 http://localhost:8081
```

**Check:** vote in the browser. The worker logs `Processing vote for ...` and the result page updates. Stop the port-forwards with `kill %1 %2`.

---

## Step 13. Final check: two environments, one app

```bash
rad env show aci        -w ignite      -g voting-aci --preview
rad env show kubernetes -w ignite-kind -g voting-k8s --preview
rad app graph -a example-voting-app -w ignite      -g voting-aci --preview   # ACI NGroups, load balancers, VNets
rad app graph -a example-voting-app -w ignite-kind -g voting-k8s --preview   # Deployments, Services, Secret
```

**Check:** both graphs show `vote -> db` and `result -> db`. Only the resources underneath differ.

## Troubleshooting

| Symptom | Cause / fix |
| --- | --- |
| `Namespace 'voting-aci' does not exist` (Step 7/10) | Create the namespace (Step 2 for `voting-aci`, Step 10 for `voting-k8s`). |
| `rad env show` output isn't JSON / env not found | Add `--preview`. |
| `rad app graph` / `rad app list` say the app doesn't exist | Use `-a <name> --preview` (Radius.Core apps), and check the workspace with `rad workspace show`. |
| A `rad` command hits the wrong cluster | Each part has its own workspace. Run `rad workspace switch ignite` (ACI) or `ignite-kind` (kind), or pass `-w`. |
| kind pods stuck `ContainerCreating`/`ErrImagePull` with `no match for platform` | You deployed the amd64 defaults to arm64 kind. Redeploy with the `-p imageTag/redisImage` from Step 11. |
| `rad install` on kind times out | Make sure Docker Desktop is running, then `kubectl get pods -n radius-system` and wait. Re-running `rad install` is safe. |
| Environment deploy says an environment is required | Your workspace has a default environment. Pass `--environment` explicitly. |
| `AuthorizationFailed` on `.../nGroupsOperations/read` | The subscription-scope custom role from Step 3 is missing or not propagated. Check the role list in Step 3, wait a minute, and redeploy. |
| `AzureContainerInstance/RegistryErrorResponse ... docker.io` | ACI couldn't pull from Docker Hub. Use a GHCR mirror (Step 5). |
| `RegistryErrorResponse` / `unauthorized` for `ghcr.io` | The package is private. Make it public (Step 5). |
| `InvalidBase64CcePolicy` | The policy is empty or broken. Check `cce/vote-ccepolicy.b64` has no newlines and is non-empty (Step 6). |
| Changed `vote` or the policy but the running group still behaves the old way | NGroups doesn't roll existing instances. Delete the Confidential container group (Step 6, item 6). |
| `vote` deployed but a container never starts | The policy doesn't match `vote`. Run the Step 6 check and regenerate. |
| `SkuNotAvailable` for Postgres | Pick another region in `LOC` and `az group create`, or another `skuName` in `environments/aci.bicep`. |
| `ConflictingConcurrentWrite`, or `vote`/`result` overwrite each other's network | The ACI recipe isn't pinned. Keep `aciRecipesVersion` (`9f5f20a…`) in `environments/aci.bicep`. `:latest` (0.61.0) names Azure resources per resource group. |
| Azure auth errors in Step 8 | Run `rad credential show azure`. If the secret expired: `az ad sp credential reset --id $SP_CLIENT_ID`, then repeat Step 4. |
| Vote works but result stays at 0 | Check worker logs: `az container logs ... --container-name worker` (ACI) or `kubectl logs deploy/vote -c worker -n voting-k8s`. |
| Which recipe failed? | `kubectl logs -n radius-system deploy/dynamic-rp` |

After any fix, re-run the same `rad deploy`. It is idempotent and adopts the Azure resources that already exist.

## Cleanup

```bash
source .env.local
rad app delete example-voting-app -w ignite -g voting-aci --preview -y
az group delete -n nsi-aci -y --no-wait        # never delete "nsi": it holds the AKS cluster

# Remove the assignment before the role definition (a role in use can't be deleted)
az role assignment delete --assignee $SP_CLIENT_ID --role "Radius ACI operation reader" --scope /subscriptions/$SUB
az role definition delete --name "Radius ACI operation reader" --scope /subscriptions/$SUB
az ad sp delete --id $SP_CLIENT_ID
```

kind (local only):
```bash
rad workspace delete ignite-kind -y
kind delete cluster --name ignite
```

Optional: delete the `redis` package at https://github.com/users/nithyatsu/packages/container/redis/settings.

## Known limitations

- The `aci` pack provisions Postgres as GeneralPurpose `Standard_D2ds_v5` (about $130/month). Delete `nsi-aci` after the demo.
- The Azure Postgres server allows public access from any IP (same as the upstream `azure-aks` pack). TLS is enforced.
- The ACI recipe passes `secretKeyRef` values through as literal key names, so the Postgres password is a plain env value from a `@secure()` parameter.
- The ACI recipe does not generate CCE policies; you must supply one (Step 6).
- The SP secret expires after 1 year by default.
