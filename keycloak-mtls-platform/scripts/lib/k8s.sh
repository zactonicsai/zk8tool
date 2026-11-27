#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
# scripts/lib/k8s.sh - load certificates into the cluster as Secrets, deploy
# the Helm chart and run the in-cluster test pod.
#
# Secret names are part of the contract with the chart
# (helm/iam-platform/templates/_helpers.tpl):
#   <release>-keycloak-tls  <release>-spring-app-tls  <release>-test-client-tls
#   <release>-saml-sp-tls   <release>-keycloak-admin
# Docs: docs/scripts/lib-k8s.md and docs/09-helm-chart.md
# =============================================================================

if [[ -n "${__PLATFORM_K8S_SH:-}" ]]; then return 0; fi
__PLATFORM_K8S_SH=1

secrets_usage() {
  cat <<'EOF'
Usage: platform.sh secrets [options]

Create the namespace and load the certificates from CERT_DIR into it as
kubernetes.io/tls Secrets (tls.crt, tls.key, ca.crt). Also creates the
Keycloak bootstrap-admin Secret with a random password if it does not exist.
Safe to re-run: certificate Secrets are replaced, the admin Secret is kept.

Options:
  --namespace NS       Target namespace (default: K8S_NAMESPACE)
  --release NAME       Helm release name used as Secret prefix (default: HELM_RELEASE)
  --no-pod-security    Do not label the namespace with the "restricted"
                       Pod Security Standard
  -h, --help           Show this help
EOF
}

deploy_usage() {
  cat <<'EOF'
Usage: platform.sh deploy [options]

Install or upgrade the Helm release. Image names, tags (or pushed digests),
URLs and certificate subjects are derived from the configuration so the chart
always matches what `certs`, `build` and `push` produced.

Options:
  --namespace NS       Target namespace (default: K8S_NAMESPACE)
  --release NAME       Helm release name (default: HELM_RELEASE)
  --tag TAG            Image tag (default: IMAGE_TAG)
  --registry HOST      Image registry (default: the ACR login server, if any)
  --cert-source SRC    secret | cert-manager | image (default: CERT_SOURCE)
  --values FILE        Extra values file; repeatable, later files win
  --set KEY=VALUE      Extra --set passed to helm; repeatable, applied last
  --no-wait            Do not wait for the workloads to become ready
  -h, --help           Show this help
EOF
}

test_usage() {
  cat <<'EOF'
Usage: platform.sh test [options]

Run `helm test`: starts the Java 25 test-client pod inside the cluster, which
checks certificates, mTLS, OIDC, SAML and the app API, then prints its report.

Options:
  --namespace NS       Target namespace (default: K8S_NAMESPACE)
  --release NAME       Helm release name (default: HELM_RELEASE)
  --timeout DURATION   helm test timeout (default: 5m)
  -h, --help           Show this help
EOF
}

k8s_secret_name() { printf '%s-%s-tls' "$HELM_RELEASE" "$1"; }

# k8s_ensure_namespace POD_SECURITY(0|1)
k8s_ensure_namespace() {
  local pod_security=$1
  if [[ "${DRY_RUN}" == "1" ]]; then
    printf '[dry-run] kubectl create namespace %s (if missing)\n' "$K8S_NAMESPACE"
  else
    kubectl create namespace "$K8S_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  fi
  if [[ "$pod_security" == "1" ]]; then
    run kubectl label namespace "$K8S_NAMESPACE" --overwrite \
      pod-security.kubernetes.io/enforce=restricted \
      pod-security.kubernetes.io/enforce-version=latest
  fi
}

# k8s_apply_tls_secret LEAF - create or replace <release>-<leaf>-tls.
# The private key travels file -> kubectl -> API server; it never appears on a
# command line or in this script's output.
k8s_apply_tls_secret() {
  local leaf=$1 secret dir="${CERT_DIR}/$1"
  secret=$(k8s_secret_name "$leaf")
  if [[ "${DRY_RUN}" == "1" ]]; then
    printf '[dry-run] kubectl apply secret %s/%s (kubernetes.io/tls) from %s\n' "$K8S_NAMESPACE" "$secret" "$dir"
    return 0
  fi
  kubectl --namespace "$K8S_NAMESPACE" create secret generic "$secret" \
    --type=kubernetes.io/tls \
    --from-file=tls.crt="${dir}/tls.crt" \
    --from-file=tls.key="${dir}/tls.key" \
    --from-file=ca.crt="${dir}/ca.crt" \
    --dry-run=client -o yaml |
    kubectl label --local -f - -o yaml \
      "app.kubernetes.io/part-of=${PROJECT_NAME}" \
      "app.kubernetes.io/managed-by=platform.sh" |
    kubectl apply -f - >/dev/null
  log_info "secrets: applied ${K8S_NAMESPACE}/${secret}"
}

# k8s_ensure_admin_secret - Keycloak bootstrap admin; created once, never rotated here.
k8s_ensure_admin_secret() {
  local secret="${HELM_RELEASE}-keycloak-admin" tmp
  if [[ "${DRY_RUN}" == "1" ]]; then
    printf '[dry-run] kubectl create secret %s/%s with a random password (if missing)\n' "$K8S_NAMESPACE" "$secret"
    return 0
  fi
  if kubectl --namespace "$K8S_NAMESPACE" get secret "$secret" >/dev/null 2>&1; then
    log_info "secrets: ${K8S_NAMESPACE}/${secret} exists, keeping it"
    return 0
  fi
  tmp=$(platform_tmpdir)
  (
    umask 077
    printf 'temp-admin' >"${tmp}/username"
    openssl rand -base64 33 | tr -d '\n' >"${tmp}/password"
  )
  kubectl --namespace "$K8S_NAMESPACE" create secret generic "$secret" \
    --from-file=username="${tmp}/username" --from-file=password="${tmp}/password" >/dev/null
  rm -rf "$tmp"
  log_info "secrets: created ${K8S_NAMESPACE}/${secret} (read it with: kubectl -n ${K8S_NAMESPACE} get secret ${secret} -o jsonpath='{.data.password}' | base64 -d)"
}

secrets_main() {
  local pod_security=1 leaf
  while (($# > 0)); do
    case "$1" in
      --namespace)
        [[ $# -ge 2 ]] || die "secrets: --namespace needs a value" 2
        K8S_NAMESPACE=$2
        shift
        ;;
      --release)
        [[ $# -ge 2 ]] || die "secrets: --release needs a value" 2
        HELM_RELEASE=$2
        shift
        ;;
      --no-pod-security) pod_security=0 ;;
      -h | --help)
        secrets_usage
        return 0
        ;;
      *) die "secrets: unknown option '$1' (see: platform.sh secrets --help)" 2 ;;
    esac
    shift
  done
  config_ready
  log_step "Loading certificates into namespace ${K8S_NAMESPACE}"
  require_cmd kubectl "Install kubectl and select the right context."
  require_cmd openssl
  if [[ "${DRY_RUN}" != "1" ]]; then
    certs_require "${CERT_LEAVES[@]}"
    certs_verify "${CERT_LEAVES[@]}" >/dev/null 2>&1 ||
      die "secrets: certificates in ${CERT_DIR} do not verify. Run: platform.sh certs --verify"
  fi
  k8s_ensure_namespace "$pod_security"
  if [[ "$CERT_SOURCE" == "cert-manager" ]]; then
    # cert-manager owns the mTLS Secrets; only the SAML signing key comes from here.
    log_info "secrets: CERT_SOURCE=cert-manager, loading only the SAML signing certificate"
    k8s_apply_tls_secret saml-sp
  else
    for leaf in "${CERT_LEAVES[@]}"; do k8s_apply_tls_secret "$leaf"; done
  fi
  k8s_ensure_admin_secret
}

_helm_cert_source() {
  case "$CERT_SOURCE" in
    cert-manager) printf 'certManager' ;;
    *) printf '%s' "$CERT_SOURCE" ;;
  esac
}

# _helm_pushed_digest COMPONENT - sha256:... when `push` recorded one for IMAGE_TAG.
_helm_pushed_digest() {
  local component=$1 manifest="${BUILD_DIR}/images.pushed.env" line
  [[ -f "$manifest" ]] || return 0
  line=$(grep "^${component}=" "$manifest" | grep " tag=${IMAGE_TAG}\$" | head -n 1 || true)
  [[ -n "$line" ]] || return 0
  line=${line#*@}
  printf '%s' "${line%% *}"
}

# _yaml_string VALUE - double-quoted YAML scalar. Config values are validated
# (no quotes, backslashes or newlines), so quoting is all that is needed.
_yaml_string() { printf '"%s"' "$1"; }

# certs_issuer_dn - RFC 2253 subject of the CA, exactly as Keycloak compares it.
_helm_issuer_dn() {
  local ca
  ca=$(certs_path ca ca.crt)
  if [[ -s "$ca" ]]; then
    openssl x509 -in "$ca" -noout -subject -nameopt RFC2253 | sed 's/^subject= *//'
  fi
}

# helm_generated_values REGISTRY - print the values file that ties the chart to
# what certs/build/push produced: images, URLs, certificate subjects and the
# SAML signing certificate. A values file (not --set) because subject DNs
# contain commas, which --set would split.
helm_generated_values() {
  local registry=$1 component key digest saml_crt issuer_dn
  printf '# Generated by platform.sh deploy from config/platform.env - do not edit.\n'
  printf 'clusterDomain: %s\n' "$(_yaml_string "$CLUSTER_DOMAIN")"
  if [[ -n "$registry" ]]; then
    printf 'global:\n  imageRegistry: %s\n' "$(_yaml_string "$registry")"
  fi
  printf 'certificates:\n'
  printf '  source: %s\n' "$(_yaml_string "$(_helm_cert_source)")"
  printf '  subject:\n'
  printf '    organization: %s\n' "$(_yaml_string "$CERT_ORG")"
  printf '    organizationalUnit: %s\n' "$(_yaml_string "$CERT_OU")"
  printf '    country: %s\n' "$(_yaml_string "$CERT_COUNTRY")"
  printf '  caCommonName: %s\n' "$(_yaml_string "${PROJECT_NAME} Root CA")"
  issuer_dn=$(_helm_issuer_dn)
  if [[ -n "$issuer_dn" && "$CERT_SOURCE" != "cert-manager" ]]; then
    printf '  issuerDn: %s\n' "$(_yaml_string "$issuer_dn")"
  fi
  for component in "${COMPONENTS[@]}"; do
    key=$(component_helm_key "$component")
    printf '%s:\n' "$key"
    printf '  image:\n'
    printf '    repository: %s\n' "$(_yaml_string "$(component_image_repo "$component")")"
    printf '    tag: %s\n' "$(_yaml_string "$IMAGE_TAG")"
    digest=""
    if [[ -n "$registry" ]]; then digest=$(_helm_pushed_digest "$component"); fi
    if [[ -n "$digest" ]]; then printf '    digest: %s\n' "$(_yaml_string "$digest")"; fi
    case "$component" in
      keycloak)
        printf '  realm:\n    name: %s\n' "$(_yaml_string "$KC_REALM")"
        printf '  database:\n    vendor: %s\n' "$(_yaml_string "$KC_DB_VENDOR")"
        if [[ "$KC_PUBLIC_URL" != "$KC_INTERNAL_URL" ]]; then
          printf '  publicUrl: %s\n' "$(_yaml_string "$KC_PUBLIC_URL")"
        fi
        ;;
      app)
        if [[ "$APP_PUBLIC_URL" != "$APP_INTERNAL_URL" ]]; then
          printf '  publicUrl: %s\n' "$(_yaml_string "$APP_PUBLIC_URL")"
        fi
        saml_crt=$(certs_path saml-sp tls.crt)
        if [[ -s "$saml_crt" ]]; then
          printf '  saml:\n    signing:\n      enabled: true\n'
          printf '      certificate: %s\n' "$(_yaml_string "$(certs_der_b64 "$saml_crt")")"
        fi
        ;;
    esac
  done
}

deploy_main() {
  local registry="" registry_set=0 wait=1 file arg generated
  local values=() sets=() args=()
  while (($# > 0)); do
    case "$1" in
      --namespace)
        [[ $# -ge 2 ]] || die "deploy: --namespace needs a value" 2
        K8S_NAMESPACE=$2
        shift
        ;;
      --release)
        [[ $# -ge 2 ]] || die "deploy: --release needs a value" 2
        HELM_RELEASE=$2
        shift
        ;;
      --tag)
        [[ $# -ge 2 ]] || die "deploy: --tag needs a value" 2
        IMAGE_TAG=$2
        shift
        ;;
      --registry)
        [[ $# -ge 2 ]] || die "deploy: --registry needs a value" 2
        registry=$2
        registry_set=1
        shift
        ;;
      --cert-source)
        [[ $# -ge 2 ]] || die "deploy: --cert-source needs a value" 2
        CERT_SOURCE=$2
        shift
        ;;
      --values)
        [[ $# -ge 2 ]] || die "deploy: --values needs a value" 2
        values+=("$2")
        shift
        ;;
      --set)
        [[ $# -ge 2 ]] || die "deploy: --set needs a value" 2
        sets+=("$2")
        shift
        ;;
      --no-wait) wait=0 ;;
      -h | --help)
        deploy_usage
        return 0
        ;;
      *) die "deploy: unknown option '$1' (see: platform.sh deploy --help)" 2 ;;
    esac
    shift
  done
  config_ready
  if [[ "$registry_set" == "0" ]]; then registry=$ACR_LOGIN_SERVER; fi

  log_step "Deploying release ${HELM_RELEASE} to namespace ${K8S_NAMESPACE}"
  require_cmd helm "Install Helm 3.14+ (or 4.x)."
  [[ -f "${HELM_CHART}/Chart.yaml" ]] || die "deploy: no chart at ${HELM_CHART}" 2

  # Generated values first, so values files and --set given by the user win.
  generated="${BUILD_DIR}/helm-values.generated.yaml"
  if [[ "${DRY_RUN}" == "1" ]]; then
    printf '[dry-run] write %s:\n' "$generated"
    helm_generated_values "$registry" | sed 's/^/[dry-run]   /'
  else
    mkdir -p "$BUILD_DIR"
    helm_generated_values "$registry" >"$generated"
    log_info "deploy: wrote ${generated}"
  fi

  args=(upgrade --install "$HELM_RELEASE" "$HELM_CHART"
    --namespace "$K8S_NAMESPACE" --create-namespace --timeout "$HELM_TIMEOUT"
    --values "$generated")
  if [[ "$wait" == "1" ]]; then args+=(--wait); fi
  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    file=$(abs_path "$file")
    [[ -f "$file" ]] || die "deploy: values file not found: ${file}" 2
    args+=(--values "$file")
  done < <(
    csv_split "$HELM_VALUES"
    if ((${#values[@]} > 0)); then printf '%s\n' "${values[@]}"; fi
  )
  if ((${#sets[@]} > 0)); then
    for arg in "${sets[@]}"; do args+=(--set "$arg"); done
  fi
  run helm "${args[@]}"
}

test_main() {
  local timeout="5m"
  while (($# > 0)); do
    case "$1" in
      --namespace)
        [[ $# -ge 2 ]] || die "test: --namespace needs a value" 2
        K8S_NAMESPACE=$2
        shift
        ;;
      --release)
        [[ $# -ge 2 ]] || die "test: --release needs a value" 2
        HELM_RELEASE=$2
        shift
        ;;
      --timeout)
        [[ $# -ge 2 ]] || die "test: --timeout needs a value" 2
        timeout=$2
        shift
        ;;
      -h | --help)
        test_usage
        return 0
        ;;
      *) die "test: unknown option '$1' (see: platform.sh test --help)" 2 ;;
    esac
    shift
  done
  config_ready
  log_step "Running in-cluster tests for release ${HELM_RELEASE}"
  require_cmd helm "Install Helm 3.14+ (or 4.x)."
  run helm test "$HELM_RELEASE" --namespace "$K8S_NAMESPACE" --logs --timeout "$timeout"
}

status_main() {
  config_ready
  require_cmd kubectl
  run kubectl --namespace "$K8S_NAMESPACE" get pods,services,secrets \
    --selector "app.kubernetes.io/instance=${HELM_RELEASE}" --output wide
}
