# 6. Spring Boot app (Java 25)

Source: [`apps/spring-app`](../apps/spring-app). Spring Boot 4.2, Spring
Security 7.2, Java 25, embedded Tomcat.

> Not compiled in the environment this repository was produced in (no access
> to Maven Central). Run `./mvnw -pl spring-app verify` in `apps/` first; see
> the verification table in the [README](../README.md#verification-status).

## What it does

| Path | Access | Purpose |
|---|---|---|
| `/`, `/login` | public | page with the two sign-in links |
| `/oauth2/authorization/keycloak` | public | starts the OIDC login |
| `/login/oauth2/code/keycloak` | public | OIDC callback |
| `/saml2/authenticate/keycloak` | public | starts the SAML login |
| `/login/saml2/sso/keycloak` | public | SAML assertion consumer service |
| `/saml2/metadata/keycloak` | public | SAML SP metadata |
| `/me` | signed-in user | name, protocol used (`oidc` / `saml2`), authorities |
| `POST /logout` | signed-in user (CSRF token required) | local logout; OIDC sessions are also ended at Keycloak |
| `/api/v1/whoami` | client certificate **and** JWT with role `api-read` | machine API |
| `:9443/actuator/health/**`, `/actuator/info` | public (management port) | probes |

## Code map

| Class | Role |
|---|---|
| `PlatformApplication` | `main`; installs outbound mTLS, then starts Spring |
| `OutboundTls` | builds the JVM default `SSLContext` from the PEM files |
| `config/PlatformProperties` | typed, validated `platform.*` settings |
| `security/SecurityConfig` | the two security filter chains |
| `security/OidcClientConfig` | OIDC client registration and token-endpoint client |
| `security/ClientCertificateAuthorizationManager` | "request arrived with a trusted client certificate" rule |
| `security/KeycloakRealmRoleConverter` | `realm_access.roles` → `ROLE_*`, `scope` → `SCOPE_*` |
| `web/LoginController`, `MeController`, `ApiController` | the endpoints above |

## Security design

### Two filter chains

1. **`/api/**`** - stateless, no session, CSRF off (nothing to ride on).
   Access needs *all* of:
   - a valid Keycloak JWT (signature via JWKS, issuer, audience `spring-app`, expiry),
   - the realm role `api-read`,
   - a client certificate on the TLS connection (optionally on an allow-list),
   - if the token carries `cnf.x5t#S256`, the presented certificate must
     match it. Spring Security's default JWT validators do this check.
2. **everything else** - browser sessions with `oauth2Login` and
   `saml2Login`. Both share the `/login` page so the entry point is
   predictable with two mechanisms active.

### OIDC client without a secret

`OidcClientConfig` registers the client with
`ClientAuthenticationMethod.TLS_CLIENT_AUTH`: at the token endpoint only
`client_id` is sent and the TLS client certificate authenticates the app.
PKCE is switched on (`requireProofKey`).

Endpoints are configured explicitly rather than discovered from the issuer:

- browser-facing endpoints (authorization, logout) use the **public** URL,
- back-channel endpoints (token, JWKS, userinfo) use the **internal** URL,
- no network call happens at start-up for OIDC,
- the issuer is still set, so the ID token's `iss` is validated.

### Outbound mTLS

Spring Security creates several HTTP clients internally (token, JWKS,
userinfo, SAML metadata). All of them fall back to the JVM default
`SSLContext`, so `OutboundTls` installs one default context in `main` that

- presents the app's certificate, and
- trusts only the platform CA.

One place, no per-client wiring, no secret. Trade-offs to know:

- The app cannot call public HTTPS endpoints unless their CA is added to the
  CA bundle file.
- The context is built once. After a certificate renewal the **inbound**
  side reloads by itself (`reload-on-update`), outbound calls use the old
  certificate until the pod restarts. Use Reloader
  (`certificates.reloader: true`) or restart the Deployment on renewal.
- If the certificate files are absent (local development), a warning is
  logged and the JVM defaults stay in place.

### SAML

- IdP metadata is loaded from Keycloak at start-up
  (`…/protocol/saml/descriptor`). The chart's init container waits for
  Keycloak so the app does not crash-loop on first install.
- Entity ID and ACS URL are fixed from `APP_PUBLIC_URL`, not derived from the
  request's Host header.
- Profile **`saml-signing`** adds the signing credential and signs
  AuthnRequests. It must be active whenever Keycloak requires client
  signatures (the chart ties the two together).
- The session cookie is `Secure; HttpOnly; SameSite=None`: the SAML response
  arrives as a cross-site POST and must carry the session that holds the
  pending request.

### Server TLS

SSL bundle `server` from the three PEM files, TLS 1.3/1.2,
`client-auth: want` (configurable), automatic reload when the files change.
The management port (9443) uses the same certificate and asks for no client
certificate.

## Settings

Set through environment variables (the chart does this); defaults in
[`application.yaml`](../apps/spring-app/src/main/resources/application.yaml).

| Variable | Default | Meaning |
|---|---|---|
| `KEYCLOAK_INTERNAL_URL` | required | Keycloak base URL for back-channel calls |
| `KEYCLOAK_PUBLIC_URL` | = internal | Keycloak base URL for browsers; token issuer |
| `KEYCLOAK_REALM` | `platform` | realm |
| `APP_PUBLIC_URL` | required | browser-facing base URL of the app |
| `OIDC_CLIENT_ID` | `spring-app` | OIDC client ID |
| `SAML_ENTITY_ID` | `<APP_PUBLIC_URL>/saml2/service-provider-metadata/keycloak` | SP entity ID |
| `SAML_IDP_METADATA_URI` | Keycloak descriptor on the internal URL | IdP metadata location |
| `SAML_SIGNING_CERTIFICATE` / `SAML_SIGNING_PRIVATE_KEY` | `file:/etc/platform/saml/tls.{crt,key}` | used by profile `saml-signing` (RSA, PKCS#8) |
| `SPRING_PROFILES_ACTIVE` | - | add `saml-signing` to sign AuthnRequests |
| `PLATFORM_TLS_CERTIFICATE` / `_PRIVATE_KEY` / `_CA` | `file:/etc/platform/tls/{tls.crt,tls.key,ca.crt}` | PEM locations (Spring resource syntax) |
| `PLATFORM_TLS_CLIENT_AUTH` | `want` | `want` or `need` |
| `PLATFORM_TLS_RELOAD` | `true` | reload the server certificate when the files change |
| `API_AUDIENCE` | `spring-app` | required `aud` |
| `API_REQUIRED_ROLE` | `api-read` | required realm role |
| `API_ALLOWED_CLIENT_SUBJECTS` | empty | allow-list of certificate subject DNs, separated by `;` |
| `SERVER_FORWARD_HEADERS_STRATEGY` | `none` | `native` behind a trusted proxy |
| `LOG_LEVEL_SECURITY` | `INFO` | `DEBUG` to trace Spring Security decisions |
| `JDK_JAVA_OPTIONS` | - | extra JVM flags |

Invalid settings (non-HTTPS URL, missing `openid` scope, role with `ROLE_`
prefix) stop the start-up with a message naming the property.

## Building and running locally

```bash
cd apps
./mvnw -pl spring-app verify          # compile + tests (needs JDK 25)
./mvnw -pl spring-app spring-boot:run # needs the environment variables above
```

OpenSAML is published by Shibboleth, not on Maven Central; the POM adds that
repository.

## Tests

| Test class | Covers |
|---|---|
| `SecurityIntegrationTests` | both filter chains through MockMvc: public pages, login redirect, OIDC redirect with PKCE, SAML AuthnRequest and SP metadata, API with/without certificate, token, role, allow-list |
| `SamlSigningProfileTests` | with profile `saml-signing` the AuthnRequest is signed and the metadata carries the certificate |
| `KeycloakRealmRoleConverterTests` | role / scope mapping, malformed claims |
| `ClientCertificateAuthorizationManagerTests` | certificate presence, allow-list, DN normalisation |
| `OutboundTlsTests` | default context installation and its fallbacks |
| `PlatformPropertiesTests` | settings validation |

The tests need no Keycloak: the test profile uses certificate fixtures and an
IdP metadata file captured from Keycloak 26.8
(`src/test/resources`).

## Running more than one replica

Browser sessions live in memory. With `app.replicas > 1` enable session
affinity at the ingress, or add Spring Session with a shared store. The
`/api/**` chain is stateless and needs neither.
