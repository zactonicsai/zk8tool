# Scripts

One entry point, one library per concern.

| File | Purpose | Docs |
|---|---|---|
| [`scripts/platform.sh`](../../scripts/platform.sh) | CLI: argument parsing, config loading, command dispatch, `doctor`, `clean`, `all` | [platform](platform.md) |
| [`scripts/lib/common.sh`](../../scripts/lib/common.sh) | logging, config file parser, validation, dry-run, helpers | [lib-common](lib-common.md) |
| [`scripts/lib/certs.sh`](../../scripts/lib/certs.sh) | private CA and certificates | [lib-certs](lib-certs.md) |
| [`scripts/lib/images.sh`](../../scripts/lib/images.sh) | build contexts, certificate loading, image builds | [lib-images](lib-images.md) |
| [`scripts/lib/acr.sh`](../../scripts/lib/acr.sh) | Azure Container Registry and AKS helpers | [lib-acr](lib-acr.md) |
| [`scripts/lib/k8s.sh`](../../scripts/lib/k8s.sh) | Secrets, Helm deploy, Helm test, status | [lib-k8s](lib-k8s.md) |
| [`scripts/lib/verify.sh`](../../scripts/lib/verify.sh) | local linters and test suites | [lib-verify](lib-verify.md) |
| [`tests/fixtures/generate-test-certs.sh`](../../tests/fixtures/generate-test-certs.sh) | regenerates the Java test certificate fixtures | [testing](../10-testing.md#certificate-fixtures) |
| [`tests/scripts/*.bats`](../../tests/scripts) | tests of all of the above | [testing](../10-testing.md#script-tests-bats) |

## Conventions shared by all scripts

- `set -Eeuo pipefail`; bash 4 or newer (macOS: `brew install bash`).
- **Logs go to stderr**, machine-readable output (`config`, dry-run plans)
  to stdout.
- **`--dry-run`** prints every state-changing command as `[dry-run] …` and
  runs none of them. Missing tools are only warnings in dry-run mode.
- **Idempotent**: every command can be re-run; it converges instead of failing.
- **Secrets never appear in arguments or logs**: keys travel as files or
  through pipes.
- **Temporary files** live in a private directory that an `EXIT` trap removes.
- **Exit codes**: `0` success, `1` failure, `2` usage or configuration
  error, `3` refused for safety (pushing images that contain private keys),
  `127` required tool missing.
- All scripts pass shellcheck.

## Data flow between commands

```
certs   ──▶ build/certs/**
build   ──▶ build/context/<image>/   build/images.env
push    ──▶ build/images.pushed.env                       (digests)
deploy  ──▶ build/helm-values.generated.yaml
            reads build/certs (subjects, SAML cert) and build/images.pushed.env
```

`build/` is disposable except `build/certs`, which holds your CA.
