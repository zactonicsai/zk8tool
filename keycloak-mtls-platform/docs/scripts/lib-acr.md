# `scripts/lib/acr.sh`

Implements `platform.sh push`, `aks-credentials` and `aks-attach`. Usage and
Azure background: [Azure](../08-azure-acr-aks.md).

## Flow of `acr_main` (push)

1. Parse options; `--acr NAME` replaces `ACR_NAME` (and resets the derived login server).
2. `config_ready`; fail (exit 2) when no registry is configured.
3. **Local images** (default): `acr_login` once, then `acr_push_one` per component.
4. **`--acr-build`**: refuse `CERT_MODE=baked` (exit 3), then `acr_build_one` per component.

## Functions

| Function | Purpose |
|---|---|
| `acr_login` | `az account set` (if `AZ_SUBSCRIPTION`), then `az acr login --name`. With podman / nerdctl: `az acr login --expose-token` piped into `<cli> login --password-stdin`; the token never touches disk or arguments. |
| `acr_push_one COMPONENT ALLOW_BAKED LOCK` | Checks the local image exists; reads its `io.platform.cert-mode` label and refuses `baked` (exit 3) unless allowed; `tag`, `push`; records the digest; optional lock. |
| `_acr_record_digest` | Writes `component=<repo>@sha256:… tag=<tag>` to `build/images.pushed.env`; `deploy` uses the digest only when the tag matches. |
| `acr_lock_tag COMPONENT` | `az acr repository update --write-enabled false --delete-enabled false` for `repository:tag`. |
| `acr_build_one COMPONENT LOCK` | Stages the context and runs `az acr build --registry … --image … --platform … --file … <build args> <ctx>`. |
| `acr_remote_ref COMPONENT` | `<login server>/<repository>:<tag>`. |
| `aks_credentials_main` | `az aks get-credentials --overwrite-existing`. |
| `aks_attach_main` | `az aks update --attach-acr <ACR_NAME>`. |

## Safety rules

- Images containing private keys are not pushed, and build contexts
  containing private keys are not uploaded, unless `--allow-baked-certs` is
  given explicitly.
- Only `az`-issued, short-lived credentials are used; the registry admin
  account is never touched.
- `--lock` turns the tag into an immutable release artifact.

## Tests

`tests/scripts/build_push.bats`: missing registry, login order, subscription
selection, overrides, sovereign login server, digest recording, refusal and
override for baked images, missing local image, `--lock`, `--acr-build`
(arguments and refusal), token login for podman, dry-run, AKS helpers.
