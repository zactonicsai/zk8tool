#!/usr/bin/env bats
# Loading certificates into the cluster, Helm deploy and helm test
# (lib/k8s.sh) plus the `all` pipeline. kubectl and helm are stubs.

load test_helper

setup() {
  setup_sandbox
  platform certs >/dev/null 2>&1
}
teardown() { teardown_sandbox; }

GENERATED() { printf '%s/build/helm-values.generated.yaml' "$SANDBOX"; }

# --- secrets ----------------------------------------------------------------------

@test "secrets creates the namespace with the restricted Pod Security Standard" {
  run platform secrets
  [ "$status" -eq 0 ]
  [ "$(stub_calls '^kubectl create namespace iam --dry-run=client -o yaml$')" -eq 1 ]
  grep -E -- "^kubectl label namespace iam --overwrite pod-security\.kubernetes\.io/enforce=restricted pod-security\.kubernetes\.io/enforce-version=latest$" "$STUB_LOG"
}

@test "secrets loads every certificate as a kubernetes.io/tls Secret from files" {
  platform secrets
  for name in keycloak spring-app test-client saml-sp; do
    grep -E -- "^kubectl --namespace iam create secret generic iam-${name}-tls --type=kubernetes\.io/tls --from-file=tls\.crt=.*/certs/${name}/tls\.crt --from-file=tls\.key=.*/certs/${name}/tls\.key --from-file=ca\.crt=.*/certs/${name}/ca\.crt --dry-run=client -o yaml$" "$STUB_LOG"
  done
  [ "$(stub_calls '^kubectl apply -f -$')" -eq 5 ]
}

@test "private key material never appears on a command line" {
  platform secrets
  run grep -c -E -- "BEGIN|--from-literal" "$STUB_LOG"
  [ "$output" = "0" ]
}

@test "secrets creates the admin Secret once, from files with a random password" {
  run platform secrets
  [ "$status" -eq 0 ]
  grep -E -- "^kubectl --namespace iam create secret generic iam-keycloak-admin --from-file=username=.* --from-file=password=.*$" "$STUB_LOG"
  [[ "$output" == *"created iam/iam-keycloak-admin"* ]]
}

@test "an existing admin Secret is kept" {
  export STUB_SECRET_GET_RC=0
  run platform secrets
  [ "$status" -eq 0 ]
  [[ "$output" == *"iam/iam-keycloak-admin exists, keeping it"* ]]
  [ "$(stub_calls 'create secret generic iam-keycloak-admin')" -eq 0 ]
}

@test "namespace and release can be overridden" {
  platform secrets --namespace identity --release prod --no-pod-security
  [ "$(stub_calls '^kubectl create namespace identity ')" -eq 1 ]
  [ "$(stub_calls 'create secret generic prod-keycloak-tls ')" -eq 1 ]
  [ "$(stub_calls '^kubectl label namespace')" -eq 0 ]
}

@test "with cert-manager only the SAML signing certificate is loaded" {
  set_config CERT_SOURCE cert-manager
  run platform secrets
  [ "$status" -eq 0 ]
  [ "$(stub_calls 'create secret generic iam-saml-sp-tls ')" -eq 1 ]
  [ "$(stub_calls 'create secret generic iam-keycloak-tls ')" -eq 0 ]
  [ "$(stub_calls 'create secret generic iam-test-client-tls ')" -eq 0 ]
}

@test "secrets refuses certificates that do not verify" {
  cp "${SANDBOX}/certs/spring-app/tls.key" "${SANDBOX}/certs/keycloak/tls.key"
  run platform secrets
  [ "$status" -ne 0 ]
  [[ "$output" == *"do not verify"* ]]
  [ "$(stub_calls '^kubectl ')" -eq 0 ]
}

@test "dry-run secrets touches nothing" {
  run platform --dry-run secrets
  [ "$status" -eq 0 ]
  [[ "$output" == *"[dry-run] kubectl apply secret iam/iam-keycloak-tls"* ]]
  [ ! -s "$STUB_LOG" ]
}

# --- deploy -----------------------------------------------------------------------

@test "deploy runs helm upgrade --install with the generated values first" {
  run platform deploy
  [ "$status" -eq 0 ]
  grep -E -- "^helm upgrade --install iam .*/helm/iam-platform --namespace iam --create-namespace --timeout 10m --values .*/build/helm-values\.generated\.yaml --wait$" "$STUB_LOG"
}

@test "the generated values tie the chart to the configuration" {
  platform deploy
  run cat "$(GENERATED)"
  [[ "$output" == *'clusterDomain: "cluster.local"'* ]]
  [[ "$output" == *'source: "secret"'* ]]
  [[ "$output" == *'organization: "Example Corp"'* ]]
  [[ "$output" == *'issuerDn: "CN=iam-platform Root CA,OU=Platform,O=Example Corp,C=US"'* ]]
  [[ "$output" == *'repository: "iam-platform/keycloak"'* ]]
  [[ "$output" == *'tag: "1.2.3"'* ]]
  [[ "$output" == *'vendor: "dev-file"'* ]]
  [[ "$output" != *"imageRegistry"* ]]
  [[ "$output" != *"publicUrl"* ]]
}

@test "the generated values are valid YAML with the expected structure" {
  if ! python3 -c 'import yaml' 2>/dev/null; then skip "python3 with PyYAML not installed"; fi
  platform deploy
  run python3 -c '
import sys, yaml
v = yaml.safe_load(open(sys.argv[1]))
assert v["keycloak"]["image"] == {"repository": "iam-platform/keycloak", "tag": "1.2.3"}, v["keycloak"]
assert v["testClient"]["image"]["repository"] == "iam-platform/test-client"
assert v["app"]["saml"]["signing"]["enabled"] is True
assert len(v["app"]["saml"]["signing"]["certificate"]) > 500
assert v["certificates"]["subject"] == {"organization": "Example Corp", "organizationalUnit": "Platform", "country": "US"}
print("ok")
' "$(GENERATED)"
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

@test "the SAML signing certificate is passed as single-line base64 DER" {
  platform deploy
  expected="$(openssl x509 -in "${SANDBOX}/certs/saml-sp/tls.crt" -outform DER | openssl base64 -A)"
  grep -F -- "certificate: \"${expected}\"" "$(GENERATED)"
}

@test "registry, pushed digest and public URLs flow into the generated values" {
  set_config ACR_NAME myregistry
  set_config KC_PUBLIC_URL https://sso.example.com
  set_config APP_PUBLIC_URL https://app.example.com
  mkdir -p "${SANDBOX}/build"
  cat >"${SANDBOX}/build/images.pushed.env" <<'EOF'
keycloak=myregistry.azurecr.io/iam-platform/keycloak@sha256:aaaa tag=1.2.3
app=myregistry.azurecr.io/iam-platform/spring-app@sha256:bbbb tag=0.0.1
EOF
  platform deploy
  run cat "$(GENERATED)"
  [[ "$output" == *'imageRegistry: "myregistry.azurecr.io"'* ]]
  [[ "$output" == *'digest: "sha256:aaaa"'* ]]
  # a digest recorded for another tag must not be used
  [[ "$output" != *"sha256:bbbb"* ]]
  [[ "$output" == *'publicUrl: "https://sso.example.com"'* ]]
  [[ "$output" == *'publicUrl: "https://app.example.com"'* ]]
}

@test "cert-manager mode is translated to the chart's value and leaves the issuer DN to the chart" {
  set_config CERT_SOURCE cert-manager
  platform deploy
  run cat "$(GENERATED)"
  [[ "$output" == *'source: "certManager"'* ]]
  [[ "$output" != *"issuerDn"* ]]
}

@test "user values files and --set come after the generated values" {
  echo "keycloak: {replicas: 1}" >"${SANDBOX}/extra.yaml"
  echo "app: {replicas: 1}" >"${SANDBOX}/more.yaml"
  set_config HELM_VALUES "${SANDBOX}/extra.yaml"
  run platform deploy --values "${SANDBOX}/more.yaml" --set app.replicas=3 --set keycloak.logLevel=debug --no-wait
  [ "$status" -eq 0 ]
  grep -E -- "--values .*/helm-values\.generated\.yaml --values .*/extra\.yaml --values .*/more\.yaml --set app\.replicas=3 --set keycloak\.logLevel=debug$" "$STUB_LOG"
  [ "$(stub_calls '--wait')" -eq 0 ]
}

@test "deploy options override namespace, release, tag and registry" {
  platform deploy --namespace identity --release prod --tag 4.5.6 --registry registry.example.com
  grep -E -- "^helm upgrade --install prod .* --namespace identity " "$STUB_LOG"
  run cat "$(GENERATED)"
  [[ "$output" == *'imageRegistry: "registry.example.com"'* ]]
  [[ "$output" == *'tag: "4.5.6"'* ]]
}

@test "a missing values file is reported before helm runs" {
  run platform deploy --values "${SANDBOX}/missing.yaml"
  [ "$status" -eq 2 ]
  [[ "$output" == *"values file not found"* ]]
  [ "$(stub_calls '^helm ')" -eq 0 ]
}

@test "dry-run deploy shows the values and the helm command without writing" {
  run platform --dry-run deploy
  [ "$status" -eq 0 ]
  [[ "$output" == *"[dry-run] helm upgrade --install iam"* ]]
  [[ "$output" == *'[dry-run]   certificates:'* ]]
  [ ! -e "$(GENERATED)" ]
  [ ! -s "$STUB_LOG" ]
}

# --- test / status ------------------------------------------------------------------

@test "test runs helm test with logs" {
  run platform test
  [ "$status" -eq 0 ]
  grep -E -- "^helm test iam --namespace iam --logs --timeout 5m$" "$STUB_LOG"
}

@test "test honours namespace, release and timeout" {
  platform test --namespace identity --release prod --timeout 2m
  grep -E -- "^helm test prod --namespace identity --logs --timeout 2m$" "$STUB_LOG"
}

@test "status lists the release's resources" {
  platform status
  grep -E -- "^kubectl --namespace iam get pods,services,secrets --selector app\.kubernetes\.io/instance=iam --output wide$" "$STUB_LOG"
}

# --- all -----------------------------------------------------------------------------

@test "all runs the pipeline in order and skips push without a registry" {
  run platform all
  [ "$status" -eq 0 ]
  [[ "$output" == *"ACR_NAME is empty, skipping push"* ]]
  [ "$(stub_calls '^docker build ')" -eq 3 ]
  [ "$(stub_calls '^docker push ')" -eq 0 ]
  build_line="$(grep -n -m1 '^docker build' "$STUB_LOG" | cut -d: -f1)"
  secret_line="$(grep -n -m1 'create secret generic iam-keycloak-tls' "$STUB_LOG" | cut -d: -f1)"
  deploy_line="$(grep -n -m1 '^helm upgrade' "$STUB_LOG" | cut -d: -f1)"
  test_line="$(grep -n -m1 '^helm test' "$STUB_LOG" | cut -d: -f1)"
  [ "$build_line" -lt "$secret_line" ]
  [ "$secret_line" -lt "$deploy_line" ]
  [ "$deploy_line" -lt "$test_line" ]
}

@test "all pushes when a registry is configured and passes the tag through" {
  set_config ACR_NAME myregistry
  run platform all --tag 7.0.0
  [ "$status" -eq 0 ]
  [ "$(stub_calls '^docker push myregistry\.azurecr\.io/iam-platform/.*:7\.0\.0$')" -eq 3 ]
  grep -F -- 'tag: "7.0.0"' "$(GENERATED)"
}

@test "all --skip leaves stages out" {
  run platform all --skip build,test
  [ "$status" -eq 0 ]
  [ "$(stub_calls '^docker build')" -eq 0 ]
  [ "$(stub_calls '^helm test')" -eq 0 ]
  [ "$(stub_calls '^helm upgrade')" -eq 1 ]
}

@test "all rejects unknown stages" {
  run platform all --skip build,lunch
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown stage 'lunch'"* ]]
}
