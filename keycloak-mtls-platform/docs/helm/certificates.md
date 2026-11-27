# `templates/certificates/certificates.yaml`

Rendered only with `certificates.source=certManager`. Requires
[cert-manager](https://cert-manager.io) in the cluster.

## What it creates

Without an existing issuer (`certificates.certManager.issuerRef.name` empty)
the chart bootstraps its own CA:

| # | Kind | Name | Purpose |
|---|---|---|---|
| 1 | Issuer | `<fullname>-selfsigned` | signs only the CA certificate |
| 2 | Certificate | `<fullname>-ca` (`isCA: true`) | the platform CA; Secret `<fullname>-ca` |
| 3 | Issuer | `<fullname>-ca` | issues the leaves from that CA |

Then one Certificate per enabled workload:

| Certificate / Secret | Common name | Usages | DNS names |
|---|---|---|---|
| `<fullname>-keycloak-tls` | `keycloak` | digital signature, server auth | Service names (short, `.ns`, `.ns.svc`, FQDN), `localhost`, public host, ingress host; IP `127.0.0.1` |
| `<fullname>-spring-app-tls` | `spring-app` | digital signature, server auth, client auth | same pattern |
| `<fullname>-test-client-tls` | `test-client` | digital signature, client auth | `<fullname>-test-client` |

(RSA keys add `key encipherment`.)

The resulting Secrets have exactly the shape `platform.sh secrets` produces
(`tls.crt`, `tls.key`, `ca.crt`), so the workloads are identical in both modes.

## Settings that matter

| Setting | Why |
|---|---|
| `privateKey.encoding: PKCS8` | the one key format Keycloak, Spring Boot and the test client all read (cert-manager's default is PKCS#1) |
| `privateKey.rotationPolicy: Always` | a new key at every renewal |
| `duration: 2160h`, `renewBefore: 720h` | 90-day certificates, renewed 30 days early |
| `subject.organizations / organizationalUnits / countries` + `commonName` | produce the subject DNs Keycloak's X.509 client authentication expects (`CN=spring-app,OU=…,O=…,C=…`) |
| CA key: ECDSA P-384 (or RSA 4096), `caDuration: 43800h` | longer-lived, stronger than the leaves |

## Using an existing issuer

```yaml
certificates:
  source: certManager
  issuerDn: "CN=Corp Issuing CA,O=Corp,C=US"     # subject of the issuing CA, RFC 2253
  certManager:
    issuerRef:
      name: corp-issuer
      kind: ClusterIssuer
```

Only the three leaf Certificates are created. Two things to check with a
corporate issuer:

1. It must honour the requested subject (some issuers override O/OU). If it
   does not, set `certificates.subject` to what it issues, or adjust the
   realm clients.
2. `ca.crt` in the issued Secrets must contain the CA that also issued the
   **other** workloads' certificates; otherwise mount a CA bundle
   (trust-manager is the usual tool).

## The SAML signing certificate

Not managed here: its rotation needs a matching change in Keycloak, so it
stays a deliberate operation ([operations](../12-operations.md#rotate-the-saml-signing-certificate)).
`platform.sh secrets` loads it in cert-manager mode too.

## Renewal and restarts

cert-manager renews the Secrets; Keycloak and the app's server side pick
the new files up, the app's outbound side needs a restart
([why](../06-spring-app.md#outbound-mtls)). Set `certificates.reloader: true`
with Stakater Reloader installed.

## Bootstrapped CA: first-install ordering

All resources are created together. cert-manager resolves the chain by
itself (CA certificate → CA issuer → leaves); pods stay in
`ContainerCreating` until their Secret exists, which typically takes a few
seconds.

## Tests

`tests/certificates_test.yaml` (11 cases): nothing rendered for `secret` /
`image`; bootstrap chain; names, subject, usages, DNS names and IPs of each
certificate; PKCS#8 and rotation policy; public and ingress host names;
existing issuer; RSA variant; disabled components.
