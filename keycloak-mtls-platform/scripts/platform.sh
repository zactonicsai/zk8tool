#!/usr/bin/env bash
# =============================================================================
# platform.sh - one entry point for the Keycloak + Spring Boot mTLS platform.
#
#   certs -> build -> push -> secrets -> deploy -> test
#
# Run `platform.sh help` for the command list and `platform.sh <command> --help`
# for the options of one command. Docs: docs/scripts/platform.md
# =============================================================================
set -Eeuo pipefail

if ((BASH_VERSINFO[0] < 4)); then
  printf 'platform.sh needs bash 4 or newer (found %s). On macOS: brew install bash\n' "$BASH_VERSION" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
export PLATFORM_ROOT

# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=scripts/lib/certs.sh
source "${SCRIPT_DIR}/lib/certs.sh"
# shellcheck source=scripts/lib/images.sh
source "${SCRIPT_DIR}/lib/images.sh"
# shellcheck source=scripts/lib/acr.sh
source "${SCRIPT_DIR}/lib/acr.sh"
# shellcheck source=scripts/lib/k8s.sh
source "${SCRIPT_DIR}/lib/k8s.sh"
# shellcheck source=scripts/lib/verify.sh
source "${SCRIPT_DIR}/lib/verify.sh"

usage() {
  cat <<EOF
platform.sh ${PLATFORM_VERSION} - build, publish and deploy Keycloak + a Java 25
Spring Boot app (OIDC + SAML) with mutual TLS everywhere.

Usage:
  platform.sh [global options] <command> [command options]

Global options (before the command):
  -c, --config FILE   Config file (default: config/platform.env, with
                      config/platform.local.env overriding it when present)
  -n, --dry-run       Print the commands that would change something; run nothing
  -v, --verbose       Debug logging
  -h, --help          Show this help
      --version       Print the tooling version

Commands:
  config            Print the effective configuration
  doctor            Check which required tools are installed
  certs             Create / renew the CA and the mTLS certificates
  build             Build the images and load certificates into them
  push              Push the images to Azure Container Registry
  aks-credentials   Fetch the kubeconfig of the configured AKS cluster
  aks-attach        Let the AKS cluster pull from the registry (AcrPull)
  secrets           Load certificates into the cluster as Secrets
  deploy            helm upgrade --install the chart
  test              helm test: run the Java 25 test-client pod
  status            Show the release's pods, services and secrets
  verify            Run all local linters and test suites
  all               certs, build, push, secrets, deploy, test in one go
  clean             Remove staged build contexts (and optionally certificates)
  help              Show this help

Examples:
  platform.sh certs
  platform.sh build --tag 1.4.0
  platform.sh push --acr myregistry --tag 1.4.0 --lock
  platform.sh --dry-run all --tag 1.4.0
  platform.sh deploy --values helm/iam-platform/values-production.yaml
  platform.sh test
EOF
}

doctor_main() {
  local strict=0 tool missing=0 status version
  local required=(bash openssl git) optional=(docker az kubectl helm java keytool shellcheck bats hadolint kubeconform)
  if [[ "${1:-}" == "--strict" ]]; then strict=1; fi
  printf '%-12s %-9s %s\n' TOOL STATUS VERSION
  for tool in "${required[@]}" "${optional[@]}"; do
    if have_cmd "$tool"; then
      status=ok
      case "$tool" in
        openssl | helm) version=$("$tool" version 2>/dev/null | head -n 1 || true) ;;
        kubeconform) version=$("$tool" -v 2>/dev/null | head -n 1 || true) ;;
        kubectl) version=$("$tool" version --client 2>/dev/null | head -n 1 || true) ;;
        java) version=$("$tool" -version 2>&1 | grep -i version | head -n 1 || true) ;;
        keytool) version="" ;;
        *) version=$("$tool" --version 2>/dev/null | head -n 1 || true) ;;
      esac
    else
      version=""
      if contains "$tool" "${required[@]}"; then
        status=MISSING
        missing=1
      else
        status=missing
        if [[ "$strict" == "1" ]]; then missing=1; fi
      fi
    fi
    printf '%-12s %-9s %s\n' "$tool" "$status" "$version"
  done
  printf '\nNeeded per command: certs=openssl  build=docker  push=az,docker  secrets=kubectl,openssl\n'
  printf '                    deploy,test=helm  verify=shellcheck,bats,hadolint,helm,kubeconform,java 25\n'
  return "$missing"
}

# safe_rm_rf PATH - refuse obviously dangerous targets before deleting.
safe_rm_rf() {
  local target=$1
  case "$target" in
    "" | "/" | "$HOME" | "$PLATFORM_ROOT" | "${PLATFORM_ROOT}/") die "clean: refusing to delete '${target}'" 2 ;;
  esac
  case "$target" in
    /*) ;;
    *) die "clean: refusing to delete relative path '${target}'" 2 ;;
  esac
  run rm -rf "$target"
}

clean_main() {
  local certs=0
  while (($# > 0)); do
    case "$1" in
      --certs) certs=1 ;;
      -h | --help)
        printf 'Usage: platform.sh clean [--certs]\n\nRemove staged build contexts and manifests. With --certs also delete the CA\nand every certificate and private key in CERT_DIR.\n'
        return 0
        ;;
      *) die "clean: unknown option '$1'" 2 ;;
    esac
    shift
  done
  config_ready
  log_step "Cleaning ${BUILD_DIR}"
  safe_rm_rf "${BUILD_DIR}/context"
  run rm -f "${BUILD_DIR}/images.env" "${BUILD_DIR}/images.pushed.env"
  if [[ "$certs" == "1" ]]; then
    log_warn "clean: deleting the CA and all certificates in ${CERT_DIR}"
    safe_rm_rf "$CERT_DIR"
  fi
}

all_usage() {
  cat <<'EOF'
Usage: platform.sh all [options]

Run the whole pipeline: certs, build, push, secrets, deploy, test.
`push` is skipped automatically when no registry is configured (ACR_NAME empty),
which suits clusters that can see local images (kind, minikube, Docker Desktop).

Options:
  --tag TAG          Image tag for build, push and deploy
  --skip LIST        Comma separated stages to skip: certs,build,push,secrets,deploy,test
  --namespace NS     Target namespace
  --release NAME     Helm release name
  -h, --help         Show this help
EOF
}

all_main() {
  local skip="" stage list
  local stages=(certs build push secrets deploy test) skipped=()
  while (($# > 0)); do
    case "$1" in
      --tag)
        [[ $# -ge 2 ]] || die "all: --tag needs a value" 2
        IMAGE_TAG=$2
        shift
        ;;
      --skip)
        [[ $# -ge 2 ]] || die "all: --skip needs a value" 2
        skip=$2
        shift
        ;;
      --namespace)
        [[ $# -ge 2 ]] || die "all: --namespace needs a value" 2
        K8S_NAMESPACE=$2
        shift
        ;;
      --release)
        [[ $# -ge 2 ]] || die "all: --release needs a value" 2
        HELM_RELEASE=$2
        shift
        ;;
      -h | --help)
        all_usage
        return 0
        ;;
      *) die "all: unknown option '$1' (see: platform.sh all --help)" 2 ;;
    esac
    shift
  done
  config_ready
  list=$(csv_split "$skip")
  while IFS= read -r stage; do
    [[ -n "$stage" ]] || continue
    contains "$stage" "${stages[@]}" || die "all: unknown stage '${stage}' (allowed: ${stages[*]})" 2
    skipped+=("$stage")
  done <<<"$list"
  if [[ -z "$ACR_NAME" ]]; then
    log_warn "all: ACR_NAME is empty, skipping push (images stay local)"
    skipped+=(push)
  fi
  if [[ "$CERT_SOURCE" == "image" ]]; then skipped+=(secrets); fi

  for stage in "${stages[@]}"; do
    if ((${#skipped[@]} > 0)) && contains "$stage" "${skipped[@]}"; then
      log_info "all: skipping ${stage}"
      continue
    fi
    case "$stage" in
      certs) certs_main ;;
      build) images_main ;;
      push) acr_main ;;
      secrets) secrets_main ;;
      deploy) deploy_main ;;
      test) test_main ;;
    esac
  done
  log_step "Done"
}

main() {
  local config_file="" command=""
  while (($# > 0)); do
    case "$1" in
      -c | --config)
        [[ $# -ge 2 ]] || die "--config needs a file" 2
        config_file=$2
        shift 2
        ;;
      --config=*)
        config_file=${1#--config=}
        shift
        ;;
      -n | --dry-run)
        DRY_RUN=1
        shift
        ;;
      -v | --verbose)
        VERBOSE=1
        shift
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      --version)
        printf '%s\n' "$PLATFORM_VERSION"
        exit 0
        ;;
      -*) die "Unknown global option '$1' (see: platform.sh --help)" 2 ;;
      *)
        command=$1
        shift
        break
        ;;
    esac
  done
  if [[ -z "$command" ]]; then
    usage >&2
    exit 2
  fi
  if [[ "$command" == "help" ]]; then
    usage
    exit 0
  fi

  # Local overrides are loaded first: a key that is already set is never
  # replaced by a file loaded later.
  if [[ -n "$config_file" ]]; then
    load_config_file "$config_file"
  else
    if [[ -f "${PLATFORM_ROOT}/config/platform.local.env" ]]; then
      load_config_file "${PLATFORM_ROOT}/config/platform.local.env"
    fi
    load_config_file "${PLATFORM_ROOT}/config/platform.env"
  fi

  platform_tmp_init
  trap platform_cleanup EXIT

  case "$command" in
    config)
      config_ready
      config_print
      ;;
    doctor) doctor_main "$@" ;;
    certs)
      # certs_main parses its own flags; the configuration is final before that
      # because no certs flag changes a config key.
      config_ready
      certs_main "$@"
      ;;
    build) images_main "$@" ;;
    push) acr_main "$@" ;;
    aks-credentials) aks_credentials_main "$@" ;;
    aks-attach) aks_attach_main "$@" ;;
    secrets) secrets_main "$@" ;;
    deploy) deploy_main "$@" ;;
    test) test_main "$@" ;;
    status) status_main "$@" ;;
    verify) verify_main "$@" ;;
    all) all_main "$@" ;;
    clean) clean_main "$@" ;;
    *) die "Unknown command '${command}' (see: platform.sh --help)" 2 ;;
  esac
}

main "$@"
