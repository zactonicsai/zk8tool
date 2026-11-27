# 12. Operations

## Day-2 runbooks

### Rotate the mTLS certificates (`CERT_SOURCE=secret`)

```bash
./scripts/platform.sh certs            # re-issues leaves inside the renewal window
./scripts/platform.sh certs --force    # ... or all of them now
./scripts/platform.sh secrets          # replaces the Secrets
kubectl -n iam rollout restart statefulset/iam-keycloak deployment/iam-spring-app
./scripts/platform.sh test
```

Keycloak re-reads its certificate files within an hour and the app reloads
its server certificate by itself, but the app's **outbound** context needs
the restart. With `certificates.reloader: true` and Reloader installed, the
restart happens automatically.

Schedule `platform.sh certs && platform.sh secrets` (for example weekly):
nothing changes until a certificate enters the renewal window.

### Rotate with cert-manager

Nothing to run: cert-manager renews `renewBefore` expiry with a new key
(`rotationPolicy: Always`). Enable Reloader so pods restart.

### Rotate the CA

A new CA invalidates everything at once, so overlap old and new:

1. Create the new CA in a separate `CERT_DIR`.
2. Distribute a **bundle** of old + new CA certificates as `ca.crt` in every
   Secret; restart. Everyone now trusts both.
3. Re-issue the leaves from the new CA; update Secrets; restart.
4. Update `x509.casubjectdn` of the Keycloak clients if the CA's subject changed.
5. Remove the old CA from the bundle; restart.

`platform.sh certs --force-ca` does the non-overlapping version (downtime
until everything is redeployed); it is meant for non-production.

### Rotate the SAML signing certificate

It is never renewed automatically, because Keycloak holds a copy.

```bash
./scripts/platform.sh certs --only saml-sp --force
./scripts/platform.sh secrets
# register the new certificate in the existing realm (import does not update it):
CERT=$(openssl x509 -in build/certs/saml-sp/tls.crt -outform DER | openssl base64 -A)
kcadm.sh update clients/<client-uuid> -r platform -s "attributes.\"saml.signing.certificate\"=${CERT}"
kubectl -n iam rollout restart deployment/iam-spring-app
```

Do the Keycloak update and the app restart close together; SAML logins fail
in between.

### Upgrade Keycloak

1. Read the Keycloak migration guide for the target version.
2. Set `KEYCLOAK_VERSION`, then `platform.sh build --only keycloak --tag <new>`,
   `push`, `deploy --tag <new>`.
3. Patch releases within a minor version can roll one pod at a time; for
   minor/major upgrades follow Keycloak's guidance (it may require all pods
   to stop first). Back up the database before.

### Upgrade Spring Boot / Java

Change the parent version in `apps/spring-app/pom.xml` or the Java images in
the config, run `platform.sh verify`, rebuild, deploy.

### Scale

- App: `app.replicas` + ingress session affinity (sessions are in memory).
- Keycloak: `keycloak.replicas` with an external database. Pods discover
  each other through the database (`jdbc-ping`) and encrypt cluster traffic
  themselves.

### Uninstall

```bash
helm uninstall iam -n iam
kubectl -n iam delete secret iam-keycloak-admin iam-keycloak-tls iam-spring-app-tls iam-test-client-tls iam-saml-sp-tls
kubectl -n iam delete pvc -l app.kubernetes.io/instance=iam    # embedded database volume
```

## Troubleshooting

Start with the test pod: its failed check usually names the cause.

```bash
./scripts/platform.sh test
./scripts/platform.sh status
kubectl -n iam logs statefulset/iam-keycloak
kubectl -n iam logs deployment/iam-spring-app -c wait-for-keycloak
kubectl -n iam logs deployment/iam-spring-app
```

| Symptom | Likely cause | Fix |
|---|---|---|
| `PKIX path building failed` / `unable to find valid certification path` | The server's certificate was issued by a CA the caller does not trust (mixed CAs, stale Secret) | `platform.sh certs --verify`; re-run `secrets`; restart pods |
| `No subject alternative DNS name matching …` | Certificate SANs do not cover the host name used (changed release name, namespace or public URL) | `platform.sh certs` (re-issues on SAN drift), `secrets`, restart |
| KC-05 fails with `invalid_client` | Client certificate subject or issuer differs from `x509.subjectdn` / `x509.casubjectdn` | Compare `openssl x509 -noout -subject -issuer -nameopt RFC2253` with the client in Keycloak; align `certificates.subject` / `issuerDn` (new installs) or the client attributes (existing realm) |
| KC-03 fails: unexpected issuer | `keycloak.publicUrl` and the URL Keycloak was started with differ | Deploy both from the same values; check `KC_HOSTNAME` |
| KC-08 fails: no `cnf` claim | Certificate-bound tokens switched off on the client, or a proxy terminates TLS before Keycloak | Enable the client setting; keep back-channel traffic in-cluster or forward the client certificate |
| APP-03 returns 401 | Token audience / issuer mismatch, or bound token presented with another certificate | Check `aud` and `iss` in the token; the caller must use the same certificate for Keycloak and the app |
| APP-03 returns 403 | Missing role, or the certificate subject is not in `app.api.allowedClientSubjects` | Grant the role; extend the allow-list |
| APP-05 fails (request without certificate accepted) | The API does not enforce mTLS | Check `SecurityConfig` changes and `PLATFORM_TLS_CLIENT_AUTH` |
| App pod stuck in `Init:0/1` | Keycloak not ready, NetworkPolicy blocks app → Keycloak, or the app cannot verify Keycloak's certificate | Logs of `wait-for-keycloak` show the exact error |
| App fails at start: `Signing credentials must not be empty` | SAML signing expected but profile / Secret missing | Deploy with `platform.sh deploy`, or set `app.saml.signing.*` consistently |
| SAML login ends with *Invalid requester* at Keycloak | AuthnRequest unsigned or signed with a key Keycloak does not know | Activate `saml-signing`; register the current signing certificate in the realm |
| SAML login ends with *Invalid redirect uri* | ACS URL differs from the client's (app public URL changed after the realm was imported) | Update the SAML client in Keycloak |
| SAML login loops back to the login page | Session cookie not sent with the cross-site POST | Keep `SameSite=None; Secure`; the app must be reached over HTTPS |
| Keycloak: `build time options … differ` | Runtime value for a build option differs from the image | Rebuild the image with the wanted `KC_DB_VENDOR` / `KC_HTTPS_CLIENT_AUTH` |
| Keycloak pod not ready, DB errors | Database unreachable or wrong credentials; egress policy | Check `keycloak.database.*`, the Secret, and the database port in the NetworkPolicy |
| `ImagePullBackOff` | Cluster cannot pull from the registry | `platform.sh aks-attach` or `global.imagePullSecrets` |
| Probes fail although the app is up | Something changed the management port or its TLS | Probes use HTTPS on the `management` port without client certificate |
| Everything times out between pods | NetworkPolicy engine blocks a flow you added | See [network policies](helm/network-policies.md); add `extraIngress` / `extraEgress` |
| `Cannot load certificate material … PRIVATE KEY (SEC1/PKCS#1)` | Key is not PKCS#8 | `openssl pkcs8 -topk8 -nocrypt`, or `privateKey.encoding: PKCS8` in cert-manager |

### Useful one-liners

```bash
# what does a Secret contain?
kubectl -n iam get secret iam-spring-app-tls -o jsonpath='{.data.tls\.crt}' | base64 -d \
  | openssl x509 -noout -subject -issuer -enddate -ext subjectAltName -nameopt RFC2253

# talk to Keycloak like a client would
kubectl -n iam port-forward svc/iam-keycloak 8443:8443 &
curl --cacert build/certs/ca/ca.crt --cert build/certs/test-client/tls.crt --key build/certs/test-client/tls.key \
  -d grant_type=client_credentials -d client_id=test-client \
  https://localhost:8443/realms/platform/protocol/openid-connect/token

# trace Spring Security decisions
helm upgrade iam helm/iam-platform -n iam --reuse-values \
  --set 'app.extraEnv[0].name=LOG_LEVEL_SECURITY' --set 'app.extraEnv[0].value=DEBUG'
```
