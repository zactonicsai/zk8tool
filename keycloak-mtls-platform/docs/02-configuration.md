# 2. Configuration

All commands read one file: [`config/platform.env`](../config/platform.env).

## Rules

- Format: `KEY=VALUE`, one per line; `#` starts a comment; values may be
  quoted with `"` or `'`.
- `${OTHER_KEY}` references are expanded (not inside single quotes). Nothing
  else is evaluated: the file is **parsed, never sourced**, so it cannot run code.
- Unknown keys produce a warning (catches typos); malformed lines stop the run.
- No secrets belong in this file.

**Precedence**, highest first:

1. command-line flag (`--tag`, `--namespace`, …)
2. environment variable with the key's name
3. `config/platform.local.env` (git-ignored; copy the `.example` file)
4. `config/platform.env`
5. built-in default

`--config FILE` replaces steps 3 and 4 with that one file.
`platform.sh config` prints the effective result.

## Keys

### Project

| Key | Default | Meaning |
|---|---|---|
| `PROJECT_NAME` | `iam-platform` | Prefix for image names; the CA is named `<PROJECT_NAME> Root CA`. |
| `IMAGE_TAG` | `0.1.0` | Tag of all three images. `latest` is rejected: tags must be immutable. |
| `BUILD_DIR` | `build` | Scratch space (certificates, staged contexts, manifests). Git-ignored. |

### Versions and base images

| Key | Default | Meaning |
|---|---|---|
| `KEYCLOAK_VERSION` | `26.8.2` | Keycloak base image tag. |
| `KEYCLOAK_BASE_IMAGE` | `quay.io/keycloak/keycloak` | Keycloak base image. |
| `JAVA_VERSION` | `25` | Used for the default Java image names. |
| `JAVA_BUILD_IMAGE` | `eclipse-temurin:25-jdk` | Build stage of the Java images. |
| `JAVA_RUNTIME_IMAGE` | `eclipse-temurin:25-jre` | Runtime stage. Debian/Ubuntu and Alpine based JREs both work. |

### Images

| Key | Default | Meaning |
|---|---|---|
| `IMAGE_KEYCLOAK` / `IMAGE_APP` / `IMAGE_CLIENT` | `<PROJECT_NAME>/keycloak` … | Repository names without registry. |
| `IMAGE_PLATFORM` | `linux/amd64` | `--platform` for the build. |
| `CONTAINER_CLI` | `docker` | `docker`, `podman` or `nerdctl`. |

### Certificates

| Key | Default | Meaning |
|---|---|---|
| `CERT_DIR` | `<BUILD_DIR>/certs` | Where the CA and certificates live. |
| `CERT_MODE` | `trust` | What `build` loads into images: `trust` (CA only), `baked` (CA + leaf + private key; demos), `none`. |
| `CERT_ORG`, `CERT_OU`, `CERT_COUNTRY` | `Example Corp`, `Platform`, `US` | Subject fields of every certificate. Keycloak matches clients on these. |
| `CERT_KEY_ALG` | `ec` | `ec` (P-256 leaves, P-384 CA) or `rsa`. |
| `CERT_EC_CURVE` | `prime256v1` | Curve for EC leaves. |
| `CERT_RSA_BITS` | `3072` | RSA key size (leaves when `rsa`; always for the SAML certificate). |
| `CERT_CA_DAYS` / `CERT_LEAF_DAYS` / `CERT_SAML_DAYS` | `1825` / `90` / `730` | Lifetimes. |
| `CERT_RENEW_BEFORE_DAYS` | `30` | `certs` re-issues leaves that expire within this window. |
| `CERT_EXTRA_SANS_KEYCLOAK` / `CERT_EXTRA_SANS_APP` | empty | Extra SANs, comma separated (DNS names or IPs). |

### Keycloak

| Key | Default | Meaning |
|---|---|---|
| `KC_REALM` | `platform` | Realm name. |
| `KC_DB_VENDOR` | `dev-file` | `dev-file` (embedded H2, evaluation only), `postgres`, `mariadb`, `mysql`, `mssql`, `oracle`. **Build option**: the image is optimised for one vendor. |
| `KC_HTTPS_CLIENT_AUTH` | `request` | `request` or `required`. **Build option** too. |
| `KC_PUBLIC_URL` | empty | Browser-facing Keycloak URL; empty = in-cluster Service URL. |
| `APP_PUBLIC_URL` | empty | Browser-facing app URL; empty = in-cluster Service URL. |

### Kubernetes / Helm

| Key | Default | Meaning |
|---|---|---|
| `K8S_NAMESPACE` | `iam` | Target namespace. |
| `CLUSTER_DOMAIN` | `cluster.local` | Cluster DNS suffix (part of certificate SANs and URLs). |
| `HELM_RELEASE` | `iam` | Release name; prefix of every resource and Secret. |
| `HELM_CHART` | `helm/iam-platform` | Chart path. |
| `HELM_VALUES` | empty | Extra values files, comma separated. |
| `HELM_TIMEOUT` | `10m` | `helm upgrade --timeout`. |
| `CERT_SOURCE` | `secret` | Where pods get certificates: `secret`, `cert-manager`, `image` (needs `CERT_MODE=baked`). |

### Azure

| Key | Default | Meaning |
|---|---|---|
| `AZ_SUBSCRIPTION` | empty | Subscription to select; empty = current `az account`. |
| `ACR_NAME` | empty | Registry name without `.azurecr.io`. Required by `push`. |
| `ACR_LOGIN_SERVER` | `<ACR_NAME>.azurecr.io` | Override for sovereign clouds. |
| `AKS_RESOURCE_GROUP`, `AKS_CLUSTER` | empty | Used by `aks-credentials` and `aks-attach`. |

## Derived values

Computed by the scripts and printed by `platform.sh config`:

| Value | Built from |
|---|---|
| `KC_SERVICE_NAME` | `<HELM_RELEASE>-keycloak` |
| `APP_SERVICE_NAME` | `<HELM_RELEASE>-spring-app` |
| `KC_INTERNAL_URL` | `https://<KC_SERVICE_NAME>.<K8S_NAMESPACE>.svc.<CLUSTER_DOMAIN>:8443` |
| `APP_INTERNAL_URL` | same pattern for the app |

`HELM_RELEASE`, `K8S_NAMESPACE` and `CLUSTER_DOMAIN` therefore end up in the
certificate SANs. Change one of them and `platform.sh certs` re-issues the
affected certificates on its next run.

## Validation

Every command validates the configuration first and exits with code 2 on:
unknown enum values, non-numeric lifetimes, RSA keys under 2048 bits, a
renewal window not shorter than the leaf lifetime, invalid DNS labels or
image names, `IMAGE_TAG=latest`, subject fields with characters that would
break a distinguished name, non-HTTPS public URLs, an ACR name with a domain
suffix, and `CERT_SOURCE=image` without `CERT_MODE=baked`.
