# `scripts/lib/images.sh`

Implements `platform.sh build`. The images themselves are described in
[images](../04-images.md).

## Flow of `images_main`

1. Parse options (`--only`, `--tag`, `--cert-mode`, `--no-cache`, `--no-pull`, `--stage-only`).
2. `config_ready` (so `--tag` and `--cert-mode` are validated like config values).
3. For each selected component: `images_stage_context`, then - unless
   `--stage-only` - one `docker build`.
4. `images_write_manifest` records `component=repository:tag` in `build/images.env`.

## Functions

| Function | Purpose |
|---|---|
| `images_stage_context COMPONENT` | Recreates `build/context/<component>`: Dockerfile, sources (realm or Maven reactor without `target/` and `src/test`), certificate material. |
| `images_stage_certs COMPONENT CTX` | Copies what `CERT_MODE` allows: `certs/trust/ca.crt` (trust, baked); `certs/tls/{tls.crt,tls.key,ca.crt}` and, for the app, `certs/saml/{tls.crt,tls.key}` (baked only). Logs a warning for every private key it bakes. |
| `images_build_args COMPONENT` | `--build-arg` list, shared with `az acr build`. |
| `images_build_one COMPONENT NO_CACHE PULL` | Assembles and runs the build command. |
| `images_write_manifest COMPONENTS…` | Updates `build/images.env`. |
| `images_local_ref COMPONENT` | `repository:tag`. |
| `images_context_dir COMPONENT` | Path of the staged context. |

## The build command

```
docker build --platform <IMAGE_PLATFORM> --file <ctx>/Dockerfile --tag <repo>:<tag> --pull
  --build-arg …                                   (see below)
  --label org.opencontainers.image.title=<project>-<component>
  --label org.opencontainers.image.version=<tag>
  --label org.opencontainers.image.revision=<git commit>
  --label org.opencontainers.image.created=<UTC timestamp>
  --label io.platform.cert-mode=<CERT_MODE>
  <ctx>
```

| Component | Build args |
|---|---|
| keycloak | `KEYCLOAK_BASE_IMAGE`, `KEYCLOAK_VERSION`, `KC_DB` (= `KC_DB_VENDOR`), `KC_HTTPS_CLIENT_AUTH` |
| app, client | `JAVA_BUILD_IMAGE`, `JAVA_RUNTIME_IMAGE` |

`--pull` keeps base images current (security patches); `--no-pull` is for
offline work. `CONTAINER_CLI` selects `docker`, `podman` or `nerdctl`.

## Guarantees worth knowing

- In `trust` mode no private key is ever copied into a context (tested).
- `baked` mode is loud: a warning per key, and a label that makes `push`
  refuse the image.
- The context is rebuilt from scratch on every run, so stale files cannot
  linger.
- A missing CA or certificate fails with "Run: platform.sh certs".

## Tests

`tests/scripts/build_push.bats`: contexts for each `CERT_MODE`, realm and
Maven reactor contents, docker arguments (tag, build args, labels, pull,
no-cache), manifest, alternative CLI, invalid input, dry-run.
