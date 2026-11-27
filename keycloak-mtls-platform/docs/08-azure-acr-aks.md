# 8. Azure: Container Registry and AKS

Commands: `platform.sh push`, `aks-credentials`, `aks-attach`
([lib-acr](scripts/lib-acr.md)).

## Configuration

```ini
# config/platform.local.env
ACR_NAME=myregistry              # without .azurecr.io
AZ_SUBSCRIPTION=                 # optional; empty = current az account
AKS_RESOURCE_GROUP=rg-platform
AKS_CLUSTER=aks-platform
```

## One-time setup

```bash
az login
az acr create --resource-group rg-platform --name myregistry --sku Premium --admin-enabled false
./scripts/platform.sh aks-attach        # AKS kubelet identity gets AcrPull on the registry
./scripts/platform.sh aks-credentials   # kubeconfig entry for the cluster
```

`aks-attach` runs `az aks update --attach-acr`, so pods pull without an
`imagePullSecret`. On other clusters create a pull secret from a scoped,
pull-only registry token and set `global.imagePullSecrets`.

## Publishing images

```bash
./scripts/platform.sh build --tag 1.4.0
./scripts/platform.sh push  --tag 1.4.0 --lock
```

`push` does, per image:

1. checks the local image exists and was **not** built with baked private keys,
2. `az acr login --name <ACR_NAME>` (once),
3. `docker tag` → `<registry>/<repository>:<tag>` and `docker push`,
4. records the pushed **digest** in `build/images.pushed.env`,
5. with `--lock`: `az acr repository update --write-enabled false --delete-enabled false`
   so the tag can no longer be overwritten or deleted.

`platform.sh deploy` then pins the workloads to those digests
(`image: repo@sha256:…`), so what runs is exactly what was pushed.

### Building in Azure instead (no local Docker)

```bash
./scripts/platform.sh push --acr-build --tag 1.4.0
```

Uploads each staged build context and builds it with ACR Tasks
(`az acr build`). Useful on build agents without a container runtime. It is
refused with `CERT_MODE=baked`, because that would upload private keys.

### Options

| Option | Effect |
|---|---|
| `--only keycloak,app,client` | subset of images |
| `--tag TAG` | image tag |
| `--acr NAME` | registry, overriding `ACR_NAME` |
| `--acr-build` | build with ACR Tasks |
| `--lock` | make the tag immutable after pushing |
| `--no-login` | skip `az acr login` (CI already logged in) |
| `--allow-baked-certs` | permit images that contain private keys (demos only) |

## Authentication and identities

- The registry **admin user is never used**. `az acr login` exchanges your
  `az` identity (user, service principal, managed identity, workload
  identity) for a short-lived registry token.
- With podman or nerdctl (`CONTAINER_CLI`), the script pipes
  `az acr login --expose-token` into `<cli> login --password-stdin`.
- Roles: the pipeline identity needs `AcrPush`; the cluster needs `AcrPull`
  (granted by `aks-attach`).

CI example (GitHub Actions, federated credentials, no stored secret):

```yaml
permissions:
  id-token: write
  contents: read
steps:
  - uses: actions/checkout@v4
  - uses: azure/login@v2
    with:
      client-id: ${{ vars.AZURE_CLIENT_ID }}
      tenant-id: ${{ vars.AZURE_TENANT_ID }}
      subscription-id: ${{ vars.AZURE_SUBSCRIPTION_ID }}
  - run: ./scripts/platform.sh certs
  - run: ./scripts/platform.sh build --tag "${GITHUB_SHA::12}"
  - run: ./scripts/platform.sh push  --tag "${GITHUB_SHA::12}" --lock
```

(`certs` in CI creates a throw-away CA just to load a CA into the images;
for real environments keep one CA, or use `CERT_MODE=none` with cert-manager.)

## Deploying to AKS

```bash
./scripts/platform.sh secrets
./scripts/platform.sh deploy --values helm/iam-platform/values-production.yaml
./scripts/platform.sh test
```

Notes for AKS:

- **Network policies** need a network policy engine (Azure CNI powered by
  Cilium, Azure NPM or Calico). Without one the policies are accepted but
  not enforced.
- **Pod Security**: `secrets` labels the namespace `restricted`; all pods of
  this chart comply.
- **cert-manager**: install it once per cluster, then use
  `CERT_SOURCE=cert-manager`.
- **Database**: use Azure Database for PostgreSQL. Build the Keycloak image
  with `KC_DB_VENDOR=postgres` and set, in your values file:

  ```yaml
  keycloak:
    database:
      vendor: postgres
      host: mydb.postgres.database.azure.com
      urlProperties: "?sslmode=verify-full&sslfactory=org.postgresql.ssl.DefaultJavaSSLFactory"
      existingSecret: keycloak-db      # keys: username, password
  ```

  `sslfactory=…DefaultJavaSSLFactory` makes the driver verify the server
  certificate against the JVM trust store, which contains the public CAs
  Azure uses.
- **Secrets**: the Kubernetes Secrets created here can instead come from
  Azure Key Vault through the Secrets Store CSI driver or External Secrets;
  keep the same Secret names and keys.
- **Exposure**: see [ingress](helm/ingress.md).

## Sovereign clouds

Set `ACR_LOGIN_SERVER` (for example `myregistry.azurecr.us`).

## Registry hygiene

Enable Microsoft Defender for Containers (image scanning), use a Premium
registry with a private endpoint and no public network access where
possible, and add a retention policy for untagged manifests.
