# Values reference

File: [`helm/iam-platform/values.yaml`](../../helm/iam-platform/values.yaml).
`platform.sh deploy` sets the values marked ⚙ from `config/platform.env`.

## Global

| Value | Default | Meaning |
|---|---|---|
| `fullnameOverride` | `""` | Base name of all resources (default: release name) |
| `clusterDomain` ⚙ | `cluster.local` | Cluster DNS suffix used in in-cluster URLs |
| `commonLabels` | `{}` | Labels added to every resource |
| `global.imageRegistry` ⚙ | `""` | Registry prefix for all images |
| `global.imagePullSecrets` | `[]` | Pull secrets (not needed with an attached ACR) |
| `serviceAccount.create` / `name` / `annotations` / `automountToken` | `true` / `""` / `{}` / `false` | Shared ServiceAccount |

## Certificates

| Value | Default | Meaning |
|---|---|---|
| `certificates.source` ⚙ | `secret` | `secret`, `certManager` or `image` |
| `certificates.subject.organization` ⚙ / `organizationalUnit` ⚙ / `country` ⚙ | `Example Corp` / `Platform` / `US` | Subject fields; Keycloak matches client certificates on them |
| `certificates.caCommonName` ⚙ | `iam-platform Root CA` | CN of the issuing CA |
| `certificates.issuerDn` ⚙ | `""` | Issuer DN (RFC 2253) of client certificates; empty = built from the fields above |
| `certificates.reloader` | `false` | Add Reloader annotations to the workloads |
| `certificates.certManager.issuerRef.{name,kind,group}` | `""` / `Issuer` / `cert-manager.io` | Existing issuer; empty name = bootstrap a CA |
| `certificates.certManager.caDuration` | `43800h` | Lifetime of the bootstrapped CA |
| `certificates.certManager.duration` / `renewBefore` | `2160h` / `720h` | Leaf lifetime / renewal window |
| `certificates.certManager.privateKey.{algorithm,size,rotationPolicy}` | `ECDSA` / `256` / `Always` | Leaf keys |

## Keycloak

| Value | Default | Meaning |
|---|---|---|
| `keycloak.enabled` | `true` | |
| `keycloak.image.{repository,tag,digest,pullPolicy}` ⚙ | `iam-platform/keycloak`, appVersion | A digest wins over the tag |
| `keycloak.replicas` | `1` | More than one requires an external database |
| `keycloak.optimized` | `true` | Image was built with `kc.sh build`; `false` for a stock image |
| `keycloak.realm.name` ⚙ / `import` | `platform` / `true` | Realm name; import on first start |
| `keycloak.publicUrl` ⚙ | `""` | Browser-facing URL; empty = in-cluster URL |
| `keycloak.admin.existingSecret` / `create` | `""` / `false` | Bootstrap admin Secret (`username`, `password`); default name `<fullname>-keycloak-admin` |
| `keycloak.database.vendor` ⚙ | `dev-file` | Must match the image |
| `keycloak.database.{host,port,name,urlProperties}` | | Connection parts |
| `keycloak.database.url` | `""` | Full JDBC URL instead |
| `keycloak.database.existingSecret` | `""` | Secret with `username`, `password` |
| `keycloak.persistence.{enabled,size,storageClass}` | `true` / `1Gi` / `""` | Volume for the embedded database only |
| `keycloak.proxyHeaders` | `""` | `xforwarded` or `forwarded` behind a trusted proxy |
| `keycloak.logLevel` | `info` | |
| `keycloak.extraEnv` | `[]` | Extra environment variables |
| `keycloak.resources` | 500m / 1Gi request, 2Gi limit | |
| `keycloak.service.{type,port,managementPort,annotations}` | `ClusterIP` / `8443` / `9000` | |
| `keycloak.ingress.{enabled,className,annotations,host,tlsSecretName}` | disabled | |
| `keycloak.pdb.{enabled,minAvailable}` | `true` / `1` | Rendered when replicas > 1 |
| `keycloak.networkPolicy.{extraIngress,extraEgress}` | `[]` | Extra peers / rules |
| `keycloak.podSecurityContext`, `containerSecurityContext` | restricted | |
| `keycloak.{terminationGracePeriodSeconds,podAnnotations,nodeSelector,tolerations,affinity,topologySpreadConstraints}` | | Scheduling |

## Spring app

| Value | Default | Meaning |
|---|---|---|
| `app.enabled` | `true` | |
| `app.image.*` ⚙ | `iam-platform/spring-app` | |
| `app.replicas` | `1` | With more: session affinity at the ingress |
| `app.publicUrl` ⚙ | `""` | Browser-facing URL |
| `app.clientAuth` | `want` | `want` or `need` |
| `app.forwardHeadersStrategy` | `none` | `native` / `framework` behind a trusted proxy |
| `app.oidc.clientId` | `spring-app` | |
| `app.saml.signing.enabled` ⚙ | `false` | Sign AuthnRequests |
| `app.saml.signing.certificate` ⚙ | `""` | Base64 DER of the SP signing certificate |
| `app.saml.signing.existingSecret` | `""` | Secret with `tls.crt`, `tls.key`; default `<fullname>-saml-sp-tls` |
| `app.api.audience` / `requiredRole` | `spring-app` / `api-read` | API requirements |
| `app.api.allowedClientSubjects` | `[]` | Allowed client certificate subject DNs; empty = any from the CA |
| `app.waitForKeycloak.{enabled,timeoutSeconds}` | `true` / `300` | Init container |
| `app.javaOptions` | `""` | `JDK_JAVA_OPTIONS` |
| `app.extraEnv`, `resources`, `service.*`, `ingress.*`, `pdb.*`, `networkPolicy.*`, security contexts, scheduling | | as for Keycloak (management port `9443`) |

## Test client

| Value | Default | Meaning |
|---|---|---|
| `testClient.enabled` | `true` | Render the `helm test` pod |
| `testClient.image.*` ⚙ | `iam-platform/test-client` | Also used by the app's init container |
| `testClient.clientId` | `test-client` | |
| `testClient.checks` | `certs,keycloak,app` | Check groups |
| `testClient.minCertValidDays` | `7` | Fail when a certificate expires sooner |
| `testClient.expectedTlsProtocols` | `TLSv1.3` | |
| `testClient.waitTimeoutSeconds` | `180` | |
| `testClient.extraEnv`, `resources`, security contexts | | |

## Network policy

| Value | Default | Meaning |
|---|---|---|
| `networkPolicy.enabled` | `true` | Render the policies |
| `networkPolicy.allowExternalHttps` | `false` | Open port 8443 of Keycloak and the app to any source |

## SAML request signing

Signing needs three things that belong together:

1. `app.saml.signing.enabled: true`
2. `app.saml.signing.certificate`: the SP certificate as single-line base64
   DER - it is registered in the realm on first import and switches the
   Keycloak client to "signature required"
3. the Secret `<fullname>-saml-sp-tls` (`tls.crt`, `tls.key`, RSA, PKCS#8)

`platform.sh secrets` + `deploy` do all three. With plain Helm:

```bash
kubectl -n iam create secret tls iam-saml-sp-tls --cert=saml-sp.crt --key=saml-sp.key
helm upgrade --install iam helm/iam-platform -n iam \
  --set app.saml.signing.enabled=true \
  --set-string app.saml.signing.certificate="$(openssl x509 -in saml-sp.crt -outform DER | openssl base64 -A)"
```

Enabling signing without a certificate fails the render on purpose.

## `values.schema.json`

Validates enums and shapes Helm would otherwise accept silently:
`certificates.source`, subject field characters and the two-letter country,
key algorithm, `keycloak.database.vendor`, `proxyHeaders`, HTTPS-only public
URLs, `app.clientAuth`, `forwardHeadersStrategy`, replica minimums and the
test client thresholds.

## `values-production.yaml`

An example overlay to copy: cert-manager, Reloader, two replicas each,
external PostgreSQL with `sslmode=verify-full`, public URLs, ingress and
the matching NetworkPolicy peers, zone spreading, a client-certificate
allow-list. Replace the host names, the database Secret and the ingress
namespace label with yours.

## `ci/cert-manager-values.yaml`

A third value set (cert-manager + SAML signing + Reloader) so that
`platform.sh verify` lints and schema-validates those code paths too.
