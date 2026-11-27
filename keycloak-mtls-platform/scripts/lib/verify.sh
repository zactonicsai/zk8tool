#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
# scripts/lib/verify.sh - run every local (no cluster needed) check.
#
#   shell   shellcheck on scripts/ and tests/
#   bats    tests/scripts/*.bats (script unit tests with stubbed CLIs)
#   docker  hadolint on the Dockerfiles
#   helm    helm lint, helm unittest, helm template | kubeconform
#   java    ./mvnw verify for the Spring app and the test client
# Docs: docs/scripts/lib-verify.md and docs/10-testing.md
# =============================================================================

if [[ -n "${__PLATFORM_VERIFY_SH:-}" ]]; then return 0; fi
__PLATFORM_VERIFY_SH=1

VERIFY_STEPS=(shell bats docker helm java)
VERIFY_RESULTS=()

verify_usage() {
  cat <<'EOF'
Usage: platform.sh verify [options]

Run the local test suites and linters. A step whose tool is not installed is
reported as SKIP (or FAIL with --strict).

Options:
  --only LIST    Comma separated subset of: shell,bats,docker,helm,java
  --skip LIST    Steps to leave out
  --strict       Treat a missing tool as a failure (use this in CI)
  -h, --help     Show this help
EOF
}

_verify_record() { VERIFY_RESULTS+=("$1|$2|${3:-}"); }

# _verify_tool STEP TOOL STRICT - returns 1 (and records SKIP/FAIL) when missing.
_verify_tool() {
  local step=$1 tool=$2 strict=$3
  if have_cmd "$tool"; then return 0; fi
  if [[ "$strict" == "1" ]]; then
    _verify_record "$step" FAIL "${tool} not installed"
  else
    _verify_record "$step" SKIP "${tool} not installed"
  fi
  return 1
}

verify_shell() {
  local strict=$1
  local files=()
  _verify_tool shell shellcheck "$strict" || return 0
  while IFS= read -r f; do files+=("$f"); done < <(
    find "${PLATFORM_ROOT}/scripts" "${PLATFORM_ROOT}/tests" -type f \( -name '*.sh' -o -name '*.bash' \) | sort
  )
  if shellcheck --external-sources --source-path="${PLATFORM_ROOT}/scripts/lib" "${files[@]}"; then
    _verify_record shell PASS "${#files[@]} files"
  else
    _verify_record shell FAIL "shellcheck findings"
  fi
}

verify_bats() {
  local strict=$1
  _verify_tool bats bats "$strict" || return 0
  if bats "${PLATFORM_ROOT}/tests/scripts"; then
    _verify_record bats PASS
  else
    _verify_record bats FAIL "bats test failures"
  fi
}

verify_docker() {
  local strict=$1 failed=0 file
  _verify_tool docker hadolint "$strict" || return 0
  for file in "${PLATFORM_ROOT}"/docker/*/Dockerfile; do
    hadolint --config "${PLATFORM_ROOT}/.hadolint.yaml" "$file" || failed=1
  done
  if [[ "$failed" == "0" ]]; then _verify_record docker PASS; else _verify_record docker FAIL "hadolint findings"; fi
}

verify_helm() {
  local strict=$1 failed=0 notes="" values
  local chart="${PLATFORM_ROOT}/helm/iam-platform"
  _verify_tool helm helm "$strict" || return 0
  for values in "" "${chart}/values-production.yaml" "${chart}/ci/cert-manager-values.yaml"; do
    if [[ -n "$values" ]]; then
      helm lint "$chart" --strict --values "$values" >/dev/null || failed=1
    else
      helm lint "$chart" --strict >/dev/null || failed=1
    fi
  done
  if helm plugin list 2>/dev/null | grep -q '^unittest'; then
    helm unittest "$chart" || failed=1
  elif [[ "$strict" == "1" ]]; then
    failed=1
    notes="helm-unittest plugin not installed"
  else
    notes="helm-unittest plugin not installed (chart unit tests skipped)"
  fi
  if have_cmd kubeconform; then
    for values in "" "${chart}/values-production.yaml" "${chart}/ci/cert-manager-values.yaml"; do
      if [[ -n "$values" ]]; then
        helm template verify "$chart" --namespace iam --values "$values" |
          kubeconform -strict -ignore-missing-schemas -summary || failed=1
      else
        helm template verify "$chart" --namespace iam |
          kubeconform -strict -ignore-missing-schemas -summary || failed=1
      fi
    done
  else
    notes="${notes:+${notes}; }kubeconform not installed (schema validation skipped)"
  fi
  if [[ "$failed" == "0" ]]; then _verify_record helm PASS "$notes"; else _verify_record helm FAIL "$notes"; fi
}

verify_java() {
  local strict=$1
  _verify_tool java java "$strict" || return 0
  if (cd "${PLATFORM_ROOT}/apps" && ./mvnw --batch-mode --no-transfer-progress verify); then
    _verify_record java PASS
  else
    _verify_record java FAIL "maven verify failed"
  fi
}

verify_main() {
  local only="" skip="" strict=0 step entry status failed=0
  local selected=() skipped=()
  while (($# > 0)); do
    case "$1" in
      --only)
        [[ $# -ge 2 ]] || die "verify: --only needs a value" 2
        only=$2
        shift
        ;;
      --skip)
        [[ $# -ge 2 ]] || die "verify: --skip needs a value" 2
        skip=$2
        shift
        ;;
      --strict) strict=1 ;;
      -h | --help)
        verify_usage
        return 0
        ;;
      *) die "verify: unknown option '$1' (see: platform.sh verify --help)" 2 ;;
    esac
    shift
  done

  if [[ -n "$only" ]]; then
    while IFS= read -r step; do selected+=("$step"); done < <(csv_split "$only")
  else
    selected=("${VERIFY_STEPS[@]}")
  fi
  while IFS= read -r step; do skipped+=("$step"); done < <(csv_split "$skip")
  for step in "${selected[@]}" ${skipped[@]+"${skipped[@]}"}; do
    contains "$step" "${VERIFY_STEPS[@]}" || die "verify: unknown step '${step}' (allowed: ${VERIFY_STEPS[*]})" 2
  done

  VERIFY_RESULTS=()
  for step in "${selected[@]}"; do
    if ((${#skipped[@]} > 0)) && contains "$step" "${skipped[@]}"; then continue; fi
    log_step "verify: ${step}"
    "verify_${step}" "$strict"
  done

  printf '\n%-8s %-6s %s\n' STEP RESULT NOTES
  for entry in ${VERIFY_RESULTS[@]+"${VERIFY_RESULTS[@]}"}; do
    IFS='|' read -r step status notes <<<"$entry"
    printf '%-8s %-6s %s\n' "$step" "$status" "$notes"
    if [[ "$status" == "FAIL" ]]; then failed=1; fi
  done
  return "$failed"
}
