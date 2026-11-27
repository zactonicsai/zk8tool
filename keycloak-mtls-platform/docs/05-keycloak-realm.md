# 5. Keycloak realm

File: [`docker/keycloak/realm/platform-realm.json`](../docker/keycloak/realm/platform-realm.json).
It is baked into the Keycloak image and imported on first start
(`--import-realm`).

## Placeholders

The file contains `${NAME}` placeholders that Keycloak resolves from
environment variables at import time. The chart sets them
([keycloak templates](helm/keycloak.md)):

| Placeholder | Value in the cluster | Used for |
|---|---|---|
| `KC_REALM_NAME` | `keycloak.realm.name` | realm name |
| `APP_BASE_URL` | public URL of the app | redirect URIs, SAML ACS URL |
| `APP_CLIENT_CERT_SUBJECT_DN` | `CN=spring-app,OU=…,O=…,C=…` | X.509 identity of the OIDC client |
| `TEST_CLIENT_CERT_SUBJECT_DN` | `CN=test-client,OU=…,O=…,C=…` | X.509 identity of the test client |
| `CLIENT_CERT_ISSUER_DN` | subject DN of the CA | issuer the client certificates must have |
| `SAML_SP_ENTITY_ID` | `<app public URL>/saml2/service-provider-metadata/keycloak` | client ID of the SAML client |
| `SAML_CLIENT_SIGNATURE_REQUIRED` | `true` when a signing certificate is configured | whether AuthnRequests must be signed |
| `SAML_SP_SIGNING_CERT` | base64 DER of the SP signing certificate | verifies AuthnRequest signatures |

## Realm settings

`sslRequired: all`, self-registration off, brute-force detection on,
password policy `length(12) and notUsername and passwordHistory(5)`, access
tokens valid 5 minutes, refresh-token rotation (`revokeRefreshToken`), login
and admin events recorded for 7 days.

The realm contains **no users** and no default credentials. Create users in
the admin console or with `kcadm.sh`.

## Clients

### `spring-app` - OpenID Connect

| Setting | Value | Why |
|---|---|---|
| Flow | authorization code only | implicit, password and device grants are off |
| Client authentication | **X.509 certificate** (`client-x509`) | the mTLS certificate is the credential; there is no secret to leak or rotate |
| `x509.subjectdn` / `x509.casubjectdn` | exact subject / issuer DN | only that certificate from that CA is accepted |
| PKCE | `S256` required | protects the authorization code |
| Redirect URI | `<app>/login/oauth2/code/keycloak` | exact, no wildcard |
| Post-logout redirect | `<app>/*` | for RP-initiated logout |
| `fullScopeAllowed` | false | tokens carry only what is mapped |

### SAML client (client ID = SP entity ID)

| Setting | Value |
|---|---|
| Binding | POST (`saml.force.post.binding`) |
| Signatures | responses **and** assertions signed with RSA-SHA256 by the realm key |
| Client signature | required when `SAML_CLIENT_SIGNATURE_REQUIRED=true`; verified with `saml.signing.certificate` |
| NameID | username |
| ACS URL | `<app>/login/saml2/sso/keycloak` (the only valid redirect) |
| Mappers | `email` attribute; plus Keycloak's default `role_list` scope |

Single logout is not configured: SAML sessions are ended locally by the app.

### `test-client` - service account

| Setting | Value | Why |
|---|---|---|
| Flow | client credentials only | machine-to-machine |
| Client authentication | X.509 certificate | as above |
| Certificate-bound tokens | on (`tls.client.certificate.bound.access.tokens`) | a stolen token is useless without the private key |
| Token lifetime | 120 s | it only runs tests |
| Audience mapper | adds `spring-app` to `aud` | the app accepts only tokens meant for it |
| Role | realm role `api-read` (service-account user + scope mapping) | what the app's API requires |

## How X.509 client authentication works

1. Keycloak is built with `https-client-auth=request`, so a client *may*
   present a certificate during the TLS handshake; it is validated against
   the truststore (the platform CA).
2. At the token endpoint the client sends only `client_id`. The `client-x509`
   authenticator compares the certificate's subject DN with `x509.subjectdn`
   and its issuer with `x509.casubjectdn`.
3. No certificate, wrong subject or wrong issuer → `401 invalid_client`.

DNs are compared in RFC 2253 form: `CN=test-client,OU=Platform,O=Example Corp,C=US`.
Print yours with:

```bash
openssl x509 -in build/certs/test-client/tls.crt -noout -subject -issuer -nameopt RFC2253
```

Behind a TLS-terminating proxy Keycloak cannot see the client certificate
directly; configure the proxy to forward it and Keycloak's
`spi-x509cert-lookup` provider accordingly, or keep back-channel traffic
in-cluster (the default here), where the pod terminates TLS itself.

## Changing the realm after the first start

`--import-realm` **never overwrites an existing realm**. Editing the JSON
changes new installations only. For an existing realm use one of:

- the admin console or `kcadm.sh` (ad hoc),
- [keycloak-config-cli](https://github.com/adorsys/keycloak-config-cli) or
  Terraform (declarative, recommended for GitOps),
- a partial import in the admin console.

Typical follow-up changes: adding users / identity providers, registering a
rotated SAML signing certificate, adding API clients:

```bash
kcadm.sh update clients/<id> -r platform \
  -s 'attributes."saml.signing.certificate"=<base64 DER>'
```

## Adding another API client

Copy the `test-client` block, change `clientId` and `x509.subjectdn`, issue a
client certificate with that subject from the same CA, and give its service
account the roles it needs. If you restrict
`app.api.allowedClientSubjects`, add the new subject there too.

## Bootstrap admin

Keycloak creates a temporary admin from the Secret
`<release>-keycloak-admin` on first start. Log in, create a personal admin
account with MFA, then delete the temporary user and the Secret.
