#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
# Shared setup for the bats suites in tests/scripts.
#
# Every test gets its own sandbox: a temp directory holding a config file,
# a build/cert directory and a bin/ directory with STUBS for docker, az,
# kubectl and helm. The stubs record their command line in $STUB_LOG, so the
# tests assert on what platform.sh WOULD have run without touching a daemon,
# a registry or a cluster. openssl is real: certificates are really generated.
# =============================================================================

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PLATFORM="${REPO_ROOT}/scripts/platform.sh"

# Config keys must not leak in from the developer's shell or CI environment.
_clear_config_env() {
  local key
  for key in PROJECT_NAME IMAGE_TAG BUILD_DIR KEYCLOAK_VERSION KEYCLOAK_BASE_IMAGE JAVA_VERSION \
    JAVA_BUILD_IMAGE JAVA_RUNTIME_IMAGE IMAGE_KEYCLOAK IMAGE_APP IMAGE_CLIENT IMAGE_PLATFORM CONTAINER_CLI \
    CERT_DIR CERT_MODE CERT_ORG CERT_OU CERT_COUNTRY CERT_KEY_ALG CERT_EC_CURVE CERT_RSA_BITS CERT_CA_DAYS \
    CERT_LEAF_DAYS CERT_SAML_DAYS CERT_RENEW_BEFORE_DAYS CERT_EXTRA_SANS_KEYCLOAK CERT_EXTRA_SANS_APP \
    KC_REALM KC_DB_VENDOR KC_HTTPS_CLIENT_AUTH KC_PUBLIC_URL APP_PUBLIC_URL K8S_NAMESPACE CLUSTER_DOMAIN \
    HELM_RELEASE HELM_CHART HELM_VALUES HELM_TIMEOUT CERT_SOURCE AZ_SUBSCRIPTION ACR_NAME ACR_LOGIN_SERVER \
    AKS_RESOURCE_GROUP AKS_CLUSTER DRY_RUN VERBOSE; do
    unset "$key"
  done
}

setup_sandbox() {
  _clear_config_env
  SANDBOX="$(mktemp -d)"
  export SANDBOX
  export STUB_LOG="${SANDBOX}/stub.log"
  export NO_COLOR=1
  : >"$STUB_LOG"
  CONFIG="${SANDBOX}/platform.env"
  cat >"$CONFIG" <<EOF
PROJECT_NAME=iam-platform
IMAGE_TAG=1.2.3
BUILD_DIR=${SANDBOX}/build
CERT_DIR=${SANDBOX}/certs
K8S_NAMESPACE=iam
HELM_RELEASE=iam
EOF
  mkdir -p "${SANDBOX}/bin"
  local tool
  for tool in docker az kubectl helm; do
    cat >"${SANDBOX}/bin/${tool}" <<'EOF'
#!/usr/bin/env bash
# Test stub: records the invocation, answers the few queries platform.sh makes.
name="$(basename "$0")"
# One write per invocation: stubs in a pipeline run concurrently and must not
# interleave their log lines.
line="$name"
for arg in "$@"; do line+=" $arg"; done
printf '%s\n' "$line" >>"$STUB_LOG"
# Commands reading a manifest from a pipe must drain it, or the writer gets SIGPIPE.
for arg in "$@"; do
  if [[ "$arg" == "-" ]]; then cat >/dev/null; fi
done
case "$name $*" in
  "docker image inspect --format"*RepoDigests*) printf '%s\n' "${STUB_REPO_DIGEST:-}" ;;
  "docker image inspect --format"*Labels*) printf '%s\n' "${STUB_CERT_MODE:-trust}" ;;
  "docker image inspect "*) exit "${STUB_IMAGE_INSPECT_RC:-0}" ;;
  "kubectl "*" get secret "*) exit "${STUB_SECRET_GET_RC:-1}" ;;
  "kubectl create "*"--dry-run=client"*) printf 'apiVersion: v1\nkind: Stub\n' ;;
  "kubectl label --local"*) printf 'apiVersion: v1\nkind: Stub\n' ;;
esac
exit 0
EOF
    chmod +x "${SANDBOX}/bin/${tool}"
  done
  PATH="${SANDBOX}/bin:${PATH}"
  export PATH
}

teardown_sandbox() {
  if [[ -n "${SANDBOX:-}" && -d "${SANDBOX}" ]]; then
    rm -rf "${SANDBOX}"
  fi
}

# platform ARGS... - run platform.sh with the sandbox config.
platform() {
  "$PLATFORM" --config "$CONFIG" "$@"
}

# set_config KEY VALUE - append (or override) a key in the sandbox config.
set_config() {
  grep -v "^$1=" "$CONFIG" >"${CONFIG}.tmp" || true
  printf '%s=%s\n' "$1" "$2" >>"${CONFIG}.tmp"
  mv "${CONFIG}.tmp" "$CONFIG"
}

# stub_calls PATTERN - number of recorded stub invocations matching a regex.
stub_calls() {
  grep -c -E -- "$1" "$STUB_LOG" || true
}

# cert_text NAME - human readable dump of a generated certificate.
cert_text() {
  openssl x509 -in "${SANDBOX}/certs/$1/tls.crt" -noout -text
}

cert_serial() {
  openssl x509 -in "${SANDBOX}/certs/$1/tls.crt" -noout -serial
}

file_mode() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"
}
