# `templates/app/`

## `deployment.yaml`

**Init container `wait-for-keycloak`** (when `app.waitForKeycloak.enabled`):
the test-client image with `--wait-only`. It mounts the app's own
certificate and waits until Keycloak answers over mutual TLS (up to
`timeoutSeconds`). The app reads the SAML IdP metadata while starting, so
this gives a clean first install instead of a crash loop, and it proves
before start-up that the app's certificate and CA are accepted. Its logs
(`kubectl logs … -c wait-for-keycloak`) show the exact TLS error if not.

**Environment of the app container**:

| Variable | Value |
|---|---|
| `KEYCLOAK_INTERNAL_URL` | Keycloak Service URL |
| `KEYCLOAK_PUBLIC_URL` | Keycloak public URL |
| `KEYCLOAK_REALM` | `keycloak.realm.name` |
| `APP_PUBLIC_URL` | app public URL |
| `OIDC_CLIENT_ID` | `app.oidc.clientId` |
| `SAML_ENTITY_ID` | `<app public URL>/saml2/service-provider-metadata/keycloak` (same value the realm gets) |
| `SPRING_PROFILES_ACTIVE` | `saml-signing`, only when signing is effective |
| `PLATFORM_TLS_CLIENT_AUTH` | `app.clientAuth` |
| `SERVER_FORWARD_HEADERS_STRATEGY` | `app.forwardHeadersStrategy` |
| `API_AUDIENCE`, `API_REQUIRED_ROLE` | `app.api.*` |
| `API_ALLOWED_CLIENT_SUBJECTS` | `app.api.allowedClientSubjects` joined with `;` (subject DNs contain commas) |
| `JDK_JAVA_OPTIONS` | `app.javaOptions`, when set |
| `app.extraEnv` | appended |

What each setting does in the application: [Spring app](../06-spring-app.md#settings).

**Ports**: `https` 8443, `management` 9443.

**Probes**: `/actuator/health/liveness` (startup, liveness) and
`/actuator/health/readiness`, HTTPS on the management port.

**Rollout**: `maxUnavailable: 0`, `maxSurge: 1`; a `preStop` sleep of 5 s
lets endpoint removal propagate before Spring's graceful shutdown starts;
`terminationGracePeriodSeconds: 45`.

**Volumes**:

| Volume | Mount | When |
|---|---|---|
| `tls` (Secret `<fullname>-spring-app-tls`, 0440) | `/etc/platform/tls` | unless `certificates.source=image` |
| `saml` (Secret `<fullname>-saml-sp-tls`, 0440) | `/etc/platform/saml` | SAML signing on |
| `tmp` (emptyDir, 64Mi) | `/tmp` | always; the root filesystem is read-only |

**Security context**: uid/gid 10001, non-root, read-only root filesystem,
`RuntimeDefault` seccomp, no privilege escalation, capabilities dropped, no
ServiceAccount token.

## `service.yaml`

`<fullname>-spring-app`: `https` 8443 (TLS terminated by the app, so client
certificates reach it) and `management` 9443 (health; fenced by the
NetworkPolicy).

## `pdb.yaml`

PodDisruptionBudget when `app.replicas > 1`.

## `ingress.yaml`, `networkpolicy.yaml`

See [ingress](ingress.md) and [network policies](network-policies.md).

## Tests

`tests/app_test.yaml` (19 cases): default and public URLs, certificate and
`/tmp` mounts, read-only root, SAML signing off/on and with baked
certificates, allow-list joining, init container on/off, probes, extra JVM
options and environment, rollout strategy, Service ports and selector, PDB,
Ingress and its guard.
