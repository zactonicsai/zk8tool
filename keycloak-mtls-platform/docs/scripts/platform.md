# `scripts/platform.sh` - command reference

```
platform.sh [global options] <command> [command options]
```

## Global options (before the command)

| Option | Meaning |
|---|---|
| `-c, --config FILE` | Config file. Default: `config/platform.env`, overridden by `config/platform.local.env` if present |
| `-n, --dry-run` | Print the commands that would change something; run none |
| `-v, --verbose` | Debug logging (each executed command, config decisions) |
| `-h, --help` | Help |
| `--version` | Version of the tooling |

Every command also accepts `--help`.

## Commands

### `config`
Prints the effective configuration as `KEY=VALUE`, including derived values.
Contains no secrets, so it is safe in CI logs.

### `doctor [--strict]`
Lists required and optional tools with their versions. Exits non-zero when a
required tool (bash, openssl, git) is missing; with `--strict` also when an
optional one is.

### `certs` - create / renew certificates
| Option | Meaning |
|---|---|
| `--only NAMES` | subset of `keycloak,spring-app,test-client,saml-sp` |
| `--force` | re-issue the selected leaves with new keys |
| `--force-ca` | also replace the CA (invalidates every certificate) |
| `--pkcs12` | also write `keystore.p12`, `truststore.p12`, `keystore.password` |
| `--verify` | verify only; change nothing |

Details: [lib-certs](lib-certs.md), [certificates](../03-certificates-and-mtls.md).

### `build` - build images, load certificates into them
| Option | Meaning |
|---|---|
| `--only LIST` | subset of `keycloak,app,client` |
| `--tag TAG` | image tag (default `IMAGE_TAG`) |
| `--cert-mode MODE` | `trust` (default), `baked`, `none` |
| `--no-cache` | build without the layer cache |
| `--no-pull` | do not pull newer base images |
| `--stage-only` | prepare `build/context/<image>` and stop |

Details: [lib-images](lib-images.md), [images](../04-images.md).

### `push` - publish to Azure Container Registry
| Option | Meaning |
|---|---|
| `--only LIST`, `--tag TAG` | as above |
| `--acr NAME` | registry name (default `ACR_NAME`) |
| `--acr-build` | build with ACR Tasks instead of pushing local images |
| `--lock` | make the pushed tag immutable |
| `--no-login` | skip `az acr login` |
| `--allow-baked-certs` | allow images containing private keys |

Details: [lib-acr](lib-acr.md), [Azure](../08-azure-acr-aks.md).

### `aks-credentials`, `aks-attach`
Fetch the kubeconfig of `AKS_CLUSTER`; grant the cluster pull access to the
registry.

### `secrets` - load certificates into the cluster
| Option | Meaning |
|---|---|
| `--namespace NS` | target namespace |
| `--release NAME` | release name = Secret prefix |
| `--no-pod-security` | do not label the namespace *restricted* |

### `deploy` - `helm upgrade --install`
| Option | Meaning |
|---|---|
| `--namespace NS`, `--release NAME`, `--tag TAG` | overrides |
| `--registry HOST` | image registry (default: the ACR login server) |
| `--cert-source SRC` | `secret`, `cert-manager`, `image` |
| `--values FILE` | extra values file; repeatable |
| `--set KEY=VALUE` | extra `--set`; repeatable, applied last |
| `--no-wait` | do not wait for readiness |

### `test` - `helm test`
| Option | Meaning |
|---|---|
| `--namespace NS`, `--release NAME` | overrides |
| `--timeout DURATION` | default `5m` |

### `status`
`kubectl get pods,services,secrets` for the release.

Details for the four commands above: [lib-k8s](lib-k8s.md).

### `verify` - local linters and tests
| Option | Meaning |
|---|---|
| `--only LIST` | subset of `shell,bats,docker,helm,java` |
| `--skip LIST` | steps to leave out |
| `--strict` | a missing tool is a failure |

Details: [lib-verify](lib-verify.md).

### `all` - the whole pipeline
`certs → build → push → secrets → deploy → test`.

| Option | Meaning |
|---|---|
| `--tag TAG` | tag for build, push and deploy |
| `--skip LIST` | stages to skip |
| `--namespace NS`, `--release NAME` | overrides |

`push` is skipped automatically when `ACR_NAME` is empty; `secrets` is
skipped with `CERT_SOURCE=image`.

### `clean [--certs]`
Removes `build/context` and the manifests. With `--certs` also deletes
`CERT_DIR` **including the CA**. Refuses to delete `/`, `$HOME`, the
repository root or a relative path.

## Examples

```bash
platform.sh --dry-run all --tag 1.4.0
platform.sh certs --only keycloak --force
platform.sh build --only app --tag 1.4.1 --no-cache
platform.sh push --acr myregistry --tag 1.4.1 --lock
platform.sh deploy --values helm/iam-platform/values-production.yaml --set app.replicas=3
platform.sh -c config/staging.env deploy --namespace iam-staging
IMAGE_TAG=$(git rev-parse --short=12 HEAD) platform.sh all
```

## How it is put together

`main` parses global options, loads the config files (local override first:
a key that is already set is never replaced), creates a private temp
directory with an `EXIT` trap, and dispatches. Each command parses its own
flags, then calls `config_ready` (defaults → derived values → validation),
so flags can still override configuration keys.
