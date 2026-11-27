# Helm chart files

Chart: [`helm/iam-platform`](../../helm/iam-platform). Overview and install
instructions: [Helm chart](../09-helm-chart.md).

## Layout

```
helm/iam-platform/
├── Chart.yaml                     chart metadata; appVersion = default image tag
├── values.yaml                    defaults (evaluation friendly)
├── values.schema.json             validation of the most important values
├── values-production.yaml         example production overlay
├── ci/cert-manager-values.yaml    extra value set rendered by `platform.sh verify`
├── templates/
│   ├── _helpers.tpl               names, labels, URLs, DNs, guards
│   ├── NOTES.txt                  post-install notes and warnings
│   ├── serviceaccount.yaml        one ServiceAccount, no token
│   ├── keycloak/                  statefulset, service, admin-secret, pdb, ingress, networkpolicy
│   ├── app/                       deployment, service, pdb, ingress, networkpolicy
│   ├── certificates/              cert-manager Issuer + Certificates
│   └── tests/                     helm test pod + its networkpolicy
└── tests/                         helm-unittest suites
```

## Per-file documentation

| File(s) | Docs |
|---|---|
| `values.yaml`, `values.schema.json`, `values-production.yaml`, `ci/` | [values](values.md) |
| `templates/_helpers.tpl` | [helpers](helpers.md) |
| `templates/keycloak/*.yaml` | [keycloak](keycloak.md) |
| `templates/app/*.yaml` | [spring-app](spring-app.md) |
| `templates/certificates/certificates.yaml` | [certificates](certificates.md) |
| `templates/tests/*.yaml` | [test-pod](test-pod.md) |
| `templates/*/networkpolicy.yaml` | [network-policies](network-policies.md) |
| `templates/*/ingress.yaml` | [ingress](ingress.md) |
| `tests/*_test.yaml` | [chart-tests](chart-tests.md) |

## `Chart.yaml`

`version` is the chart version (bump on every chart change). `appVersion`
is the default image tag for all three images when `<component>.image.tag`
is empty; `platform.sh deploy` always sets the tag (or digest) explicitly.
`kubeVersion: >=1.27`.

## `templates/serviceaccount.yaml`

One ServiceAccount `<fullname>` for all workloads, with
`automountServiceAccountToken: false`: nothing here calls the Kubernetes
API. Add annotations (`serviceAccount.annotations`) for Entra Workload ID
if a workload needs an Azure identity, for example password-less database
access. `serviceAccount.create: false` + `serviceAccount.name` reuses an
existing account.

## `templates/NOTES.txt`

Printed after install/upgrade: the URLs, how to run the test pod, how to
read the bootstrap admin password, a port-forward command. It also prints
warnings for evaluation-grade settings (embedded database, unsigned SAML
requests, certificates baked into images) and runs the chart's guard rails,
so an invalid combination fails the release instead of half-installing.

## Naming

Everything is named `<fullname>-<component>`, where `fullname` is the
release name (or `fullnameOverride`). These names are a contract with the
scripts: certificate SANs and Secret names are derived the same way in
`scripts/lib/common.sh` and `scripts/lib/k8s.sh`.

## Labels

Every resource carries `app.kubernetes.io/{name,instance,component,version,part-of,managed-by}`
and `helm.sh/chart`, plus `commonLabels`. Selectors use only
`name`, `instance` and `component`, which never change during a release's life.
Components: `keycloak`, `spring-app`, `test-client`, `pki`, `platform`.
