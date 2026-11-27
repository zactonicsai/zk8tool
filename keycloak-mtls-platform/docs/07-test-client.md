# 7. Test client (Java 25)

Source: [`apps/test-client`](../apps/test-client). A command-line program
with **no third-party dependencies** (JDK only: `java.net.http`, JSSE, JCA,
the built-in XML parser). It runs as the `helm test` pod, and with
`--wait-only` as the app's init container.

## What it checks

Each check prints `[PASS]`, `[FAIL]` or `[SKIP]` with a detail line. A failed
check never stops the run; later checks that depend on it are skipped.

### Certificates (offline)

| ID | Check |
|---|---|
| CERT-01 | The private key belongs to the client certificate (sign / verify round trip) |
| CERT-02 | The certificate chains to the configured CA (PKIX validation) |
| CERT-03 | The certificate is valid now and for at least `MIN_CERT_VALID_DAYS` more |
| CERT-04 | It may be used for TLS client authentication (EKU `clientAuth`, key usage, not a CA) |
| CERT-05 | Every certificate in the CA bundle is a CA certificate and still valid |

### Keycloak

| ID | Check |
|---|---|
| KC-01 | Reachable over TLS; negotiated protocol is accepted; server certificate chains to the CA, matches the host name and is not about to expire |
| KC-02 | Management interface reports ready (`/health/ready`) |
| KC-03 | OIDC discovery: expected issuer, HTTPS endpoints, `tls_client_auth` supported, certificate-bound tokens advertised |
| KC-04 | JWK Set is served and has signing keys |
| KC-05 | Client-credentials grant succeeds **with** the client certificate |
| KC-06 | The same request **without** a client certificate is rejected |
| KC-07 | Access token: signature verifies against the JWK Set; issuer, `azp`, audience and expiry are right |
| KC-08 | The token is bound to this certificate (`cnf.x5t#S256` = SHA-256 of the certificate) |
| KC-09 | The token carries the expected realm role |
| KC-10 | SAML IdP metadata: well formed, expected entity ID, valid signing certificate, HTTPS endpoints, POST binding |

### Spring app

| ID | Check |
|---|---|
| APP-01 | Reachable over TLS with a trusted, valid certificate |
| APP-02 | Readiness reported on the management port |
| APP-03 | API accepts client certificate + bound token; response names this client |
| APP-04 | API without token → 401 |
| APP-05 | API without client certificate → 401/403 (or the handshake is refused) |
| APP-06 | API with a tampered token → 401 |
| APP-07 | OIDC login redirects to Keycloak's authorization endpoint with PKCE, state and nonce |
| APP-08 | SAML login sends an AuthnRequest to one of the IdP's SSO endpoints (and reports whether it is signed) |
| APP-09 | SAML SP metadata is published |
| APP-10 | A protected page redirects anonymous users to `/login` |

The negative checks (KC-06, APP-04/05/06) matter most: they prove that
mutual TLS and token validation are *enforced*, not merely available.

## Settings (environment variables)

| Variable | Default | Meaning |
|---|---|---|
| `KEYCLOAK_URL` | required | URL the client connects to (in-cluster Service) |
| `KEYCLOAK_REALM` | `platform` | realm |
| `KEYCLOAK_ISSUER` | `<KEYCLOAK_URL>/realms/<realm>` | issuer expected in discovery and tokens (the public URL when one is set) |
| `KEYCLOAK_MGMT_URL` | - | management interface; KC-02 is skipped without it |
| `APP_URL` | - | app base URL; all APP checks are skipped without it |
| `APP_MGMT_URL` | - | app management port; APP-02 is skipped without it |
| `APP_REGISTRATION_ID` | `keycloak` | registration id in the app's login URLs |
| `OIDC_CLIENT_ID` | `test-client` | client for the client-credentials grant |
| `EXPECTED_AUDIENCE` | `spring-app` | audience the token must carry |
| `EXPECTED_ROLE` | `api-read` | realm role the token must carry |
| `TLS_CERT_FILE` / `TLS_KEY_FILE` / `TLS_CA_FILE` | `/etc/platform/tls/{tls.crt,tls.key,ca.crt}` | PEM files; the key must be unencrypted PKCS#8 |
| `MIN_CERT_VALID_DAYS` | `7` | minimum remaining lifetime of any certificate seen |
| `EXPECTED_TLS_PROTOCOLS` | `TLSv1.3` | accepted negotiated versions, comma separated |
| `HTTP_TIMEOUT_SECONDS` | `10` | per-request timeout |
| `WAIT_TIMEOUT_SECONDS` | `120` | how long to wait for Keycloak / the app to answer before testing |
| `CHECKS` | `certs,keycloak,app` | groups to run |
| `REPORT_JUNIT_FILE` | - | also write a JUnit XML report there |

## Exit codes

| Code | Meaning |
|---|---|
| 0 | every check passed or was skipped |
| 1 | at least one check failed (or `--wait-only` timed out) |
| 2 | invalid setting, unreadable certificate material, unknown argument |

## Modes

```
java -jar test-client.jar              run the checks and print the report
java -jar test-client.jar --wait-only  wait until Keycloak answers over mutual TLS, then exit
```

## Running it

In the cluster:

```bash
./scripts/platform.sh test          # = helm test <release> --logs
```

From a workstation against a port-forwarded Keycloak (its certificate has a
`localhost` SAN):

```bash
kubectl -n iam port-forward svc/iam-keycloak 8443:8443 9000:9000 &
cd apps && ./mvnw -q -pl test-client package
KEYCLOAK_URL=https://localhost:8443 \
KEYCLOAK_MGMT_URL=https://localhost:9000 \
KEYCLOAK_ISSUER=https://iam-keycloak.iam.svc.cluster.local:8443/realms/platform \
TLS_CERT_FILE=../build/certs/test-client/tls.crt \
TLS_KEY_FILE=../build/certs/test-client/tls.key \
TLS_CA_FILE=../build/certs/test-client/ca.crt \
java -jar test-client/target/test-client.jar
```

Sample output:

```
[PASS] KC-05   Client-credentials grant succeeds with mTLS client authentication (58 ms)
       client test-client, expires in 120 s
[PASS] KC-06   Token endpoint rejects the same request without a client certificate (88 ms)
       rejected with HTTP 401 (invalid_client)
...
Summary: 25 passed, 0 failed, 0 skipped in 2.1 s
```

## Code map

| Class | Role |
|---|---|
| `TestClient` | entry point, modes, summary, exit code |
| `Config` | settings from the environment, with validation |
| `Pem`, `TlsMaterial` | PEM parsing; TLS contexts with and without client certificate; thumbprint |
| `Http` | thin `HttpClient` wrapper: no redirects, hostname verification on |
| `Json`, `Jwt` | small strict JSON parser; JWT parsing and RS/ES signature verification |
| `CheckRunner` | runs checks, records results, flattens exception cause chains |
| `CertificateChecks`, `KeycloakChecks`, `AppChecks` | the checks |
| `Wire` | TLS session inspection, XXE-safe XML parsing, readiness polling |
| `JunitReport` | JUnit XML output |

Safety properties of the client itself: it trusts only the configured CA,
never follows redirects, parses XML with DTDs and external entities
disabled, and rejects `alg: none` and symmetric JWT algorithms.

## Tests

54 JUnit 5 tests (`./mvnw -pl test-client verify`). `TestClientEndToEndTest`
starts `FakePlatform`, an in-process HTTPS server with real mutual TLS that
plays Keycloak and the app, runs the whole client against it, then breaks
one thing at a time (token endpoint without certificate enforcement, API
without mTLS, wrong audience, unbound token, missing PKCE, wrong issuer,
untrusted server certificate) and asserts that exactly the matching check fails.
