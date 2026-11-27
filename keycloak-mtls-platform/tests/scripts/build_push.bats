#!/usr/bin/env bats
# Image builds with certificate loading (lib/images.sh) and Azure Container
# Registry publishing (lib/acr.sh). docker and az are stubs that log their
# arguments; see test_helper.bash.

load test_helper

setup() {
  setup_sandbox
  platform certs >/dev/null 2>&1
}
teardown() { teardown_sandbox; }

CTX() { printf '%s/build/context/%s' "$SANDBOX" "$1"; }

# --- build contexts and certificate loading ---------------------------------------

@test "trust mode stages only the CA certificate, never a private key" {
  run platform build --stage-only
  [ "$status" -eq 0 ]
  for component in keycloak app client; do
    [ -f "$(CTX "$component")/Dockerfile" ]
    [ -f "$(CTX "$component")/certs/trust/ca.crt" ]
    [ ! -e "$(CTX "$component")/certs/tls/tls.key" ]
    [ ! -e "$(CTX "$component")/certs/tls/tls.crt" ]
  done
  run grep -rl "PRIVATE KEY" "$(CTX keycloak)/certs" "$(CTX app)/certs" "$(CTX client)/certs"
  [ "$status" -ne 0 ]
}

@test "the Keycloak context carries the realm import file" {
  platform build --stage-only --only keycloak
  [ -f "$(CTX keycloak)/realm/platform-realm.json" ]
  [ ! -e "$(CTX app)" ]
}

@test "the Java contexts carry the Maven reactor without build output" {
  mkdir -p "${REPO_ROOT}/apps/test-client/target"
  touch "${REPO_ROOT}/apps/test-client/target/stale.jar"
  platform build --stage-only --only app,client
  rm -rf "${REPO_ROOT}/apps/test-client/target"
  for component in app client; do
    [ -x "$(CTX "$component")/apps/mvnw" ]
    [ -f "$(CTX "$component")/apps/pom.xml" ]
    [ -f "$(CTX "$component")/apps/spring-app/pom.xml" ]
    [ -f "$(CTX "$component")/apps/test-client/pom.xml" ]
    [ ! -e "$(CTX "$component")/apps/test-client/target" ]
    # Tests (and their fixture keys) are not needed to build an image.
    [ -d "$(CTX "$component")/apps/test-client/src/main" ]
    [ ! -e "$(CTX "$component")/apps/test-client/src/test" ]
    [ ! -e "$(CTX "$component")/apps/spring-app/src/test" ]
  done
}

@test "baked mode loads certificate and key into each context and warns" {
  run platform build --stage-only --cert-mode baked
  [ "$status" -eq 0 ]
  [[ "$output" == *"baking the PRIVATE KEY of 'keycloak'"* ]]
  cmp "$(CTX keycloak)/certs/tls/tls.key" "${SANDBOX}/certs/keycloak/tls.key"
  cmp "$(CTX app)/certs/tls/tls.key" "${SANDBOX}/certs/spring-app/tls.key"
  cmp "$(CTX client)/certs/tls/tls.crt" "${SANDBOX}/certs/test-client/tls.crt"
  [ -f "$(CTX app)/certs/saml/tls.key" ]
  [ ! -e "$(CTX client)/certs/saml/tls.key" ]
  [ "$(file_mode "$(CTX keycloak)/certs/tls/tls.key")" = "600" ]
}

@test "none mode stages no certificate material at all" {
  run platform build --stage-only --cert-mode none
  [ "$status" -eq 0 ]
  [ ! -e "$(CTX keycloak)/certs/trust/ca.crt" ]
  [ -d "$(CTX keycloak)/certs/trust" ]
}

@test "build fails with a hint when certificates are missing" {
  rm -rf "${SANDBOX}/certs"
  run platform build --stage-only
  [ "$status" -ne 0 ]
  [[ "$output" == *"Run: platform.sh certs"* ]]
}

# --- docker build ---------------------------------------------------------------

@test "build runs docker build once per image with tag, build args and labels" {
  run platform build
  [ "$status" -eq 0 ]
  [ "$(stub_calls '^docker build ')" -eq 3 ]
  grep -E -- "^docker build .*--tag iam-platform/keycloak:1\.2\.3 .*--build-arg KEYCLOAK_VERSION=26\.8\.2 .*--build-arg KC_DB=dev-file .*--build-arg KC_HTTPS_CLIENT_AUTH=request" "$STUB_LOG"
  grep -E -- "^docker build .*--tag iam-platform/spring-app:1\.2\.3 .*--build-arg JAVA_BUILD_IMAGE=eclipse-temurin:25-jdk .*--build-arg JAVA_RUNTIME_IMAGE=eclipse-temurin:25-jre" "$STUB_LOG"
  grep -E -- "^docker build .*--tag iam-platform/test-client:1\.2\.3 " "$STUB_LOG"
  [ "$(stub_calls '^docker build .*--pull .*--label io\.platform\.cert-mode=trust .*/build/context/')" -eq 3 ]
  [ "$(stub_calls 'org\.opencontainers\.image\.version=1\.2\.3')" -eq 3 ]
}

@test "build records what it built" {
  platform build
  run cat "${SANDBOX}/build/images.env"
  [[ "$output" == *"keycloak=iam-platform/keycloak:1.2.3"* ]]
  [[ "$output" == *"app=iam-platform/spring-app:1.2.3"* ]]
  [[ "$output" == *"client=iam-platform/test-client:1.2.3"* ]]
}

@test "--tag, --only, --no-cache and --no-pull are honoured" {
  run platform build --only client --tag 2.0.0 --no-cache --no-pull
  [ "$status" -eq 0 ]
  [ "$(stub_calls '^docker build ')" -eq 1 ]
  grep -E -- "^docker build .*--tag iam-platform/test-client:2\.0\.0 .*--no-cache" "$STUB_LOG"
  [ "$(stub_calls '--pull')" -eq 0 ]
}

@test "the database vendor and base images come from the configuration" {
  set_config KC_DB_VENDOR postgres
  set_config KEYCLOAK_VERSION 26.8.1
  set_config JAVA_RUNTIME_IMAGE mcr.microsoft.com/openjdk/jdk:25-ubuntu
  platform build
  grep -E -- "--build-arg KEYCLOAK_VERSION=26\.8\.1 .*--build-arg KC_DB=postgres" "$STUB_LOG"
  grep -E -- "--build-arg JAVA_RUNTIME_IMAGE=mcr\.microsoft\.com/openjdk/jdk:25-ubuntu" "$STUB_LOG"
}

@test "another container CLI can be selected" {
  cp "${SANDBOX}/bin/docker" "${SANDBOX}/bin/podman"
  set_config CONTAINER_CLI podman
  platform build --only keycloak
  [ "$(stub_calls '^podman build ')" -eq 1 ]
  [ "$(stub_calls '^docker ')" -eq 0 ]
}

@test "build rejects unknown components and cert modes" {
  run platform build --only keycloak,db
  [ "$status" -eq 2 ]
  [[ "$output" == *"Unknown component 'db'"* ]]
  run platform build --cert-mode sometimes
  [ "$status" -eq 2 ]
  [[ "$output" == *"CERT_MODE='sometimes' is invalid"* ]]
}

@test "dry-run build prints the commands and stages nothing" {
  run platform --dry-run build
  [ "$status" -eq 0 ]
  [[ "$output" == *"[dry-run] docker build"* ]]
  [ "$(stub_calls '^docker ')" -eq 0 ]
  [ ! -e "${SANDBOX}/build/context" ]
}

# --- push to Azure Container Registry ---------------------------------------------

@test "push needs a registry name" {
  run platform push
  [ "$status" -eq 2 ]
  [[ "$output" == *"ACR_NAME is not set"* ]]
}

@test "push logs in with az, then tags and pushes every image" {
  set_config ACR_NAME myregistry
  run platform push
  [ "$status" -eq 0 ]
  [ "$(stub_calls '^az acr login --name myregistry$')" -eq 1 ]
  for repo in keycloak spring-app test-client; do
    grep -E -- "^docker tag iam-platform/${repo}:1\.2\.3 myregistry\.azurecr\.io/iam-platform/${repo}:1\.2\.3$" "$STUB_LOG"
    grep -E -- "^docker push myregistry\.azurecr\.io/iam-platform/${repo}:1\.2\.3$" "$STUB_LOG"
  done
  # login happens before the first push
  [ "$(grep -n -m1 '^az acr login' "$STUB_LOG" | cut -d: -f1)" -lt "$(grep -n -m1 '^docker push' "$STUB_LOG" | cut -d: -f1)" ]
}

@test "push selects the subscription when one is configured" {
  set_config ACR_NAME myregistry
  set_config AZ_SUBSCRIPTION 00000000-0000-0000-0000-000000000000
  platform push --only keycloak
  [ "$(stub_calls '^az account set --subscription 00000000-0000-0000-0000-000000000000$')" -eq 1 ]
}

@test "--acr, --tag and --no-login override the configuration" {
  run platform push --acr otherregistry --tag 3.0.0 --only app --no-login
  [ "$status" -eq 0 ]
  [ "$(stub_calls '^az acr login')" -eq 0 ]
  grep -E -- "^docker push otherregistry\.azurecr\.io/iam-platform/spring-app:3\.0\.0$" "$STUB_LOG"
}

@test "a sovereign-cloud login server can be configured" {
  set_config ACR_NAME myregistry
  set_config ACR_LOGIN_SERVER myregistry.azurecr.us
  platform push --only client
  grep -E -- "^docker push myregistry\.azurecr\.us/iam-platform/test-client:1\.2\.3$" "$STUB_LOG"
}

@test "push records the pushed digest for deploy" {
  set_config ACR_NAME myregistry
  export STUB_REPO_DIGEST="myregistry.azurecr.io/iam-platform/keycloak@sha256:0123456789abcdef"
  platform push --only keycloak
  run cat "${SANDBOX}/build/images.pushed.env"
  [ "$output" = "keycloak=myregistry.azurecr.io/iam-platform/keycloak@sha256:0123456789abcdef tag=1.2.3" ]
}

@test "push refuses images that contain private keys" {
  set_config ACR_NAME myregistry
  export STUB_CERT_MODE=baked
  run platform push
  [ "$status" -eq 3 ]
  [[ "$output" == *"contains private keys"* ]]
  [ "$(stub_calls '^docker push')" -eq 0 ]
}

@test "--allow-baked-certs overrides the refusal" {
  set_config ACR_NAME myregistry
  export STUB_CERT_MODE=baked
  run platform push --allow-baked-certs --only keycloak
  [ "$status" -eq 0 ]
  [ "$(stub_calls '^docker push')" -eq 1 ]
}

@test "push fails with a hint when the image was not built" {
  set_config ACR_NAME myregistry
  export STUB_IMAGE_INSPECT_RC=1
  run platform push --only keycloak
  [ "$status" -ne 0 ]
  [[ "$output" == *"Run: platform.sh build --tag 1.2.3"* ]]
}

@test "--lock makes the pushed tag immutable" {
  set_config ACR_NAME myregistry
  platform push --only keycloak --lock
  grep -E -- "^az acr repository update --name myregistry --image iam-platform/keycloak:1\.2\.3 --write-enabled false --delete-enabled false$" "$STUB_LOG"
}

@test "--acr-build builds in Azure from the staged context without docker" {
  set_config ACR_NAME myregistry
  run platform push --acr-build --only keycloak
  [ "$status" -eq 0 ]
  grep -E -- "^az acr build --registry myregistry --image iam-platform/keycloak:1\.2\.3 --platform linux/amd64 --file .*/build/context/keycloak/Dockerfile --build-arg KEYCLOAK_BASE_IMAGE=quay\.io/keycloak/keycloak .* .*/build/context/keycloak$" "$STUB_LOG"
  [ "$(stub_calls '^docker ')" -eq 0 ]
  [ -f "$(CTX keycloak)/certs/trust/ca.crt" ]
}

@test "--acr-build refuses to upload private keys to Azure" {
  set_config ACR_NAME myregistry
  set_config CERT_MODE baked
  run platform push --acr-build
  [ "$status" -eq 3 ]
  [[ "$output" == *"would upload private keys"* ]]
  [ "$(stub_calls '^az acr build')" -eq 0 ]
}

@test "podman logs in with a short-lived token instead of docker credentials" {
  cp "${SANDBOX}/bin/docker" "${SANDBOX}/bin/podman"
  set_config ACR_NAME myregistry
  set_config CONTAINER_CLI podman
  platform push --only keycloak
  [ "$(stub_calls '^az acr login --name myregistry --expose-token')" -eq 1 ]
  [ "$(stub_calls '^podman login myregistry\.azurecr\.io --username 00000000-0000-0000-0000-000000000000 --password-stdin$')" -eq 1 ]
}

@test "dry-run push prints the plan and calls nothing" {
  set_config ACR_NAME myregistry
  run platform --dry-run push
  [ "$status" -eq 0 ]
  [[ "$output" == *"[dry-run] az acr login --name myregistry"* ]]
  [[ "$output" == *"[dry-run] docker push myregistry.azurecr.io/iam-platform/keycloak:1.2.3"* ]]
  [ ! -s "$STUB_LOG" ]
}

# --- AKS helpers ----------------------------------------------------------------

@test "aks-credentials and aks-attach call az with the configured cluster" {
  set_config ACR_NAME myregistry
  set_config AKS_RESOURCE_GROUP rg-platform
  set_config AKS_CLUSTER aks-platform
  run platform aks-credentials
  [ "$status" -eq 0 ]
  grep -E -- "^az aks get-credentials --resource-group rg-platform --name aks-platform --overwrite-existing$" "$STUB_LOG"
  run platform aks-attach
  [ "$status" -eq 0 ]
  grep -E -- "^az aks update --resource-group rg-platform --name aks-platform --attach-acr myregistry$" "$STUB_LOG"
}

@test "the AKS helpers need the cluster settings" {
  run platform aks-credentials
  [ "$status" -eq 2 ]
  [[ "$output" == *"AKS_RESOURCE_GROUP and AKS_CLUSTER must be set"* ]]
}
