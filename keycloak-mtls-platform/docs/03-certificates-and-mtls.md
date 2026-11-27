# 3. Certificates and mutual TLS

Created by `platform.sh certs` ([lib-certs](scripts/lib-certs.md)), loaded
into images by `platform.sh build` ([lib-images](scripts/lib-images.md)) and
into the cluster by `platform.sh secrets` ([lib-k8s](scripts/lib-k8s.md)).

## What is created

```
build/certs/
├── ca/           ca.crt  ca.key                    private root CA
├── keycloak/     tls.crt tls.key ca.crt cert.info  server certificate
├── spring-app/   tls.crt tls.key ca.crt cert.info  server + client certificate
├── test-client/  tls.crt tls.key ca.crt cert.info  client certificate
└── saml-sp/      tls.crt tls.key ca.crt cert.info  SAML request-signing certificate
```

| | Key | Key usage | Extended key usage | SANs | Lifetime |
|---|---|---|---|---|---|
| CA | EC P-384 | certSign, cRLSign; `CA:TRUE, pathlen:0` | - | - | 5 years |
| keycloak | EC P-256 | digitalSignature | serverAuth | Service names, `localhost`, `127.0.0.1`, public host, extras | 90 days |
| spring-app | EC P-256 | digitalSignature | serverAuth, clientAuth | same pattern | 90 days |
| test-client | EC P-256 | digitalSignature | clientAuth | `<release>-test-client` | 90 days |
| saml-sp | RSA 3072 | digitalSignature | - | - | 2 years |

Design choices:

- **Unencrypted PKCS#8 PEM keys, mode 600.** It is the one key format that
  Keycloak, Spring Boot and the plain-JDK test client all read. Protection
  comes from file permissions, Kubernetes Secrets and short lifetimes.
- **Least-privilege usages.** Keycloak's certificate cannot be used as a
  client certificate; the test client's cannot be used as a server.
- **`pathlen:0`.** The CA can sign leaves but not further CAs.
- **Random 128-bit serial numbers**, SHA-256 signatures.
- **RSA for SAML.** Keycloak verifies SAML client signatures with RSA only,
  so that certificate is RSA regardless of `CERT_KEY_ALG`.
- **Service names in the SANs.** The names are derived from `HELM_RELEASE`,
  `K8S_NAMESPACE` and `CLUSTER_DOMAIN`; hostname verification stays on everywhere.

## Idempotent by design

`platform.sh certs` can run in every pipeline. It issues a certificate only when it is

- missing,
- not signed by the current CA,
- different from the configuration (subject, key type, usages or SAN list -
  recorded in `cert.info`), or
- inside the renewal window (`CERT_RENEW_BEFORE_DAYS`).

The **SAML certificate is never renewed automatically**: Keycloak stores a
copy, so rotation is a deliberate act (see [operations](12-operations.md)).
The CA is never replaced unless you pass `--force-ca`.

`platform.sh certs --verify` checks chain, key/certificate match, expiry,
intended purpose and key file permissions without changing anything.

## Loading certificates into images (`CERT_MODE`)

| Mode | What goes into the image | Use |
|---|---|---|
| `trust` (default) | the CA certificate only | Always safe: it is public data. Private keys arrive at runtime. |
| `baked` | CA + leaf certificate + **private key** | Demos / air-gapped trials. `push` refuses such images unless `--allow-baked-certs`. |
| `none` | nothing | When even the CA should be mounted at runtime. |

Where it lands:

| Image | CA | Leaf (baked only) |
|---|---|---|
| Keycloak | `/opt/keycloak/conf/truststores/ca.crt` (Keycloak's truststore directory) | `/etc/platform/tls/` |
| Spring app, test client | `/etc/platform/trust/ca.crt` **and** imported into the JVM `cacerts` | `/etc/platform/tls/` (+ `/etc/platform/saml/` for the app) |

Every image is labelled `io.platform.cert-mode=<mode>`; that label is what
`push` checks.

## Getting certificates into pods (`CERT_SOURCE`)

| Source | How | When |
|---|---|---|
| `secret` (default) | `platform.sh secrets` creates `kubernetes.io/tls` Secrets `<release>-{keycloak,spring-app,test-client,saml-sp}-tls` with `tls.crt`, `tls.key`, `ca.crt` | Simple setups, CI, evaluation. You rotate by re-running `certs` + `secrets`. |
| `cert-manager` | The chart creates `Certificate` resources; cert-manager issues and renews Secrets of the same shape | Production. Either bootstraps its own CA or uses your Issuer. |
| `image` | Nothing is mounted; the baked files are used | Demos only. |

Pods mount the Secret read-only at `/etc/platform/tls` with mode `0440`; the
pod `fsGroup` gives the unprivileged container user access.

With `cert-manager`, `platform.sh secrets` loads only the SAML signing
certificate (and the admin Secret): cert-manager owns the mTLS Secrets.

## How each component uses its certificate

| Component | Inbound | Outbound |
|---|---|---|
| Keycloak | `https-certificate-file` / `-key-file`; client certificates validated against `truststore-paths`; files re-read hourly (`https-certificates-reload-period`) | `truststore-paths` |
| Spring app | Spring SSL bundle `server` (PEM), `reload-on-update: true` | JVM default `SSLContext` built once from the same files ([details](06-spring-app.md#outbound-mtls)) |
| Test client | - | Builds its `SSLContext` from the three files; trusts only that CA |

Because the app's outbound context is built at start-up, restart the app
after its certificate is renewed. The chart can add
[Reloader](https://github.com/stakater/Reloader) annotations
(`certificates.reloader: true`) to do that automatically.

## Using your own PKI

- **cert-manager with a corporate issuer**: set
  `certificates.certManager.issuerRef` (name, kind) and
  `certificates.issuerDn` to the issuing CA's subject DN in RFC 2253 form.
- **Certificates from elsewhere**: create Secrets with the names and keys
  above yourself and skip `platform.sh certs` / `secrets`. Requirements:
  PKCS#8 keys, the subject DNs configured in `certificates.subject`, SANs
  covering the Service names.
- Subject DNs matter: Keycloak authenticates `spring-app` and `test-client`
  by exact subject and issuer DN. If your PKI uses different subjects, change
  the realm clients accordingly ([realm](05-keycloak-realm.md)).

## Optional PKCS#12 stores

`platform.sh certs --pkcs12` also writes `keystore.p12`, `truststore.p12` and
a random `keystore.password` (mode 600) next to each certificate, for JVM
software that cannot read PEM. Nothing in this project needs them.
