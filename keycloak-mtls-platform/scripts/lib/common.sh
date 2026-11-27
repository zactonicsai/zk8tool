#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
# scripts/lib/common.sh - logging, configuration loading and command helpers.
#
# Sourced by scripts/platform.sh and by the bats tests; never executed.
# Docs: docs/scripts/lib-common.md
# =============================================================================

if [[ -n "${__PLATFORM_COMMON_SH:-}" ]]; then return 0; fi
__PLATFORM_COMMON_SH=1

# The version of this tooling (not of the images).
# shellcheck disable=SC2034  # read by platform.sh
PLATFORM_VERSION="1.0.0"

: "${DRY_RUN:=0}"
: "${VERBOSE:=0}"

# Repository root: two levels above this file unless the caller already set it.
if [[ -z "${PLATFORM_ROOT:-}" ]]; then
  PLATFORM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi

# -----------------------------------------------------------------------------
# Logging (always to stderr so stdout stays machine readable)
# -----------------------------------------------------------------------------
_log() {
  local level=$1
  shift
  local color="" reset=""
  if [[ -t 2 && -z "${NO_COLOR:-}" ]]; then
    reset=$'\033[0m'
    case "$level" in
      ERROR) color=$'\033[31m' ;;
      WARN) color=$'\033[33m' ;;
      STEP) color=$'\033[1;36m' ;;
      DEBUG) color=$'\033[2m' ;;
      *) color="" ;;
    esac
  fi
  printf '%s[%s]%s %s\n' "$color" "$level" "$reset" "$*" >&2
}

log_info() { _log INFO "$@"; }
log_warn() { _log WARN "$@"; }
log_error() { _log ERROR "$@"; }
log_step() { _log STEP "$@"; }
log_debug() {
  if [[ "${VERBOSE}" == "1" ]]; then _log DEBUG "$@"; fi
}

# die MESSAGE [EXIT_CODE]
die() {
  log_error "$1"
  exit "${2:-1}"
}

# -----------------------------------------------------------------------------
# Command helpers
# -----------------------------------------------------------------------------
have_cmd() { command -v "$1" >/dev/null 2>&1; }

# require_cmd NAME [HINT] - fail (exit 127) when a tool is missing.
# In dry-run mode a missing tool is only a warning: nothing will be executed.
require_cmd() {
  local cmd=$1 hint=${2:-}
  if have_cmd "$cmd"; then return 0; fi
  if [[ "${DRY_RUN}" == "1" ]]; then
    log_warn "'$cmd' not found (ignored in dry-run)"
    return 0
  fi
  die "Required command '$cmd' not found.${hint:+ $hint}" 127
}

# quote_cmd ARGS... - print a copy-pasteable, shell-quoted command line.
quote_cmd() {
  local out="" arg
  for arg in "$@"; do
    out+="$(printf '%q' "$arg") "
  done
  printf '%s' "${out% }"
}

# run ARGS... - execute a state-changing command, or print it in dry-run mode.
# Read-only commands (openssl verify, docker inspect, ...) are called directly.
run() {
  if [[ "${DRY_RUN}" == "1" ]]; then
    printf '[dry-run] %s\n' "$(quote_cmd "$@")"
    return 0
  fi
  log_debug "+ $(quote_cmd "$@")"
  "$@"
}

# platform_tmp_init / platform_tmpdir / platform_cleanup - private scratch
# space. platform.sh calls platform_tmp_init once and removes everything in an
# EXIT trap, so half-written keys never survive a failed run.
platform_tmp_init() {
  if [[ -z "${PLATFORM_TMP_ROOT:-}" || ! -d "${PLATFORM_TMP_ROOT}" ]]; then
    PLATFORM_TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/platform.XXXXXX")
    chmod 700 "$PLATFORM_TMP_ROOT"
  fi
}

platform_tmpdir() {
  if [[ -n "${PLATFORM_TMP_ROOT:-}" && -d "${PLATFORM_TMP_ROOT}" ]]; then
    mktemp -d "${PLATFORM_TMP_ROOT}/XXXXXX"
  else
    mktemp -d "${TMPDIR:-/tmp}/platform.XXXXXX"
  fi
}

platform_cleanup() {
  if [[ -n "${PLATFORM_TMP_ROOT:-}" && -d "${PLATFORM_TMP_ROOT}" ]]; then
    rm -rf "${PLATFORM_TMP_ROOT}"
  fi
}

# abs_path PATH - resolve a path relative to the repository root.
abs_path() {
  case "$1" in
    /*) printf '%s' "$1" ;;
    *) printf '%s' "${PLATFORM_ROOT}/$1" ;;
  esac
}

# contains ITEM LIST... - true when ITEM equals one of the remaining arguments.
contains() {
  local needle=$1 item
  shift
  for item in "$@"; do
    if [[ "$item" == "$needle" ]]; then return 0; fi
  done
  return 1
}

# csv_split "a, b,c" - print one trimmed, non-empty item per line.
csv_split() {
  local IFS=',' item
  # shellcheck disable=SC2206  # intentional splitting on commas
  local items=($1)
  for item in "${items[@]}"; do
    item="${item#"${item%%[![:space:]]*}"}"
    item="${item%"${item##*[![:space:]]}"}"
    if [[ -n "$item" ]]; then printf '%s\n' "$item"; fi
  done
}

# url_host https://host:port/path - print "host".
url_host() {
  local rest=${1#*://}
  rest=${rest%%/*}
  printf '%s' "${rest%%:*}"
}

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
# Every key the config file may contain. Unknown keys produce a warning, which
# catches typos such as ACR_NAMES=.
CONFIG_KEYS=(
  PROJECT_NAME IMAGE_TAG BUILD_DIR
  KEYCLOAK_VERSION KEYCLOAK_BASE_IMAGE JAVA_VERSION JAVA_BUILD_IMAGE JAVA_RUNTIME_IMAGE
  IMAGE_KEYCLOAK IMAGE_APP IMAGE_CLIENT IMAGE_PLATFORM CONTAINER_CLI
  CERT_DIR CERT_MODE CERT_ORG CERT_OU CERT_COUNTRY CERT_KEY_ALG CERT_EC_CURVE CERT_RSA_BITS
  CERT_CA_DAYS CERT_LEAF_DAYS CERT_SAML_DAYS CERT_RENEW_BEFORE_DAYS
  CERT_EXTRA_SANS_KEYCLOAK CERT_EXTRA_SANS_APP
  KC_REALM KC_DB_VENDOR KC_HTTPS_CLIENT_AUTH KC_PUBLIC_URL APP_PUBLIC_URL
  K8S_NAMESPACE CLUSTER_DOMAIN HELM_RELEASE HELM_CHART HELM_VALUES HELM_TIMEOUT CERT_SOURCE
  AZ_SUBSCRIPTION ACR_NAME ACR_LOGIN_SERVER AKS_RESOURCE_GROUP AKS_CLUSTER
)

# Values derived from the keys above by config_finalize (printed by `config`).
CONFIG_DERIVED_KEYS=(
  KC_SERVICE_NAME APP_SERVICE_NAME CLIENT_NAME KC_SERVICE_HOST APP_SERVICE_HOST
  KC_INTERNAL_URL APP_INTERNAL_URL
)

# _config_expand VALUE - replace ${NAME} with the current value of NAME.
# Deliberately tiny: no command substitution, no defaults, no arithmetic.
_config_expand() {
  local value=$1 pre name post guard=0
  local re='^(.*)\$\{([A-Za-z_][A-Za-z0-9_]*)\}(.*)$'
  while [[ "$value" =~ $re ]]; do
    pre=${BASH_REMATCH[1]}
    name=${BASH_REMATCH[2]}
    post=${BASH_REMATCH[3]}
    value="${pre}${!name-}${post}"
    guard=$((guard + 1))
    if ((guard > 50)); then die "Config: reference loop while expanding '\${${name}}'"; fi
  done
  printf '%s' "$value"
}

# _config_parse_value RAW - strip quotes / trailing comments, expand references.
_config_parse_value() {
  local raw=$1
  local re_dq='^"(.*)"[[:space:]]*(#.*)?$'
  local re_sq="^'(.*)'[[:space:]]*(#.*)?\$"
  raw="${raw#"${raw%%[![:space:]]*}"}"
  raw="${raw%"${raw##*[![:space:]]}"}"
  if [[ "$raw" =~ $re_dq ]]; then
    _config_expand "${BASH_REMATCH[1]}"
  elif [[ "$raw" =~ $re_sq ]]; then
    printf '%s' "${BASH_REMATCH[1]}" # single quotes: literal, no expansion
  else
    raw="${raw%%[[:space:]]#*}"
    raw="${raw%"${raw##*[![:space:]]}"}"
    _config_expand "$raw"
  fi
}

# load_config_file FILE - parse KEY=VALUE lines. A key that is already set
# (by the environment, a CLI flag or a file loaded earlier) is NOT overridden.
load_config_file() {
  local file=$1 line key value lineno=0
  local re_blank='^[[:space:]]*(#.*)?$'
  local re_kv='^[[:space:]]*([A-Z][A-Z0-9_]*)=(.*)$'
  [[ -f "$file" ]] || die "Config file not found: $file" 2
  while IFS= read -r line || [[ -n "$line" ]]; do
    lineno=$((lineno + 1))
    line="${line%$'\r'}"
    if [[ "$line" =~ $re_blank ]]; then continue; fi
    if [[ ! "$line" =~ $re_kv ]]; then
      die "Config: ${file}:${lineno}: expected KEY=VALUE, got: ${line}" 2
    fi
    key=${BASH_REMATCH[1]}
    value=${BASH_REMATCH[2]}
    if ! contains "$key" "${CONFIG_KEYS[@]}"; then
      log_warn "Config: ${file}:${lineno}: unknown key '${key}' ignored"
      continue
    fi
    if [[ -n "${!key+x}" ]]; then
      log_debug "Config: ${key} already set, keeping '${!key}'"
      continue
    fi
    value=$(_config_parse_value "$value")
    printf -v "$key" '%s' "$value"
  done <"$file"
  log_debug "Config: loaded ${file}"
}

# config_finalize - apply built-in defaults, resolve paths, compute derived values.
config_finalize() {
  : "${PROJECT_NAME:=iam-platform}"
  : "${IMAGE_TAG:=0.1.0}"
  : "${BUILD_DIR:=build}"
  : "${KEYCLOAK_VERSION:=26.8.2}"
  : "${KEYCLOAK_BASE_IMAGE:=quay.io/keycloak/keycloak}"
  : "${JAVA_VERSION:=25}"
  : "${JAVA_BUILD_IMAGE:=eclipse-temurin:${JAVA_VERSION}-jdk}"
  : "${JAVA_RUNTIME_IMAGE:=eclipse-temurin:${JAVA_VERSION}-jre}"
  : "${IMAGE_KEYCLOAK:=${PROJECT_NAME}/keycloak}"
  : "${IMAGE_APP:=${PROJECT_NAME}/spring-app}"
  : "${IMAGE_CLIENT:=${PROJECT_NAME}/test-client}"
  : "${IMAGE_PLATFORM:=linux/amd64}"
  : "${CONTAINER_CLI:=docker}"
  : "${CERT_DIR:=${BUILD_DIR}/certs}"
  : "${CERT_MODE:=trust}"
  : "${CERT_ORG:=Example Corp}"
  : "${CERT_OU:=Platform}"
  : "${CERT_COUNTRY:=US}"
  : "${CERT_KEY_ALG:=ec}"
  : "${CERT_EC_CURVE:=prime256v1}"
  : "${CERT_RSA_BITS:=3072}"
  : "${CERT_CA_DAYS:=1825}"
  : "${CERT_LEAF_DAYS:=90}"
  : "${CERT_SAML_DAYS:=730}"
  : "${CERT_RENEW_BEFORE_DAYS:=30}"
  : "${CERT_EXTRA_SANS_KEYCLOAK:=}"
  : "${CERT_EXTRA_SANS_APP:=}"
  : "${KC_REALM:=platform}"
  : "${KC_DB_VENDOR:=dev-file}"
  : "${KC_HTTPS_CLIENT_AUTH:=request}"
  : "${K8S_NAMESPACE:=iam}"
  : "${CLUSTER_DOMAIN:=cluster.local}"
  : "${HELM_RELEASE:=iam}"
  : "${HELM_CHART:=helm/iam-platform}"
  : "${HELM_VALUES:=}"
  : "${HELM_TIMEOUT:=10m}"
  : "${CERT_SOURCE:=secret}"
  : "${AZ_SUBSCRIPTION:=}"
  : "${ACR_NAME:=}"
  : "${ACR_LOGIN_SERVER:=}"
  : "${AKS_RESOURCE_GROUP:=}"
  : "${AKS_CLUSTER:=}"

  BUILD_DIR=$(abs_path "$BUILD_DIR")
  CERT_DIR=$(abs_path "$CERT_DIR")
  HELM_CHART=$(abs_path "$HELM_CHART")

  # Names must match the Helm chart helpers (helm/iam-platform/templates/_helpers.tpl).
  # shellcheck disable=SC2034  # CLIENT_NAME is read by certs.sh
  CLIENT_NAME="${HELM_RELEASE}-test-client"
  KC_SERVICE_NAME="${HELM_RELEASE}-keycloak"
  APP_SERVICE_NAME="${HELM_RELEASE}-spring-app"
  KC_SERVICE_HOST="${KC_SERVICE_NAME}.${K8S_NAMESPACE}.svc.${CLUSTER_DOMAIN}"
  APP_SERVICE_HOST="${APP_SERVICE_NAME}.${K8S_NAMESPACE}.svc.${CLUSTER_DOMAIN}"
  KC_INTERNAL_URL="https://${KC_SERVICE_HOST}:8443"
  APP_INTERNAL_URL="https://${APP_SERVICE_HOST}:8443"
  : "${KC_PUBLIC_URL:=${KC_INTERNAL_URL}}"
  : "${APP_PUBLIC_URL:=${APP_INTERNAL_URL}}"
  KC_PUBLIC_URL=${KC_PUBLIC_URL%/}
  APP_PUBLIC_URL=${APP_PUBLIC_URL%/}

  if [[ -z "$ACR_LOGIN_SERVER" && -n "$ACR_NAME" ]]; then
    ACR_LOGIN_SERVER="${ACR_NAME}.azurecr.io"
  fi
  # shellcheck disable=SC2034  # consumed by other libs
  CONFIG_FINALIZED=1
}

_validate_enum() {
  local key=$1
  shift
  if ! contains "${!key}" "$@"; then
    die "Config: ${key}='${!key}' is invalid (allowed: $*)" 2
  fi
}

_validate_regex() {
  local key=$1 re=$2 hint=$3
  if [[ ! "${!key}" =~ $re ]]; then
    die "Config: ${key}='${!key}' is invalid (${hint})" 2
  fi
}

# config_validate - fail fast on values that would break later steps.
config_validate() {
  local re_int='^[1-9][0-9]*$'
  local re_dns='^[a-z0-9]([-a-z0-9]*[a-z0-9])?$'
  local re_repo='^[a-z0-9]+([._/-][a-z0-9]+)*$'
  local re_tag='^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$'
  local re_dn='^[A-Za-z0-9 ._-]+$'
  local re_url='^https://[^/[:space:]]+(/[^[:space:]]*)?$'
  local key

  _validate_enum CERT_MODE trust baked none
  _validate_enum CERT_KEY_ALG ec rsa
  _validate_enum CERT_SOURCE secret cert-manager image
  _validate_enum KC_DB_VENDOR dev-file postgres mariadb mssql mysql oracle
  _validate_enum KC_HTTPS_CLIENT_AUTH request required
  _validate_enum CONTAINER_CLI docker podman nerdctl

  for key in CERT_CA_DAYS CERT_LEAF_DAYS CERT_SAML_DAYS CERT_RENEW_BEFORE_DAYS CERT_RSA_BITS; do
    _validate_regex "$key" "$re_int" "positive integer expected"
  done
  if ((CERT_RSA_BITS < 2048)); then die "Config: CERT_RSA_BITS must be >= 2048" 2; fi
  if ((CERT_RENEW_BEFORE_DAYS >= CERT_LEAF_DAYS)); then
    die "Config: CERT_RENEW_BEFORE_DAYS (${CERT_RENEW_BEFORE_DAYS}) must be smaller than CERT_LEAF_DAYS (${CERT_LEAF_DAYS})" 2
  fi

  for key in K8S_NAMESPACE HELM_RELEASE; do
    _validate_regex "$key" "$re_dns" "lowercase DNS label expected"
  done
  if ((${#HELM_RELEASE} > 40)); then die "Config: HELM_RELEASE must be at most 40 characters" 2; fi
  for key in IMAGE_KEYCLOAK IMAGE_APP IMAGE_CLIENT; do
    _validate_regex "$key" "$re_repo" "lowercase repository name expected"
  done
  _validate_regex IMAGE_TAG "$re_tag" "valid image tag expected"
  if [[ "$IMAGE_TAG" == "latest" ]]; then
    die "Config: IMAGE_TAG=latest is not allowed; use an immutable tag (version or git SHA)" 2
  fi
  for key in CERT_ORG CERT_OU; do
    _validate_regex "$key" "$re_dn" "letters, digits, space, dot, dash, underscore"
  done
  _validate_regex CERT_COUNTRY '^[A-Z]{2}$' "two-letter ISO country code"
  _validate_regex KC_REALM '^[A-Za-z0-9_-]+$' "letters, digits, dash, underscore"
  for key in KC_PUBLIC_URL APP_PUBLIC_URL; do
    _validate_regex "$key" "$re_url" "https:// URL expected"
  done
  if [[ -n "$ACR_NAME" ]]; then
    _validate_regex ACR_NAME '^[a-zA-Z0-9]{5,50}$' "5-50 alphanumeric characters, no .azurecr.io suffix"
  fi
  if [[ "$CERT_SOURCE" == "image" && "$CERT_MODE" != "baked" ]]; then
    die "Config: CERT_SOURCE=image requires CERT_MODE=baked" 2
  fi
}

# config_ready - finalize + validate. Every command calls this after it has
# applied its own flags, so flags can still override configuration keys.
config_ready() {
  config_finalize
  config_validate
}

# config_print - effective configuration as KEY=VALUE (contains no secrets).
config_print() {
  local key
  for key in "${CONFIG_KEYS[@]}"; do
    printf '%s=%s\n' "$key" "${!key-}"
  done
  printf '# derived\n'
  for key in "${CONFIG_DERIVED_KEYS[@]}"; do
    printf '%s=%s\n' "$key" "${!key-}"
  done
}

# -----------------------------------------------------------------------------
# Components (the three images / workloads)
# -----------------------------------------------------------------------------
COMPONENTS=(keycloak app client)

# parse_components CSV - validate a --only list; prints one component per line.
parse_components() {
  local item
  if [[ -z "${1:-}" ]]; then
    printf '%s\n' "${COMPONENTS[@]}"
    return 0
  fi
  while IFS= read -r item; do
    if ! contains "$item" "${COMPONENTS[@]}"; then
      die "Unknown component '${item}' (allowed: ${COMPONENTS[*]})" 2
    fi
    printf '%s\n' "$item"
  done < <(csv_split "$1")
}

# component_image_repo COMPONENT - repository name without registry or tag.
component_image_repo() {
  case "$1" in
    keycloak) printf '%s' "$IMAGE_KEYCLOAK" ;;
    app) printf '%s' "$IMAGE_APP" ;;
    client) printf '%s' "$IMAGE_CLIENT" ;;
    *) die "Unknown component '$1'" 2 ;;
  esac
}

# component_cert_name COMPONENT - directory name under CERT_DIR.
component_cert_name() {
  case "$1" in
    keycloak) printf 'keycloak' ;;
    app) printf 'spring-app' ;;
    client) printf 'test-client' ;;
    *) die "Unknown component '$1'" 2 ;;
  esac
}

# component_helm_key COMPONENT - top-level key in the chart's values.yaml.
component_helm_key() {
  case "$1" in
    keycloak) printf 'keycloak' ;;
    app) printf 'app' ;;
    client) printf 'testClient' ;;
    *) die "Unknown component '$1'" 2 ;;
  esac
}
