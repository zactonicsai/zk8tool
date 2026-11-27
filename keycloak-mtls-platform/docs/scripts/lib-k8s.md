# `scripts/lib/k8s.sh`

Implements `platform.sh secrets`, `deploy`, `test` and `status`.

## `secrets`

1. Verifies the certificates in `CERT_DIR` first; refuses to load material
   that does not verify.
2. Creates the namespace if needed and labels it with the *restricted* Pod
   Security Standard (`--no-pod-security` skips the label).
3. Applies one Secret per certificate (`k8s_apply_tls_secret`):

   | Secret | Type | Keys |
   |---|---|---|
   | `<release>-keycloak-tls` | `kubernetes.io/tls` | `tls.crt`, `tls.key`, `ca.crt` |
   | `<release>-spring-app-tls` | same | same |
   | `<release>-test-client-tls` | same | same |
   | `<release>-saml-sp-tls` | same | same |

   The manifest is produced by `kubectl create secret … --from-file … --dry-run=client -o yaml`
   and piped into `kubectl apply`, so the command is idempotent and private
   keys never appear in an argument list or in the script's output.
4. Creates `<release>-keycloak-admin` (`username`, `password`) with a random
   password **only if it does not exist** (`k8s_ensure_admin_secret`).

With `CERT_SOURCE=cert-manager` only the SAML signing Secret and the admin
Secret are created; cert-manager owns the mTLS Secrets.

The Secret names are a contract with the chart
(`templates/_helpers.tpl`: `platform.tlsSecretName`).

## `deploy`

1. `helm_generated_values` writes `build/helm-values.generated.yaml`:

   | Value | From |
   |---|---|
   | `clusterDomain` | `CLUSTER_DOMAIN` |
   | `global.imageRegistry` | `--registry`, else the ACR login server |
   | `certificates.source` | `CERT_SOURCE` (`cert-manager` → `certManager`) |
   | `certificates.subject.*`, `caCommonName` | `CERT_ORG`, `CERT_OU`, `CERT_COUNTRY`, `PROJECT_NAME` |
   | `certificates.issuerDn` | subject of the real CA certificate (not in cert-manager mode) |
   | `<component>.image.repository` / `tag` | `IMAGE_*`, `IMAGE_TAG` |
   | `<component>.image.digest` | `build/images.pushed.env`, when recorded for this tag |
   | `keycloak.realm.name`, `keycloak.database.vendor` | `KC_REALM`, `KC_DB_VENDOR` |
   | `keycloak.publicUrl`, `app.publicUrl` | `KC_PUBLIC_URL`, `APP_PUBLIC_URL` when set |
   | `app.saml.signing.enabled` / `certificate` | the SAML certificate in `CERT_DIR` |

   A values file is used instead of `--set` because subject DNs contain
   commas, which `--set` would split.

2. Runs

   ```
   helm upgrade --install <release> <chart> --namespace <ns> --create-namespace --timeout <HELM_TIMEOUT>
     --values build/helm-values.generated.yaml
     --values <each file in HELM_VALUES> --values <each --values option>
     --set <each --set option>
     --wait
   ```

   Order matters: your files and `--set` flags come last and win.

In dry-run mode the generated values are printed, not written.

## `test`

`helm test <release> --namespace <ns> --logs --timeout <timeout>`; the exit
code is Helm's, i.e. non-zero when the [test client](../07-test-client.md)
reports a failed check.

## `status`

`kubectl get pods,services,secrets --selector app.kubernetes.io/instance=<release> -o wide`.

## Functions

`k8s_secret_name`, `k8s_ensure_namespace`, `k8s_apply_tls_secret`,
`k8s_ensure_admin_secret`, `helm_generated_values`, `_helm_pushed_digest`,
`_helm_issuer_dn`, `secrets_main`, `deploy_main`, `test_main`, `status_main`.

## Tests

`tests/scripts/k8s.bats` (26 tests): namespace and Pod Security label, each
Secret from files, no key material on any command line, admin Secret created
once and kept, overrides, cert-manager mode, refusal of unverifiable
certificates, content and YAML validity of the generated values, digest
selection by tag, ordering of values files and `--set`, `helm test`
arguments, the `all` pipeline order and its skips, dry-run.
