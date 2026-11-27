# `templates/keycloak/`

## `statefulset.yaml`

Keycloak runs as a StatefulSet (stable pod names for clustering; a volume
claim for the embedded database).

**Start command**: `start --optimized --import-realm`
(`--optimized` is dropped with `keycloak.optimized=false`; `--import-realm`
with `keycloak.realm.import=false`).

**Environment** (runtime configuration; build options are in the image):

| Variable | Value | Purpose |
|---|---|---|
| `KC_HOSTNAME` | public URL | issuer and front-channel URLs |
| `KC_HOSTNAME_BACKCHANNEL_DYNAMIC` | `true`, only when the public URL differs from the Service URL | in-cluster callers keep using the Service |
| `KC_HTTP_ENABLED` | `false` | HTTPS only |
| `KC_HTTPS_PORT` | `8443` | |
| `KC_HTTPS_CERTIFICATE_FILE` / `_KEY_FILE` | `/etc/platform/tls/tls.{crt,key}` | server certificate (PEM) |
| `KC_TRUSTSTORE_PATHS` | `/etc/platform/tls/ca.crt` | CA for client certificates and outgoing TLS (not set with `certificates.source=image`: the CA baked into the image is used) |
| `KC_HTTP_MANAGEMENT_PORT` | `9000` | health / metrics |
| `KC_PROXY_HEADERS` | `keycloak.proxyHeaders` | only when set |
| `KC_LOG_LEVEL` | `keycloak.logLevel` | |
| `KC_BOOTSTRAP_ADMIN_USERNAME` / `_PASSWORD` | from the admin Secret | temporary admin |
| `KC_DB_URL_HOST` / `_PORT` / `_DATABASE` / `_PROPERTIES` or `KC_DB_URL` | `keycloak.database.*` | external database |
| `KC_DB_USERNAME` / `KC_DB_PASSWORD` | from `database.existingSecret` | |
| realm placeholders | see [realm](../05-keycloak-realm.md#placeholders) | resolved at import |
| `keycloak.extraEnv` | | appended |

With `keycloak.optimized=false` the chart also sets the build options
(`KC_DB`, health, metrics, client-auth) at runtime, for use with a stock
Keycloak image.

**Ports**: `https` 8443, `management` 9000, `jgroups` 7800, `jgroups-fd` 57800.

**Probes**: `startupProbe` `/health/started`, `readinessProbe`
`/health/ready`, `livenessProbe` `/health/live`, all HTTPS on the
management port. The kubelet does not verify the certificate and cannot
present one, which is why the management interface asks for none.

**Volumes**:

| Volume | Mount | When |
|---|---|---|
| `tls` (Secret `<fullname>-keycloak-tls`, mode 0440) | `/etc/platform/tls` | unless `certificates.source=image` |
| `data` (volume claim, or emptyDir without persistence) | `/opt/keycloak/data/h2` | embedded database only. Only the H2 directory is mounted: `/opt/keycloak/data/import` (the realm file) ships in the image |
| `tmp` (emptyDir) | `/tmp` | always |

**Security context**: uid 1000, gid 0, `fsGroup` 1000, non-root,
`RuntimeDefault` seccomp, no privilege escalation, all capabilities dropped.
The root filesystem stays writable because Keycloak writes below
`/opt/keycloak/data`.

**Clustering**: `podManagementPolicy: Parallel`; pods find each other
through the database (Keycloak's default `jdbc-ping`) and encrypt cluster
traffic themselves, so no extra discovery configuration is needed.

**Guards**: the template fails for an external database without host/URL or
credentials Secret, and for several replicas on the embedded database.

## `service.yaml`

Two Services:

- `<fullname>-keycloak` (ClusterIP by default): `https` 8443 and
  `management` 9000. TLS is terminated by Keycloak itself, so client
  certificates reach it.
- `<fullname>-keycloak-headless`: required by the StatefulSet;
  `publishNotReadyAddresses: true`.

## `admin-secret.yaml`

Rendered only with `keycloak.admin.create=true` and no `existingSecret`.
Creates `<fullname>-keycloak-admin` with user `temp-admin` and a random
40-character password. The password is generated once (`lookup` reuses the
stored value on upgrades) and the Secret is annotated
`helm.sh/resource-policy: keep`. `platform.sh secrets` creates the same
Secret outside Helm, which is why this is off by default.

## `pdb.yaml`

PodDisruptionBudget (`minAvailable: 1`) when `keycloak.replicas > 1`.

## `ingress.yaml`, `networkpolicy.yaml`

See [ingress](ingress.md) and [network policies](network-policies.md).

## Tests

`tests/keycloak_test.yaml` (33 cases): image reference rules, TLS settings
and mounts per certificate source, hostname split, realm placeholders and
DNs, SAML signing switch and its guard, admin Secret reference, database
variants and guards, persistence, probes, security context, Reloader
annotation, Services, admin Secret, PDB, Ingress.
