# `scripts/lib/verify.sh`

Implements `platform.sh verify`: every check that needs no cluster.

## Steps

| Step | Tool | What runs |
|---|---|---|
| `shell` | shellcheck | all `*.sh` and `*.bash` under `scripts/` and `tests/`, following sourced files |
| `bats` | bats | `tests/scripts/*.bats` |
| `docker` | hadolint | `docker/*/Dockerfile` with `.hadolint.yaml` |
| `helm` | helm (+ helm-unittest plugin, kubeconform) | `helm lint --strict` with default, production and cert-manager values; `helm unittest`; `helm template … \| kubeconform -strict` for the same three value sets |
| `java` | JDK 25 + Maven Wrapper | `./mvnw verify` in `apps/` (both modules) |

## Options

| Option | Meaning |
|---|---|
| `--only LIST` | run only these steps |
| `--skip LIST` | leave these steps out |
| `--strict` | a missing tool makes its step `FAIL` instead of `SKIP` |

## Output and exit code

```
STEP     RESULT NOTES
shell    PASS   9 files
bats     PASS
docker   SKIP   hadolint not installed
helm     PASS   kubeconform not installed (schema validation skipped)
java     PASS
```

Exit code 0 when no step failed. Without `--strict`, a missing tool is
reported as `SKIP`, so a quick local run works with whatever is installed;
CI should use `--strict` so nothing is silently skipped.

## Installing the tools

| Tool | Install |
|---|---|
| shellcheck, bats | package manager (`apt install shellcheck bats`, `brew install shellcheck bats-core`) |
| hadolint | release binary from the hadolint project, or `brew install hadolint` |
| helm | https://helm.sh/docs/intro/install/ |
| helm-unittest | `helm plugin install https://github.com/helm-unittest/helm-unittest` |
| kubeconform | release binary from the kubeconform project, or `brew install kubeconform` |
| JDK 25 | any distribution (Temurin, Microsoft Build of OpenJDK, …) |

`platform.sh doctor` shows what is present.

## Extending

Add a function `verify_<step>` that calls `_verify_record STEP PASS|FAIL|SKIP [NOTES]`
and append the step name to `VERIFY_STEPS`.
