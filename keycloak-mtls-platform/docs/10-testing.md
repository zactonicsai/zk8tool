# 10. Testing

Every part of the project has tests. One command runs everything that needs
no cluster:

```bash
./scripts/platform.sh verify            # all suites
./scripts/platform.sh verify --only bats,helm
./scripts/platform.sh verify --strict   # CI: a missing tool is a failure
```

## Overview

| Layer | Suite | Tool | Count | Needs |
|---|---|---|---|---|
| Scripts | static analysis | shellcheck | all `*.sh` / `*.bash` | - |
| Scripts | [`tests/scripts/*.bats`](../tests/scripts) | bats | 107 | openssl |
| Dockerfiles | lint | hadolint | 3 files | - |
| Helm chart | `helm lint --strict` | Helm | 3 value sets | - |
| Helm chart | [`helm/iam-platform/tests`](../helm/iam-platform/tests) | helm-unittest | 91 | - |
| Helm chart | schema validation | kubeconform | 3 value sets | - |
| Test client | [`apps/test-client/src/test`](../apps/test-client/src/test) | JUnit 5 | 54 | JDK 25 |
| Spring app | [`apps/spring-app/src/test`](../apps/spring-app/src/test) | JUnit + MockMvc | 37 | JDK 25 |
| Deployed system | `helm test` pod | Java 25 test client | 25 checks | cluster |

`platform.sh verify` prints a table (`PASS` / `FAIL` / `SKIP`) and exits
non-zero when a step fails.

## Script tests (bats)

Each test runs `platform.sh` in a sandbox: a temp directory with its own
config, build and certificate directories and **stubs** for `docker`, `az`,
`kubectl` and `helm` that record their command line. openssl is real, so
certificates are really generated and inspected.

| File | Covers |
|---|---|
| `cli_config.bats` | command line, help, config parsing and precedence, validation, `clean` safety |
| `certs.bats` | CA and leaf profiles, SANs, key format and permissions, idempotency, renewal, drift detection, `--verify` failure modes, PKCS#12 |
| `build_push.bats` | staged contexts per `CERT_MODE`, docker arguments, manifests, ACR login / tag / push / lock / ACR build, refusal of images with private keys, AKS helpers |
| `k8s.bats` | Secrets from files (never on a command line), admin Secret, cert-manager mode, generated Helm values, `helm` arguments, the `all` pipeline |

```bash
bats tests/scripts                 # all
bats tests/scripts/certs.bats      # one file
bats -f "baked" tests/scripts      # by name
```

## Java tests

```bash
cd apps
./mvnw verify                 # both modules
./mvnw -pl test-client verify
./mvnw -pl spring-app verify
```

- **Test client**: unit tests for the JSON parser, PEM reader, JWT
  verification, settings and report, plus `TestClientEndToEndTest`, which
  runs the whole client against an in-process HTTPS server with real mutual
  TLS and injects one misconfiguration at a time
  ([details](07-test-client.md#tests)).
- **Spring app**: MockMvc tests of both security filter chains, the SAML
  signing profile, and unit tests of the security components
  ([details](06-spring-app.md#tests)). No Keycloak is needed.

### Certificate fixtures

Both modules use committed test certificates in `src/test/resources/certs`
(a CA, server and client certificates, a certificate from an untrusted CA,
one without client usage, an RSA signing pair). They are valid for 100
years, trusted by nothing and must never be used elsewhere. Regenerate with:

```bash
tests/fixtures/generate-test-certs.sh
```

## Chart tests

```bash
helm plugin install https://github.com/helm-unittest/helm-unittest   # once
helm unittest helm/iam-platform
```

See [chart tests](helm/chart-tests.md) for what each suite asserts.

## In-cluster test

```bash
./scripts/platform.sh test     # helm test <release> --logs
```

Runs the [25 checks](07-test-client.md#what-it-checks) from inside the
cluster, through the real NetworkPolicies, with the real certificates. Run
it after every deploy and on a schedule: CERT-03 and the TLS checks fail
once a certificate is closer to expiry than `testClient.minCertValidDays`,
which makes it a certificate-expiry alarm as well.

For a recurring check, create a CronJob from the same pod spec, or run
`helm test` from your pipeline scheduler.

## CI outline

```yaml
jobs:
  verify:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-java@v4
        with: { distribution: temurin, java-version: "25" }
      - run: |
          sudo apt-get update && sudo apt-get install -y bats shellcheck
          # install hadolint, helm, helm-unittest and kubeconform here
      - run: ./scripts/platform.sh verify --strict
```

## What was and was not executed for this repository

See the [verification status](../README.md#verification-status) in the
README. In short: the script suites, the test client (on JDK 25, against a
real Keycloak 26.8.2) and the chart logic were exercised; the Maven builds,
the Spring Boot tests, Docker builds and real Helm were not available in the
environment this was produced in. Your first `platform.sh verify` closes
that gap.

## Adding tests

- New script behaviour → a bats test using `platform`, `set_config` and
  `stub_calls` from `tests/scripts/test_helper.bash`.
- New chart value → a case in the matching `helm/iam-platform/tests/*_test.yaml`.
- New check in the test client → implement it in `FakePlatform` too and add
  a happy-path and a failure case to `TestClientEndToEndTest`.
