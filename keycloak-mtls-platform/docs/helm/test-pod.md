# `templates/tests/`

## `test-client-pod.yaml`

A Pod with the annotation `helm.sh/hook: test`. It is not created at
install time; `helm test <release>` (or `platform.sh test`) creates it, waits
for it to finish and reports its exit code.

- Image: the Java 25 [test client](../07-test-client.md).
- `restartPolicy: Never`: one run, one verdict.
- `helm.sh/hook-delete-policy: before-hook-creation`: the pod and its logs
  stay until the next test run replaces them.
- Rendered only when `testClient.enabled` and `keycloak.enabled`.

**Environment**:

| Variable | Value | Note |
|---|---|---|
| `KEYCLOAK_URL` | Keycloak Service URL | where the client connects |
| `KEYCLOAK_ISSUER` | `<Keycloak public URL>/realms/<realm>` | what it must find in discovery and tokens |
| `KEYCLOAK_REALM` | `keycloak.realm.name` | |
| `KEYCLOAK_MGMT_URL` | Keycloak Service, management port | health check |
| `APP_URL`, `APP_MGMT_URL` | app Service URLs | only when `app.enabled` |
| `OIDC_CLIENT_ID` | `testClient.clientId` | |
| `EXPECTED_AUDIENCE`, `EXPECTED_ROLE` | `app.api.audience`, `app.api.requiredRole` | the token must be usable for the app's API |
| `CHECKS`, `MIN_CERT_VALID_DAYS`, `EXPECTED_TLS_PROTOCOLS`, `WAIT_TIMEOUT_SECONDS` | `testClient.*` | |

Connecting to the Service URL while expecting the public issuer is what
verifies the front-channel / back-channel split when a public URL is set.

**Certificate**: Secret `<fullname>-test-client-tls` at `/etc/platform/tls`
(a client-only certificate, `CN=test-client`).

**Security context**: uid/gid 10001, non-root, read-only root filesystem
with an emptyDir at `/tmp`, capabilities dropped, no ServiceAccount token.

### Using it

```bash
helm test iam -n iam --logs          # or: ./scripts/platform.sh test
kubectl -n iam logs iam-test-client  # the report of the last run
```

Exit code 0 → release verified; non-zero → the log names the failed checks.

Adjust thresholds without changing the image:

```bash
helm upgrade iam helm/iam-platform -n iam --reuse-values \
  --set testClient.minCertValidDays=30 --set testClient.checks=certs\\,keycloak
```

Write a JUnit report (for example to a mounted volume) with
`testClient.extraEnv`: `REPORT_JUNIT_FILE=/tmp/report.xml`.

## `networkpolicy.yaml`

A regular resource (not a hook): it has to exist before `helm test` creates
the pod. It selects the test pod and

- allows **no** ingress,
- allows egress to DNS, to Keycloak on 8443 and 9000, and to the app on
  8443 and 9443.

The matching ingress rules live in the Keycloak and app policies
([network policies](network-policies.md)), so the test exercises the real
network path.

## Tests

`tests/test_client_test.yaml` (8 cases): hook annotations, image, URLs with
and without a public issuer, thresholds from values, certificate mount,
security context, behaviour with the app or the test client disabled.
`tests/networkpolicy_test.yaml` covers the policy.
