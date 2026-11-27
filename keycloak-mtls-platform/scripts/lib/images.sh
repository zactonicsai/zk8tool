#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
# scripts/lib/images.sh - stage build contexts, load certificates into them and
# build the three container images.
#
# Every image is built from a self-contained, staged context
#   ${BUILD_DIR}/context/<component>/{Dockerfile, sources, certs/}
# so the very same directory works with `docker build` and `az acr build`.
# Docs: docs/scripts/lib-images.md and docs/04-images.md
# =============================================================================

if [[ -n "${__PLATFORM_IMAGES_SH:-}" ]]; then return 0; fi
__PLATFORM_IMAGES_SH=1

# Label read back by `push` to refuse images that contain private keys.
IMAGE_CERT_MODE_LABEL="io.platform.cert-mode"

images_usage() {
  cat <<'EOF'
Usage: platform.sh build [options]

Build the Keycloak, Spring Boot app and test-client images and load the
certificates selected by --cert-mode into them.

Options:
  --only LIST        Comma separated subset of: keycloak,app,client
  --tag TAG          Image tag (default: IMAGE_TAG from the config)
  --cert-mode MODE   trust : CA certificate only (default, safe to push)
                     baked : CA + leaf certificate + PRIVATE KEY (demos only)
                     none  : no certificate material in the image
  --no-cache         Build without the layer cache
  --no-pull          Do not pull newer base images
  --stage-only       Prepare build/context/<component> and stop
  -h, --help         Show this help
EOF
}

images_context_dir() { printf '%s/context/%s' "$BUILD_DIR" "$1"; }

# images_local_ref COMPONENT - e.g. iam-platform/keycloak:0.1.0
images_local_ref() { printf '%s:%s' "$(component_image_repo "$1")" "$IMAGE_TAG"; }

_images_docker_dir() {
  case "$1" in
    keycloak) printf '%s/docker/keycloak' "$PLATFORM_ROOT" ;;
    app) printf '%s/docker/spring-app' "$PLATFORM_ROOT" ;;
    client) printf '%s/docker/test-client' "$PLATFORM_ROOT" ;;
  esac
}

_images_git_revision() {
  git -C "$PLATFORM_ROOT" rev-parse --short=12 HEAD 2>/dev/null || printf 'unknown'
}

# images_stage_certs COMPONENT CTX - copy the material allowed by CERT_MODE.
#   certs/trust/ca.crt          trust + baked
#   certs/tls/{tls.crt,tls.key,ca.crt}   baked only
#   certs/saml/{tls.crt,tls.key}         baked only, app only
images_stage_certs() {
  local component=$1 ctx=$2 cert_name dir
  cert_name=$(component_cert_name "$component")
  for dir in trust tls saml; do
    mkdir -p "${ctx}/certs/${dir}"
    # COPY needs every source directory to exist, even when it carries nothing.
    : >"${ctx}/certs/${dir}/.placeholder"
  done
  case "$CERT_MODE" in
    none) return 0 ;;
    trust | baked)
      certs_require
      cp "$(certs_path ca ca.crt)" "${ctx}/certs/trust/ca.crt"
      ;;
  esac
  if [[ "$CERT_MODE" == "baked" ]]; then
    certs_require "$cert_name"
    log_warn "build: ${component}: baking the PRIVATE KEY of '${cert_name}' into the image (CERT_MODE=baked)"
    cp "$(certs_path "$cert_name" tls.crt)" "$(certs_path "$cert_name" ca.crt)" "${ctx}/certs/tls/"
    cp -p "$(certs_path "$cert_name" tls.key)" "${ctx}/certs/tls/tls.key"
    if [[ "$component" == "app" ]]; then
      certs_require saml-sp
      cp "$(certs_path saml-sp tls.crt)" "${ctx}/certs/saml/tls.crt"
      cp -p "$(certs_path saml-sp tls.key)" "${ctx}/certs/saml/tls.key"
    fi
    # The image user is not the user running this script: the key must be
    # readable after COPY --chown, which keeps the mode bits.
    chmod 600 "${ctx}"/certs/*/tls.key
  fi
}

# images_stage_context COMPONENT - (re)create the build context directory.
images_stage_context() {
  local component=$1 ctx src
  ctx=$(images_context_dir "$component")
  src=$(_images_docker_dir "$component")
  if [[ "${DRY_RUN}" == "1" ]]; then
    printf '[dry-run] stage build context %s (cert mode: %s)\n' "$ctx" "$CERT_MODE"
    return 0
  fi
  [[ -f "${src}/Dockerfile" ]] || die "build: ${src}/Dockerfile not found"
  rm -rf "$ctx"
  mkdir -p "$ctx"
  cp "${src}/Dockerfile" "${ctx}/Dockerfile"
  case "$component" in
    keycloak)
      cp -R "${src}/realm" "${ctx}/realm"
      ;;
    app | client)
      mkdir -p "${ctx}/apps"
      # Maven reactor without build output and without tests (they run in
      # `platform.sh verify`, and their fixture keys have no place in a build
      # context). tar keeps mvnw executable.
      tar -C "${PLATFORM_ROOT}/apps" --exclude target --exclude 'src/test' -cf - . | tar -C "${ctx}/apps" -xf -
      ;;
  esac
  images_stage_certs "$component" "$ctx"
  log_debug "build: staged ${ctx}"
}

# images_build_args COMPONENT - one "--build-arg"/value token per line; shared
# by the local build and by `az acr build`.
images_build_args() {
  case "$1" in
    keycloak)
      printf '%s\n' \
        --build-arg "KEYCLOAK_BASE_IMAGE=${KEYCLOAK_BASE_IMAGE}" \
        --build-arg "KEYCLOAK_VERSION=${KEYCLOAK_VERSION}" \
        --build-arg "KC_DB=${KC_DB_VENDOR}" \
        --build-arg "KC_HTTPS_CLIENT_AUTH=${KC_HTTPS_CLIENT_AUTH}"
      ;;
    app | client)
      printf '%s\n' \
        --build-arg "JAVA_BUILD_IMAGE=${JAVA_BUILD_IMAGE}" \
        --build-arg "JAVA_RUNTIME_IMAGE=${JAVA_RUNTIME_IMAGE}"
      ;;
  esac
}

images_build_one() {
  local component=$1 no_cache=$2 pull=$3 ctx ref arg
  local args=()
  ctx=$(images_context_dir "$component")
  ref=$(images_local_ref "$component")
  images_stage_context "$component"

  args=(build --platform "$IMAGE_PLATFORM" --file "${ctx}/Dockerfile" --tag "$ref")
  if [[ "$pull" == "1" ]]; then args+=(--pull); fi
  if [[ "$no_cache" == "1" ]]; then args+=(--no-cache); fi
  while IFS= read -r arg; do args+=("$arg"); done < <(images_build_args "$component")
  args+=(
    --label "org.opencontainers.image.title=${PROJECT_NAME}-${component}"
    --label "org.opencontainers.image.version=${IMAGE_TAG}"
    --label "org.opencontainers.image.revision=$(_images_git_revision)"
    --label "org.opencontainers.image.created=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    --label "${IMAGE_CERT_MODE_LABEL}=${CERT_MODE}"
  )
  log_info "build: ${component} -> ${ref}"
  run "$CONTAINER_CLI" "${args[@]}" "$ctx"
}

# images_write_manifest COMPONENTS... - record what was built for later steps.
images_write_manifest() {
  local manifest="${BUILD_DIR}/images.env" component
  if [[ "${DRY_RUN}" == "1" ]]; then return 0; fi
  mkdir -p "$BUILD_DIR"
  touch "$manifest"
  for component in "$@"; do
    # Replace an older line for the same component, keep the others.
    grep -v "^${component}=" "$manifest" >"${manifest}.tmp" || true
    printf '%s=%s\n' "$component" "$(images_local_ref "$component")" >>"${manifest}.tmp"
    mv "${manifest}.tmp" "$manifest"
  done
  log_info "build: manifest ${manifest}"
}

images_main() {
  local only="" no_cache=0 pull=1 stage_only=0 list component
  local components=()
  while (($# > 0)); do
    case "$1" in
      --only)
        [[ $# -ge 2 ]] || die "build: --only needs a value" 2
        only=$2
        shift
        ;;
      --tag)
        [[ $# -ge 2 ]] || die "build: --tag needs a value" 2
        IMAGE_TAG=$2
        shift
        ;;
      --cert-mode)
        [[ $# -ge 2 ]] || die "build: --cert-mode needs a value" 2
        CERT_MODE=$2
        shift
        ;;
      --no-cache) no_cache=1 ;;
      --no-pull) pull=0 ;;
      --stage-only) stage_only=1 ;;
      -h | --help)
        images_usage
        return 0
        ;;
      *) die "build: unknown option '$1' (see: platform.sh build --help)" 2 ;;
    esac
    shift
  done
  config_ready
  list=$(parse_components "$only") || exit $?
  while IFS= read -r component; do components+=("$component"); done <<<"$list"

  log_step "Building images (tag ${IMAGE_TAG}, cert mode ${CERT_MODE})"
  if [[ "$stage_only" == "1" ]]; then
    for component in "${components[@]}"; do images_stage_context "$component"; done
    log_info "build: contexts staged under ${BUILD_DIR}/context"
    return 0
  fi
  require_cmd "$CONTAINER_CLI" "Install Docker (or set CONTAINER_CLI)."
  for component in "${components[@]}"; do
    images_build_one "$component" "$no_cache" "$pull"
  done
  images_write_manifest "${components[@]}"
}
