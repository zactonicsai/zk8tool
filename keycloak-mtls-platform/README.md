# Keycloak + Java 25 Spring Boot with mutual TLS

One script builds, publishes and deploys an identity platform in which every
connection is mutually authenticated:

- **Keycloak 26.8** image, pre-built for your database, with a realm that
  authenticates its OIDC clients by **X.509 certificate** (no client secrets).
- **Java 25 / Spring Boot 4.2 app** that signs users in with **OpenID Connect
  and SAML 2.0** against that realm and exposes an API requiring a client
  certificate **and** a certificate-bound access token.
- **Java 25 test client** that runs as the `helm test` pod and proves, from
  inside the cluster, that certificates, mTLS, OIDC and SAML actually work.
- **Certificate tooling** (private CA, leaf certificates, loading into images
  and into Kubernetes), **Azure Container Registry** publishing, and a
  **Helm chart** with network policies and optional cert-manager integration.

```
 browser ──TLS──▶ Spring app ──mTLS──▶ Keycloak ──TLS──▶ database
                     ▲                    ▲
        client cert + bound JWT           │ mTLS client-credentials grant
                     └──── test client ───┘      (helm test pod)
```

## Quick start

```bash
cp config/platform.local.env.example config/platform.local.env   # then edit: ACR_NAME, ...

./scripts/platform.sh doctor            # which tools are installed?
./scripts/platform.sh verify            # run every local test suite first

./scripts/platform.sh certs             # private CA + mTLS certificates  -> build/certs
./scripts/platform.sh build             # three images, CA loaded into each
./scripts/platform.sh push              # tag + push to Azure Container Registry
./scripts/platform.sh aks-credentials   # kubeconfig for the configured AKS cluster
./scripts/platform.sh secrets           # namespace + certificate Secrets
./scripts/platform.sh deploy            # helm upgrade --install
./scripts/platform.sh test              # helm test: Java 25 client checks everything
```

Or in one go: `./scripts/platform.sh all --tag 1.0.0`.
Add `--dry-run` before any command to see what it would do without doing it.

No registry (kind, minikube, Docker Desktop)? Leave `ACR_NAME` empty: `all`
skips the push; load the images into the cluster yourself
(`kind load docker-image ...`).

## What you need

| For | Tools |
|---|---|
| everything | bash 4+, openssl, git |
| `build` | Docker (or podman / nerdctl) with internet access to Maven Central |
| `push`, `aks-*` | Azure CLI (`az login` done) |
| `secrets`, `deploy`, `test` | kubectl, Helm 3.14+ |
| `verify` | shellcheck, bats, hadolint, helm + helm-unittest plugin, kubeconform, JDK 25 |

## Repository map

| Path | What it is | Docs |
|---|---|---|
| `config/platform.env` | The config file every command reads | [02-configuration](docs/02-configuration.md) |
| `scripts/platform.sh` | The CLI | [scripts/platform](docs/scripts/platform.md) |
| `scripts/lib/*.sh` | One library per concern | [scripts/](docs/scripts/README.md) |
| `docker/keycloak/` | Keycloak Dockerfile + realm import | [04-images](docs/04-images.md), [05-keycloak-realm](docs/05-keycloak-realm.md) |
| `docker/spring-app/`, `docker/test-client/` | Dockerfiles of the Java images | [04-images](docs/04-images.md) |
| `apps/spring-app/` | Java 25 Spring Boot app | [06-spring-app](docs/06-spring-app.md) |
| `apps/test-client/` | Java 25 test client | [07-test-client](docs/07-test-client.md) |
| `helm/iam-platform/` | Helm chart | [09-helm-chart](docs/09-helm-chart.md), [helm/](docs/helm/README.md) |
| `tests/scripts/` | bats tests of the scripts | [10-testing](docs/10-testing.md) |
| `tests/fixtures/` | Generator for the Java test certificates | [10-testing](docs/10-testing.md) |

## Documentation

1. [Architecture](docs/01-architecture.md) - components, trust model, flows, ports
2. [Configuration](docs/02-configuration.md) - every key of `platform.env`
3. [Certificates and mTLS](docs/03-certificates-and-mtls.md) - PKI, modes, rotation
4. [Images](docs/04-images.md) - Dockerfiles, build contexts, loading certificates
5. [Keycloak realm](docs/05-keycloak-realm.md) - clients, X.509 client auth, SAML
6. [Spring Boot app](docs/06-spring-app.md) - security design, settings, endpoints
7. [Test client](docs/07-test-client.md) - the 25 checks, settings, exit codes
8. [Azure: ACR and AKS](docs/08-azure-acr-aks.md) - publishing, identities, database
9. [Helm chart](docs/09-helm-chart.md) - install, modes, per-file docs under [docs/helm](docs/helm/README.md)
10. [Testing](docs/10-testing.md) - all test suites and how to run them
11. [Security best practices](docs/11-security-best-practices.md) - what is applied and why
12. [Operations](docs/12-operations.md) - rotation runbooks, upgrades, troubleshooting

## Verification status

What was executed while building this repository, and what was not. Run
`./scripts/platform.sh verify` on your machine before relying on the parts
in the second table.

| Verified by running it | Result |
|---|---|
| shellcheck on all scripts | clean |
| bats suites for the scripts (real openssl, stubbed docker/az/kubectl/helm) | 107 / 107 pass |
| hadolint on the three Dockerfiles | clean |
| Test client compiled with JDK 25 (`-Xlint:all -Werror`) | compiles |
| Test client unit tests (54), executed with a minimal stand-in JUnit runner | 54 / 54 pass |
| Test client against a real Keycloak 26.8.2 (mTLS, this realm file, same settings the chart uses) | 15 / 15 certificate + Keycloak checks pass |
| Realm SAML client: signed, unsigned, wrongly signed AuthnRequests and a foreign ACS URL posted to that Keycloak | accepted / rejected as intended |
| Chart rendered with a stand-in Go template renderer, manifests validated against Kubernetes 1.31 and cert-manager schemas | valid |
| Chart unit test suites (91 tests) interpreted against that renderer | 91 / 91 pass |

| Not executed (no Maven Central, container registry or cluster in the build sandbox) | Mitigation |
|---|---|
| Maven build and the 37 JUnit tests of the Spring Boot app | Code was written against the Spring Boot 4.2.0 / Spring Security 7.2.0 sources and syntax-checked with JDK 25, but never compiled against the real libraries |
| Maven build of the test client with real JUnit 5 | Sources and tests ran on JDK 25 outside Maven |
| `docker build` of the three images | Dockerfiles linted only |
| Real `helm lint`, `helm template`, `helm unittest` | Chart checked with the stand-in renderer only |
| Anything against a cluster or Azure (`push`, `secrets`, `deploy`, `test`) | Command lines are covered by the bats suites with stubbed CLIs |

Treat the first real `platform.sh verify` and `platform.sh all` as the
acceptance test of those parts.
