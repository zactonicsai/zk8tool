# Chart unit tests (`helm/iam-platform/tests/`)

[helm-unittest](https://github.com/helm-unittest/helm-unittest) suites:
they render the chart with given values and assert on the result. No
cluster needed.

```bash
helm plugin install https://github.com/helm-unittest/helm-unittest   # once
helm unittest helm/iam-platform
# or, together with helm lint and kubeconform:
./scripts/platform.sh verify --only helm
```

| Suite | Cases | Asserts |
|---|---|---|
| `keycloak_test.yaml` | 33 | StatefulSet, Services, admin Secret, PDB, Ingress: image reference rules, TLS settings and mounts per certificate source, hostname split, realm placeholders, SAML signing switch, database variants, guards, probes, security context |
| `app_test.yaml` | 19 | Deployment, Service, PDB, Ingress: URLs, mounts, read-only root, SAML signing on/off, allow-list, init container, probes, rollout |
| `certificates_test.yaml` | 11 | cert-manager resources: bootstrap chain, subjects, usages, SANs, PKCS#8, existing issuer, RSA |
| `test_client_test.yaml` | 8 | `helm test` pod: hook annotations, environment, mounts, security context |
| `networkpolicy_test.yaml` | 12 | default deny, exact peers and ports, database egress, extra rules, `allowExternalHttps` |
| `common_test.yaml` | 8 | ServiceAccount, naming, labels, NOTES warnings and guards |

All suites render the chart as release `iam` in namespace `iam`.

## What the suites protect

- **The contract with the scripts**: resource and Secret names
  (`iam-keycloak`, `iam-keycloak-tls`, …), the subject DNs handed to the
  realm, and the URLs. A rename that would break `platform.sh secrets` or
  the certificate SANs fails a test.
- **Security defaults**: non-root, read-only root filesystem, dropped
  capabilities, no API token, certificate mounts with mode `0440`,
  default-deny policies.
- **Guards**: each `fail` in the templates has a test (`failedTemplate`).
- **Both branches of every switch**: certificate source, database vendor,
  SAML signing, public URL, replicas, ingress.

## Writing a case

```yaml
- it: uses the tag when no digest is given
  template: keycloak/statefulset.yaml
  set:
    global.imageRegistry: myreg.azurecr.io
    keycloak.image.tag: 1.2.3
  asserts:
    - equal:
        path: spec.template.spec.containers[0].image
        value: myreg.azurecr.io/iam-platform/keycloak:1.2.3
```

Conventions used here: `contains` with a full `{name, value}` item for
environment variables; `notContains … any: true` to assert a variable or
volume is absent; `documentIndex` for templates that render several
documents; `failedTemplate.errorPattern` for guards.

## Other static checks on the chart

`platform.sh verify --only helm` additionally runs, for the default values,
`values-production.yaml` and `ci/cert-manager-values.yaml`:

- `helm lint --strict` (includes `values.schema.json` validation),
- `helm template | kubeconform -strict -ignore-missing-schemas` (Kubernetes
  API schema validation; cert-manager kinds are skipped unless you give
  kubeconform their schemas).

## Note on how these suites were checked

The environment this repository was produced in could not run Helm. The
suites were executed against a stand-in renderer that implements the
template functions the chart uses, and all 91 cases passed there; rendered
manifests were validated against the Kubernetes 1.31 and cert-manager JSON
schemas. Run `helm unittest` once with real Helm to confirm.
