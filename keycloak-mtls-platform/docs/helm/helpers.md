# `templates/_helpers.tpl`

Named templates used by every manifest. Keeping names, URLs and
distinguished names in one place is what keeps the chart, the certificates
and the Keycloak realm consistent.

## Names

| Template | Result (release `iam`) |
|---|---|
| `platform.fullname` | `iam` (or `fullnameOverride`), max 40 characters |
| `platform.keycloak.fullname` | `iam-keycloak` |
| `platform.app.fullname` | `iam-spring-app` |
| `platform.testClient.fullname` | `iam-test-client` |
| `platform.serviceAccountName` | `iam`, or `serviceAccount.name` |
| `platform.tlsSecretName` (dict `root`, `name`) | `iam-<name>-tls` |
| `platform.samlSecretName` | `iam-saml-sp-tls` or `app.saml.signing.existingSecret` |
| `platform.keycloak.adminSecretName` | `iam-keycloak-admin` or `keycloak.admin.existingSecret` |

## Labels and images

| Template | Purpose |
|---|---|
| `platform.labels` (dict `root`, `component`) | full label set |
| `platform.selectorLabels` | the immutable subset used in selectors |
| `platform.image` (dict `root`, `image`) | `[registry/]repository@digest` when a digest is set, else `…:tag` (tag defaults to `appVersion`) |
| `platform.imagePullSecrets` | `imagePullSecrets:` block when configured |

## URLs

| Template | Result |
|---|---|
| `platform.keycloak.host` | `iam-keycloak.<ns>.svc.<clusterDomain>` |
| `platform.keycloak.internalUrl` | `https://<host>:<service.port>` |
| `platform.keycloak.publicUrl` | `keycloak.publicUrl` or the internal URL, without trailing slash |
| `platform.keycloak.managementUrl` | `https://<host>:<service.managementPort>` |
| `platform.app.*` | the same four for the app |
| `platform.app.samlEntityId` | `<app public URL>/saml2/service-provider-metadata/keycloak` |
| `platform.urlHost` | host part of a URL |

## Certificates

| Template | Purpose |
|---|---|
| `platform.subjectDn` (dict `root`, `cn`) | `CN=<cn>,OU=…,O=…,C=…` from `certificates.subject` |
| `platform.issuerDn` | `certificates.issuerDn` or the subject DN of `caCommonName` |
| `platform.mountCertificates` | true unless `certificates.source=image` |
| `platform.tlsVolume` / `platform.tlsVolumeMount` | Secret volume (mode `0440`) and its read-only mount at `/etc/platform/tls` |
| `platform.reloaderAnnotations` | Reloader annotation when `certificates.reloader` |

## Guards

| Template | Fails the render when |
|---|---|
| `platform.app.samlSigning` | signing is enabled but no certificate was supplied |
| `platform.validate` | an external database has no host/URL or no credentials Secret; several Keycloak replicas would share the embedded database |
| `platform.keycloak.databasePort` | (helper) explicit port or the vendor default: 5432, 3306, 1433, 1521 |

Guards turn silent misconfiguration into an install-time error with a
message that names the value to fix.

## The contract with the scripts

`scripts/lib/common.sh` derives the same names (`<release>-keycloak`, …) for
certificate SANs and `scripts/lib/k8s.sh` creates Secrets named
`<release>-<name>-tls`. If you change a naming template here, change those
too; the bats tests (`certs.bats`, `k8s.bats`) and the chart tests assert
both sides.
