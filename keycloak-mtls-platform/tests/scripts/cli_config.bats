#!/usr/bin/env bats
# Command line parsing and configuration loading (scripts/platform.sh, lib/common.sh).

load test_helper

setup() { setup_sandbox; }
teardown() { teardown_sandbox; }

# --- command line ---------------------------------------------------------------

@test "help lists every command" {
  run "$PLATFORM" --help
  [ "$status" -eq 0 ]
  for command in config doctor certs build push aks-credentials aks-attach secrets deploy test status verify all clean; do
    [[ "$output" == *"  ${command} "* ]]
  done
}

@test "--version prints the tooling version" {
  run "$PLATFORM" --version
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

@test "no command prints usage and exits 2" {
  run "$PLATFORM"
  [ "$status" -eq 2 ]
  [[ "$output" == *"Usage:"* ]]
}

@test "unknown command exits 2" {
  run platform frobnicate
  [ "$status" -eq 2 ]
  [[ "$output" == *"Unknown command 'frobnicate'"* ]]
}

@test "unknown global option exits 2" {
  run "$PLATFORM" --bogus config
  [ "$status" -eq 2 ]
  [[ "$output" == *"Unknown global option"* ]]
}

@test "unknown command option exits 2 and points to --help" {
  run platform build --bogus
  [ "$status" -eq 2 ]
  [[ "$output" == *"build: unknown option '--bogus'"* ]]
}

@test "an option that needs a value reports it" {
  run platform build --tag
  [ "$status" -eq 2 ]
  [[ "$output" == *"--tag needs a value"* ]]
}

@test "every command has its own --help" {
  for command in certs build push secrets deploy test verify all clean; do
    run platform "$command" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage: platform.sh ${command}"* ]]
  done
}

@test "a missing config file is an error" {
  run "$PLATFORM" --config "${SANDBOX}/nope.env" config
  [ "$status" -eq 2 ]
  [[ "$output" == *"Config file not found"* ]]
}

# --- configuration ----------------------------------------------------------------

@test "config prints file values, defaults and derived values" {
  run platform config
  [ "$status" -eq 0 ]
  [[ "$output" == *"IMAGE_TAG=1.2.3"* ]]
  [[ "$output" == *"KEYCLOAK_VERSION=26.8.2"* ]]
  [[ "$output" == *"CERT_MODE=trust"* ]]
  [[ "$output" == *"KC_SERVICE_HOST=iam-keycloak.iam.svc.cluster.local"* ]]
  [[ "$output" == *"KC_INTERNAL_URL=https://iam-keycloak.iam.svc.cluster.local:8443"* ]]
  [[ "$output" == *"KC_PUBLIC_URL=https://iam-keycloak.iam.svc.cluster.local:8443"* ]]
  [[ "$output" == *"APP_INTERNAL_URL=https://iam-spring-app.iam.svc.cluster.local:8443"* ]]
}

@test "the repository's own config file loads and validates" {
  run "$PLATFORM" --config "${REPO_ROOT}/config/platform.env" config
  [ "$status" -eq 0 ]
  [[ "$output" == *"PROJECT_NAME=iam-platform"* ]]
  [[ "$output" != *"unknown key"* ]]
}

@test "environment variables win over the config file" {
  IMAGE_TAG=9.9.9 run platform config
  [ "$status" -eq 0 ]
  [[ "$output" == *"IMAGE_TAG=9.9.9"* ]]
}

@test "values may be quoted, commented and reference other keys" {
  cat >>"$CONFIG" <<'EOF'
CERT_ORG="Acme Corp"   # trailing comment
CERT_OU='Identity'
IMAGE_KEYCLOAK=${PROJECT_NAME}/kc   # reference
KC_REALM=corp # comment
EOF
  run platform config
  [ "$status" -eq 0 ]
  [[ "$output" == *"CERT_ORG=Acme Corp"* ]]
  [[ "$output" == *"CERT_OU=Identity"* ]]
  [[ "$output" == *"IMAGE_KEYCLOAK=iam-platform/kc"* ]]
  [[ "$output" == *"KC_REALM=corp"$'\n'* ]]
}

@test "the config file is parsed, never executed" {
  echo 'CERT_OU=$(touch '"${SANDBOX}"'/pwned)' >>"$CONFIG"
  run platform config
  [ ! -e "${SANDBOX}/pwned" ]
}

@test "unknown keys are reported, not silently accepted" {
  echo 'ACR_NAMES=typo' >>"$CONFIG"
  run platform config
  [ "$status" -eq 0 ]
  [[ "$output" == *"unknown key 'ACR_NAMES' ignored"* ]]
}

@test "a malformed line stops with file and line number" {
  echo 'this is not a setting' >>"$CONFIG"
  run platform config
  [ "$status" -eq 2 ]
  [[ "$output" == *"platform.env:7: expected KEY=VALUE"* ]]
}

@test "public URLs and the ACR login server are derived when not set" {
  set_config ACR_NAME myregistry
  set_config KC_PUBLIC_URL https://sso.example.com/
  run platform config
  [ "$status" -eq 0 ]
  [[ "$output" == *"ACR_LOGIN_SERVER=myregistry.azurecr.io"* ]]
  [[ "$output" == *"KC_PUBLIC_URL=https://sso.example.com"$'\n'* ]]
}

# --- validation -------------------------------------------------------------------

@test "IMAGE_TAG=latest is rejected" {
  set_config IMAGE_TAG latest
  run platform config
  [ "$status" -eq 2 ]
  [[ "$output" == *"immutable tag"* ]]
}

@test "invalid enumerations are rejected with the allowed values" {
  set_config CERT_MODE everything
  run platform config
  [ "$status" -eq 2 ]
  [[ "$output" == *"CERT_MODE='everything' is invalid (allowed: trust baked none)"* ]]
}

@test "the renewal window must be shorter than the certificate lifetime" {
  set_config CERT_LEAF_DAYS 20
  run platform config
  [ "$status" -eq 2 ]
  [[ "$output" == *"CERT_RENEW_BEFORE_DAYS"* ]]
}

@test "plain http public URLs are rejected" {
  set_config KC_PUBLIC_URL http://sso.example.com
  run platform config
  [ "$status" -eq 2 ]
  [[ "$output" == *"KC_PUBLIC_URL"* ]]
}

@test "subject fields that would break a distinguished name are rejected" {
  set_config CERT_ORG "Acme, Inc"
  run platform config
  [ "$status" -eq 2 ]
  [[ "$output" == *"CERT_ORG"* ]]
}

@test "an ACR name with a domain suffix is rejected" {
  set_config ACR_NAME myregistry.azurecr.io
  run platform config
  [ "$status" -eq 2 ]
  [[ "$output" == *"ACR_NAME"* ]]
}

@test "certificates baked into images require CERT_MODE=baked" {
  set_config CERT_SOURCE image
  run platform config
  [ "$status" -eq 2 ]
  [[ "$output" == *"CERT_SOURCE=image requires CERT_MODE=baked"* ]]
}

# --- clean --------------------------------------------------------------------------

@test "clean removes staged contexts but keeps certificates" {
  mkdir -p "${SANDBOX}/build/context/keycloak" "${SANDBOX}/certs/ca"
  touch "${SANDBOX}/build/images.env"
  run platform clean
  [ "$status" -eq 0 ]
  [ ! -e "${SANDBOX}/build/context" ]
  [ ! -e "${SANDBOX}/build/images.env" ]
  [ -d "${SANDBOX}/certs/ca" ]
}

@test "clean --certs also removes the certificates" {
  mkdir -p "${SANDBOX}/certs/ca"
  run platform clean --certs
  [ "$status" -eq 0 ]
  [ ! -e "${SANDBOX}/certs" ]
}

@test "clean refuses dangerous targets" {
  set_config CERT_DIR /
  # --dry-run: the guard fires before anything would run, and the test stays
  # harmless even if the guard were ever broken.
  run platform --dry-run clean --certs
  [ "$status" -eq 2 ]
  [[ "$output" == *"refusing to delete '/'"* ]]
}

@test "dry-run clean deletes nothing" {
  mkdir -p "${SANDBOX}/build/context/keycloak"
  run platform --dry-run clean
  [ "$status" -eq 0 ]
  [[ "$output" == *"[dry-run] rm -rf"* ]]
  [ -d "${SANDBOX}/build/context/keycloak" ]
}
