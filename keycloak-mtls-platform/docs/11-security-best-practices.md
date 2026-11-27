# 11. Security best practices

What this project applies, where, and what remains yours to do.

## Applied

### Transport and identity

| Practice | Where |
|---|---|
| TLS 1.3 (1.2 minimum) on every listener; no plain HTTP | Keycloak options, `application.yaml`, test client |
| Mutual TLS for all service-to-service calls | [architecture](01-architecture.md) |
| No shared secrets for OAuth clients: certificate-based client authentication (RFC 8705) | realm, `OidcClientConfig` |
| Certificate-bound access tokens for machine clients | realm `test-client`, verified by the app and by check KC-08 |
| PKCE (S256) required for the authorization code flow | realm + app |
| Exact redirect URIs, no wildcards | realm |
| Signed SAML responses, assertions and (with signing on) requests | realm, profile `saml-signing` |
| Audience and role checks on the API | `SecurityConfig`, realm audience mapper |
| Hostname verification on, trust limited to the platform CA | app `OutboundTls`, test client |
| Short-lived leaf certificates (90 days) with automated renewal paths | `certs`, cert-manager |

### Keys and secrets

| Practice | Where |
|---|---|
| Private keys never baked into images by default; `push` refuses images that contain them | `CERT_MODE`, `acr.sh` |
| Keys and passwords never on a command line or in logs | `k8s.sh` uses `--from-file` and pipes |
| Key files mode 600, directories 700; `--verify` checks it | `certs.sh` |
| Random bootstrap admin password, created once, never printed | `k8s.sh` / chart |
| The config file is parsed, not executed, and holds no secrets | `common.sh` |
| Least-privilege certificate usages; CA limited to `pathlen:0` | `certs.sh` |

### Supply chain and images

| Practice | Where |
|---|---|
| Immutable image tags (`latest` rejected), deploy by digest, optional tag lock in ACR | config validation, `acr.sh`, `k8s.sh` |
| Registry access through Entra ID identities; admin user unused | `acr.sh` |
| Minimal, explicit build contexts | `images.sh` |
| Multi-stage builds, non-root users, JRE-only runtime images | Dockerfiles |
| Pinned versions for Keycloak, Spring Boot, Maven and plugins | config, POMs, Maven Wrapper |

### Kubernetes

| Practice | Where |
|---|---|
| *Restricted* Pod Security Standard on the namespace | `platform.sh secrets` |
| Non-root, no privilege escalation, capabilities dropped, seccomp `RuntimeDefault` | chart |
| Read-only root filesystem (app, test client) | chart |
| No ServiceAccount token mounted | chart |
| Default-deny NetworkPolicies with explicit flows | chart |
| Resource requests and limits; PodDisruptionBudgets; graceful shutdown | chart |
| Fail-fast guards against unsafe value combinations | `_helpers.tpl`, `values.schema.json` |

### Verification

Negative tests are first-class: the test pod proves that a request
**without** certificate or with a tampered token is rejected (KC-06,
APP-04/05/06), not only that the happy path works.

## Yours to do before production

1. **Database**: external, with TLS verification and backups. The default
   embedded database is for evaluation only.
2. **Certificate lifecycle**: use cert-manager (or your PKI) so renewal is
   automatic; enable Reloader so pods pick up renewed certificates; alert on
   the scheduled test pod.
3. **CA custody**: `build/certs/ca/ca.key` signs everything. Keep it out of
   CI workspaces and laptops: generate it in a controlled place, or let
   cert-manager / a vault hold it.
4. **Secrets at rest**: enable Kubernetes secret encryption (AKS: KMS with
   Key Vault), or source Secrets from Key Vault.
5. **Bootstrap admin**: create personal admin accounts with MFA, then delete
   the temporary admin and its Secret.
6. **Realm hardening**: add your identity providers / user federation,
   require MFA, review token and session lifetimes, enable WebAuthn where
   possible.
7. **Exposure**: put a WAF / ingress in front of the public URLs, restrict
   the Keycloak admin console (`/admin`) to an internal network, and keep
   back-channel traffic in-cluster.
8. **Client-certificate allow-list**: set `app.api.allowedClientSubjects` so
   that not every certificate from the CA may call the API.
9. **Images**: mirror base images into your registry, pin them by digest,
   scan them (Defender for Containers), and rebuild regularly for patches.
   Consider signing images and enforcing signatures at admission.
10. **Revocation**: this private CA publishes no CRL / OCSP. Revocation is
    by short lifetimes, removing a client in Keycloak, and the app's
    allow-list. If you need hard revocation, use a PKI that provides it.
11. **Logging and audit**: ship Keycloak events and application logs to your
    SIEM; keep admin events.

## Deliberate trade-offs

| Choice | Reason | Alternative |
|---|---|---|
| `request` / `want` instead of required client certificates at the TLS layer | browsers must reach the login pages | `KC_HTTPS_CLIENT_AUTH=required`, `app.clientAuth=need` when every caller has a certificate |
| Unencrypted PKCS#8 keys in Secrets | the common format of all three components; protected by Secret RBAC and encryption at rest | a CSI driver that mounts keys from a vault |
| JVM-wide outbound TLS context in the app | covers every HTTP client Spring Security creates, in one place | per-client `RestClient` wiring if the app must also call public endpoints |
| Management ports without client certificates | the kubelet cannot present one | they expose only health (and metrics on Keycloak) and are fenced by NetworkPolicy |
| Keycloak root filesystem writable | Keycloak writes below `/opt/keycloak/data` | add volumes for those paths and switch `readOnlyRootFilesystem` on |
| SAML single logout not configured | keeps the example focused | add `saml2Logout` and the SLO URL in the realm client |
