# `scripts/lib/common.sh`

Shared foundation sourced by `platform.sh` and usable from tests.

## Logging

`log_info`, `log_warn`, `log_error`, `log_step`, `log_debug` write
`[LEVEL] message` to **stderr** (colour only on a terminal; `NO_COLOR`
disables it). `log_debug` prints only with `--verbose`. `die MESSAGE [CODE]`
logs an error and exits (default code 1).

## Running commands

| Function | Behaviour |
|---|---|
| `run CMD…` | Executes a state-changing command. In dry-run mode prints `[dry-run] <shell-quoted command>` to stdout instead. |
| `have_cmd NAME` | True when a tool is on the `PATH`. |
| `require_cmd NAME [HINT]` | Exits 127 with a hint when a tool is missing; only warns in dry-run mode. |
| `quote_cmd ARGS…` | Copy-pasteable quoting used by `run`. |

Read-only commands (`openssl verify`, `docker image inspect`) are called
directly, not through `run`.

## Temporary files

`platform_tmp_init` creates one private directory (mode 700);
`platform_tmpdir` hands out sub-directories; `platform_cleanup` (the `EXIT`
trap of `platform.sh`) removes everything, so half-written keys do not
survive a failed run.

## Configuration

| Function | Behaviour |
|---|---|
| `load_config_file FILE` | Parses `KEY=VALUE` lines. Skips keys that are already set (environment, flags, earlier file). Warns on unknown keys, dies on malformed lines. |
| `config_finalize` | Applies built-in defaults, resolves relative paths against the repository root, computes derived values (Service names, URLs, ACR login server). |
| `config_validate` | Fails fast (exit 2) on values that would break later steps. |
| `config_ready` | `config_finalize` + `config_validate`; called by every command after its flags are applied. |
| `config_print` | Prints all keys and derived values. |

The parser deliberately supports very little: quotes, trailing comments and
`${KEY}` references. There is no command substitution and the file is never
sourced, so a config file cannot execute code. `CONFIG_KEYS` is the
allow-list of keys; adding a config option means adding it there, in
`config_finalize` (default) and, if needed, in `config_validate`.

## Components

The three images are addressed as `keycloak`, `app`, `client`:

| Function | Example result |
|---|---|
| `parse_components "app,client"` | validates a `--only` list |
| `component_image_repo app` | `iam-platform/spring-app` |
| `component_cert_name app` | `spring-app` (directory under `CERT_DIR`) |
| `component_helm_key client` | `testClient` (key in `values.yaml`) |

## Small helpers

`abs_path`, `contains ITEM LIST…`, `csv_split "a, b"`, `url_host URL`.

## Tests

`tests/scripts/cli_config.bats`: precedence, quoting, references, unknown
and malformed lines, "parsed, never executed", each validation rule.
