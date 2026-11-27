#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
# scripts/lib/acr.sh - Azure Container Registry (push / ACR Tasks build) and
# the two AKS convenience commands.
#
# Authentication always goes through `az` (Entra ID user, service principal,
# managed identity or workload identity). The registry admin user is never used.
# Docs: docs/scripts/lib-acr.md and docs/08-azure-acr-aks.md
# =============================================================================

if [[ -n "${__PLATFORM_ACR_SH:-}" ]]; then return 0; fi
__PLATFORM_ACR_SH=1

acr_usage() {
  cat <<'EOF'
Usage: platform.sh push [options]

Tag the locally built images for Azure Container Registry and push them.

Options:
  --only LIST          Comma separated subset of: keycloak,app,client
  --tag TAG            Image tag (default: IMAGE_TAG from the config)
  --acr NAME           Registry name without .azurecr.io (default: ACR_NAME)
  --acr-build          Build in Azure with ACR Tasks instead of pushing local
                       images (no local container runtime needed)
  --lock               After pushing, make the tag immutable
                       (write-enabled=false, delete-enabled=false)
  --no-login           Skip `az acr login` (already logged in / CI did it)
  --allow-baked-certs  Permit pushing images built with --cert-mode baked.
                       They contain private keys; do not use outside demos.
  -h, --help           Show this help
EOF
}

acr_require_config() {
  [[ -n "$ACR_NAME" ]] || die "ACR_NAME is not set. Set it in config/platform.env or pass --acr NAME." 2
}

# acr_remote_ref COMPONENT - e.g. myreg.azurecr.io/iam-platform/keycloak:0.1.0
acr_remote_ref() {
  printf '%s/%s:%s' "$ACR_LOGIN_SERVER" "$(component_image_repo "$1")" "$IMAGE_TAG"
}

acr_login() {
  require_cmd az "Install the Azure CLI: https://learn.microsoft.com/cli/azure/install-azure-cli"
  if [[ -n "$AZ_SUBSCRIPTION" ]]; then
    run az account set --subscription "$AZ_SUBSCRIPTION"
  fi
  if [[ "$CONTAINER_CLI" == "docker" ]]; then
    run az acr login --name "$ACR_NAME"
    return 0
  fi
  # podman / nerdctl: exchange the az identity for a short-lived registry token.
  if [[ "${DRY_RUN}" == "1" ]]; then
    printf '[dry-run] az acr login --name %s --expose-token | %s login %s --password-stdin\n' \
      "$ACR_NAME" "$CONTAINER_CLI" "$ACR_LOGIN_SERVER"
    return 0
  fi
  az acr login --name "$ACR_NAME" --expose-token --output tsv --query accessToken |
    "$CONTAINER_CLI" login "$ACR_LOGIN_SERVER" \
      --username 00000000-0000-0000-0000-000000000000 --password-stdin
}

# _acr_image_cert_mode REF - value of the cert-mode label, empty if unknown.
_acr_image_cert_mode() {
  "$CONTAINER_CLI" image inspect \
    --format "{{ index .Config.Labels \"${IMAGE_CERT_MODE_LABEL}\" }}" "$1" 2>/dev/null || true
}

# _acr_record_digest COMPONENT REMOTE_REF - append "component=repo@sha256:..".
_acr_record_digest() {
  local component=$1 remote=$2 repo digest manifest="${BUILD_DIR}/images.pushed.env"
  repo="${remote%:*}"
  digest=$("$CONTAINER_CLI" image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "$remote" 2>/dev/null |
    grep -F "${repo}@" | head -n 1 || true)
  mkdir -p "$BUILD_DIR"
  touch "$manifest"
  grep -v "^${component}=" "$manifest" >"${manifest}.tmp" || true
  if [[ -n "$digest" ]]; then
    printf '%s=%s tag=%s\n' "$component" "$digest" "$IMAGE_TAG" >>"${manifest}.tmp"
    log_info "push: ${component} digest ${digest##*@}"
  else
    log_warn "push: could not determine the digest of ${remote}; deploy will use the tag"
  fi
  mv "${manifest}.tmp" "$manifest"
}

acr_lock_tag() {
  local component=$1
  run az acr repository update --name "$ACR_NAME" \
    --image "$(component_image_repo "$component"):${IMAGE_TAG}" \
    --write-enabled false --delete-enabled false
}

acr_push_one() {
  local component=$1 allow_baked=$2 lock=$3 local_ref remote_ref mode
  local_ref=$(images_local_ref "$component")
  remote_ref=$(acr_remote_ref "$component")

  if [[ "${DRY_RUN}" != "1" ]]; then
    "$CONTAINER_CLI" image inspect "$local_ref" >/dev/null 2>&1 ||
      die "push: local image ${local_ref} not found. Run: platform.sh build --tag ${IMAGE_TAG}"
    mode=$(_acr_image_cert_mode "$local_ref")
    if [[ "$mode" == "baked" && "$allow_baked" != "1" ]]; then
      die "push: ${local_ref} was built with --cert-mode baked and contains private keys. Rebuild with --cert-mode trust, or pass --allow-baked-certs if you really mean it." 3
    fi
  fi

  log_info "push: ${local_ref} -> ${remote_ref}"
  run "$CONTAINER_CLI" tag "$local_ref" "$remote_ref"
  run "$CONTAINER_CLI" push "$remote_ref"
  if [[ "${DRY_RUN}" != "1" ]]; then _acr_record_digest "$component" "$remote_ref"; fi
  if [[ "$lock" == "1" ]]; then acr_lock_tag "$component"; fi
}

# acr_build_one COMPONENT - build inside Azure from the staged context.
acr_build_one() {
  local component=$1 lock=$2 ctx arg
  local args=()
  ctx=$(images_context_dir "$component")
  images_stage_context "$component"
  args=(acr build --registry "$ACR_NAME"
    --image "$(component_image_repo "$component"):${IMAGE_TAG}"
    --platform "$IMAGE_PLATFORM" --file "${ctx}/Dockerfile")
  while IFS= read -r arg; do args+=("$arg"); done < <(images_build_args "$component")
  log_info "push: ACR Tasks build of ${component}"
  run az "${args[@]}" "$ctx"
  if [[ "$lock" == "1" ]]; then acr_lock_tag "$component"; fi
}

acr_main() {
  local only="" acr_build=0 lock=0 login=1 allow_baked=0 list component
  local components=()
  while (($# > 0)); do
    case "$1" in
      --only)
        [[ $# -ge 2 ]] || die "push: --only needs a value" 2
        only=$2
        shift
        ;;
      --tag)
        [[ $# -ge 2 ]] || die "push: --tag needs a value" 2
        IMAGE_TAG=$2
        shift
        ;;
      --acr)
        [[ $# -ge 2 ]] || die "push: --acr needs a value" 2
        ACR_NAME=$2
        ACR_LOGIN_SERVER=""
        shift
        ;;
      --acr-build) acr_build=1 ;;
      --lock) lock=1 ;;
      --no-login) login=0 ;;
      --allow-baked-certs) allow_baked=1 ;;
      -h | --help)
        acr_usage
        return 0
        ;;
      *) die "push: unknown option '$1' (see: platform.sh push --help)" 2 ;;
    esac
    shift
  done
  config_ready
  acr_require_config
  list=$(parse_components "$only") || exit $?
  while IFS= read -r component; do components+=("$component"); done <<<"$list"

  log_step "Publishing to ${ACR_LOGIN_SERVER} (tag ${IMAGE_TAG})"
  require_cmd az "Install the Azure CLI: https://learn.microsoft.com/cli/azure/install-azure-cli"

  if [[ "$acr_build" == "1" ]]; then
    if [[ "$CERT_MODE" == "baked" && "$allow_baked" != "1" ]]; then
      die "push: --acr-build with CERT_MODE=baked would upload private keys to Azure. Use CERT_MODE=trust or pass --allow-baked-certs." 3
    fi
    if [[ -n "$AZ_SUBSCRIPTION" ]]; then run az account set --subscription "$AZ_SUBSCRIPTION"; fi
    for component in "${components[@]}"; do acr_build_one "$component" "$lock"; done
    return 0
  fi

  require_cmd "$CONTAINER_CLI" "Install Docker (or use --acr-build)."
  if [[ "$login" == "1" ]]; then acr_login; fi
  for component in "${components[@]}"; do
    acr_push_one "$component" "$allow_baked" "$lock"
  done
}

# --- AKS helpers --------------------------------------------------------------

_aks_require_config() {
  [[ -n "$AKS_RESOURCE_GROUP" && -n "$AKS_CLUSTER" ]] ||
    die "AKS_RESOURCE_GROUP and AKS_CLUSTER must be set in the config." 2
  require_cmd az "Install the Azure CLI."
  if [[ -n "$AZ_SUBSCRIPTION" ]]; then run az account set --subscription "$AZ_SUBSCRIPTION"; fi
}

# aks_credentials_main - merge the cluster's kubeconfig entry (Entra ID auth).
aks_credentials_main() {
  config_ready
  _aks_require_config
  log_step "Fetching kubeconfig for ${AKS_CLUSTER}"
  run az aks get-credentials --resource-group "$AKS_RESOURCE_GROUP" --name "$AKS_CLUSTER" --overwrite-existing
}

# aks_attach_main - grant the cluster's kubelet identity AcrPull on the registry,
# so no imagePullSecret is needed.
aks_attach_main() {
  config_ready
  acr_require_config
  _aks_require_config
  log_step "Attaching ${ACR_NAME} to ${AKS_CLUSTER}"
  run az aks update --resource-group "$AKS_RESOURCE_GROUP" --name "$AKS_CLUSTER" --attach-acr "$ACR_NAME"
}
