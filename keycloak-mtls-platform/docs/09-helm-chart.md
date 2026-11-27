# 9. Helm chart

Chart: [`helm/iam-platform`](../helm/iam-platform). Per-file documentation
lives in [`docs/helm/`](helm/README.md).

## What it deploys

| Resource | Name | Notes |
|---|---|---|
| StatefulSet + Services | `<release>-keycloak` (+ `-headless`) | HTTPS 8443, management 9000 |
| Deployment + Service | `<release>-spring-app` | HTTPS 8443, management 9443; init container waits for Keycloak |
| Pod (hook `test`) | `<release>-test-client` | runs on `helm test` |
| NetworkPolicies | one per workload | default deny + required flows |
| ServiceAccount | `<release>` | no API token mounted |
| PodDisruptionBudgets | per workload | only when replicas > 1 |
| Ingresses | per workload | optional |
| cert-manager Issuer/Certificates | | only with `certificates.source=certManager` |
| Secret `<release>-keycloak-admin` | | only with `keycloak.admin.create=true` |

## Installing

### With the script (recommended)

```bash
./scripts/platform.sh secrets
./scripts/platform.sh deploy
./scripts/platform.sh test
```

`deploy` writes `build/helm-values.generated.yaml` from the configuration -
images and tag (or pushed digest), registry, cluster domain, certificate
subject and issuer DN, realm, database vendor, public URLs, and the SAML
signing certificate - and passes it to `helm upgrade --install` **before**
your own values files and `--set` flags, so yours win.

### With plain Helm

```bash
helm upgrade --install iam helm/iam-platform --namespace iam --create-namespace \
  --set global.imageRegistry=myregistry.azurecr.io \
  --set keycloak.image.tag=1.4.0 --set app.image.tag=1.4.0 --set testClient.image.tag=1.4.0 \
  --set keycloak.admin.create=true \
  --set certificates.source=certManager
helm test iam --namespace iam --logs
```

With plain Helm you are responsible for what the script otherwise derives:
the certificate subject fields must match your certificates, and SAML
request signing stays off unless you supply the signing certificate and
Secret ([values](helm/values.md#saml-request-signing)).

## Three decisions

| Decision | Value | Options |
|---|---|---|
| Where certificates come from | `certificates.source` | `secret` (default), `certManager`, `image` - see [certificates](03-certificates-and-mtls.md#getting-certificates-into-pods-cert_source) |
| Keycloak's database | `keycloak.database.*` | `dev-file` (default, evaluation) or an external database |
| Exposure | `*.publicUrl`, `*.ingress`, `networkPolicy` | in-cluster only (default) or through an ingress - see [ingress](helm/ingress.md) |

## Evaluation vs production

The defaults install without prerequisites: embedded H2 database on a
volume, one replica each, in-cluster URLs. That is for evaluation.
[`values-production.yaml`](../helm/iam-platform/values-production.yaml) shows
the production shape: cert-manager, external PostgreSQL with verified TLS,
two replicas with PodDisruptionBudgets and zone spreading, public URLs,
ingress, Reloader annotations. The chart refuses unsafe combinations
(several Keycloak replicas on the embedded database, external database
without host or credentials Secret, SAML signing without a certificate).

## Security posture of the pods

- Non-root users, `seccompProfile: RuntimeDefault`, all capabilities
  dropped, no privilege escalation: compliant with the *restricted* Pod
  Security Standard.
- Read-only root filesystem for the app and the test client (Keycloak needs
  to write below `/opt/keycloak/data`).
- No ServiceAccount token mounted.
- Certificates mounted read-only with mode `0440`.
- NetworkPolicies: only the app and the test pod reach Keycloak; the app may
  only talk to Keycloak and DNS; the test pod accepts nothing.

## Testing the chart

| Level | Command | What it proves |
|---|---|---|
| Static | `platform.sh verify --only helm` | `helm lint`, 91 helm-unittest cases, kubeconform schema validation for default, production and cert-manager values |
| In cluster | `platform.sh test` | the 25 checks of the [test client](07-test-client.md) |

## Files

| File | Docs |
|---|---|
| `Chart.yaml`, `values.yaml`, `values.schema.json`, `values-production.yaml`, `ci/` | [values](helm/values.md) |
| `templates/_helpers.tpl` | [helpers](helm/helpers.md) |
| `templates/keycloak/*` | [keycloak](helm/keycloak.md) |
| `templates/app/*` | [spring-app](helm/spring-app.md) |
| `templates/certificates/*` | [certificates](helm/certificates.md) |
| `templates/tests/*` | [test-pod](helm/test-pod.md) |
| `templates/*/networkpolicy.yaml` | [network-policies](helm/network-policies.md) |
| `templates/*/ingress.yaml` | [ingress](helm/ingress.md) |
| `templates/serviceaccount.yaml`, `templates/NOTES.txt` | [helm/README](helm/README.md) |
| `tests/*_test.yaml` | [chart-tests](helm/chart-tests.md) |
