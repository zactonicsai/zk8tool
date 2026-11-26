#!/usr/bin/env bash
# Installs Keycloak, and Istio with SSO sign-in wired to it, on the cluster
# of the CURRENT kubectl context.
#
#   ./install.sh           ask before installing
#   ./install.sh -y        do not ask
#
# With no settings it installs a LOCAL DEVELOPMENT setup meant for a kind
# cluster that maps localhost:8080 to node port 30080 (as the kubegen kind
# examples with extraPortMappings do):
#
#   app (sign-in required)   http://localhost:8080/headers
#   Keycloak                 http://keycloak.localhost:8080
#   Keycloak admin login     admin / admin
#   test user                demo / demo
#
# For a real cluster, copy keycloak.env.example to keycloak.env and set the
# host names, TLS and a strong admin password there.
#
# Settings (in keycloak.env or exported), with their defaults:
#   APP_HOST=localhost               host of the app behind sign-in
#   KEYCLOAK_HOST=keycloak.localhost public host of Keycloak
#   TLS_ENABLED=false                true = HTTPS (needs TLS_SECRET_NAME in istio-ingress)
#   TLS_SECRET_NAME=sso-gateway-tls
#   EXTERNAL_PORT=8080               port in the browser; empty for 80/443
#   GATEWAY_SERVICE_TYPE=NodePort    LoadBalancer on cloud clusters
#   GATEWAY_NODE_PORT_HTTP=30080     only used with NodePort
#   GATEWAY_NODE_PORT_HTTPS=30443
#   KEYCLOAK_ADMIN_USER=admin
#   KEYCLOAK_ADMIN_PASSWORD=admin
#   KEYCLOAK_REALM=sso
#   KEYCLOAK_NAMESPACE=keycloak
#   KEYCLOAK_IMAGE_TAG=              empty = the chart's default
#   DEMO_USER=true                   create the demo / demo test user
#   OIDC_CLIENT_ID=oauth2-proxy
#   OIDC_CLIENT_SECRET=              empty = generated (and reused on re-runs)
#   INSTALL_ISTIO=true               false = only install Keycloak
#   ISTIO_VERSION=                   empty = latest
set -euo pipefail
cd "$(dirname "$0")"

die() { echo "error: $*" >&2; exit 1; }

assume_yes=false
case "${1:-}" in
  -y | --yes) assume_yes=true ;;
  "") ;;
  *) die "unknown option '$1' (usage: ./install.sh [-y])" ;;
esac

# --- required tools ----------------------------------------------------------
missing=0
need() {
  command -v "$1" >/dev/null 2>&1 && return
  echo "error: required tool '$1' is not installed or not in PATH" >&2
  echo "       install it from: $2" >&2
  missing=1
}
need helm    https://helm.sh/docs/intro/install/
need kubectl https://kubernetes.io/docs/tasks/tools/
need openssl https://www.openssl.org/source/
[ "$missing" -eq 0 ] || exit 127

# --- settings ------------------------------------------------------------------
ENV_FILE="${KEYCLOAK_ENV_FILE:-./keycloak.env}"
if [ -f "$ENV_FILE" ]; then
  echo "==> Reading settings from $ENV_FILE"
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
fi

APP_HOST="${APP_HOST:-localhost}"
KEYCLOAK_HOST="${KEYCLOAK_HOST:-keycloak.localhost}"
TLS_ENABLED="${TLS_ENABLED:-false}"
TLS_SECRET_NAME="${TLS_SECRET_NAME:-sso-gateway-tls}"
EXTERNAL_PORT="${EXTERNAL_PORT-8080}" # "-" not ":-": an empty value means "no port"
GATEWAY_SERVICE_TYPE="${GATEWAY_SERVICE_TYPE:-NodePort}"
GATEWAY_NODE_PORT_HTTP="${GATEWAY_NODE_PORT_HTTP-30080}"
GATEWAY_NODE_PORT_HTTPS="${GATEWAY_NODE_PORT_HTTPS-30443}"
KEYCLOAK_ADMIN_USER="${KEYCLOAK_ADMIN_USER:-admin}"
KEYCLOAK_ADMIN_PASSWORD="${KEYCLOAK_ADMIN_PASSWORD:-admin}"
KEYCLOAK_REALM="${KEYCLOAK_REALM:-sso}"
KEYCLOAK_NAMESPACE="${KEYCLOAK_NAMESPACE:-keycloak}"
KEYCLOAK_IMAGE_TAG="${KEYCLOAK_IMAGE_TAG:-}"
DEMO_USER="${DEMO_USER:-true}"
OIDC_CLIENT_ID="${OIDC_CLIENT_ID:-oauth2-proxy}"
OIDC_CLIENT_SECRET="${OIDC_CLIENT_SECRET:-}"
INSTALL_ISTIO="${INSTALL_ISTIO:-true}"
ISTIO_VERSION="${ISTIO_VERSION:-}"

if [ "$GATEWAY_SERVICE_TYPE" != "NodePort" ]; then
  GATEWAY_NODE_PORT_HTTP=""
  GATEWAY_NODE_PORT_HTTPS=""
fi

scheme=https
[ "$TLS_ENABLED" = "true" ] || scheme=http
port_suffix="${EXTERNAL_PORT:+:$EXTERNAL_PORT}"
app_url="$scheme://$APP_HOST$port_suffix"
keycloak_url="$scheme://$KEYCLOAK_HOST$port_suffix"

# --- target cluster -----------------------------------------------------------
context="$(kubectl config current-context 2>/dev/null)" || die "kubectl has no current context; check your kubeconfig"
kubectl cluster-info >/dev/null 2>&1 || die "kubectl cannot reach the cluster of context '$context'"

echo
echo "About to install on kubectl context:  $context"
echo "  App behind sign-in:   $app_url"
echo "  Keycloak:             $keycloak_url   (realm: $KEYCLOAK_REALM)"
echo "  Keycloak admin user:  $KEYCLOAK_ADMIN_USER"
echo "  Gateway service:      $GATEWAY_SERVICE_TYPE${GATEWAY_NODE_PORT_HTTP:+ (node port $GATEWAY_NODE_PORT_HTTP)}"
echo "  Install Istio:        $INSTALL_ISTIO"
if [ "$KEYCLOAK_ADMIN_PASSWORD" = "admin" ]; then
  echo
  echo "WARNING: the Keycloak admin password is 'admin'. That is only acceptable on a"
  echo "         private test cluster. Set KEYCLOAK_ADMIN_PASSWORD for anything else."
fi
if [ "$TLS_ENABLED" != "true" ]; then
  echo "WARNING: plain HTTP. Passwords and session cookies travel unencrypted;"
  echo "         use this for local testing only."
fi
echo
if [ "$assume_yes" != "true" ]; then
  [ -t 0 ] || die "not running in a terminal; pass -y to install without asking"
  read -r -p "Continue? [y/N] " answer
  case "$answer" in y | Y | yes | YES) ;; *) echo "Cancelled."; exit 0 ;; esac
fi

# --- client secret shared by Keycloak and oauth2-proxy ------------------------
# Reuse the one already in the cluster: Keycloak imports the realm only once,
# so the secret must stay the same on later runs.
if [ -z "$OIDC_CLIENT_SECRET" ]; then
  OIDC_CLIENT_SECRET="$(kubectl get secret oauth2-proxy-credentials -n oauth2-proxy \
    -o jsonpath='{.data.client-secret}' 2>/dev/null | base64 -d 2>/dev/null || true)"
fi
[ -n "$OIDC_CLIENT_SECRET" ] || OIDC_CLIENT_SECRET="$(openssl rand -hex 24)"

# --- 1. Istio with sign-in, pointed at this Keycloak --------------------------
if [ "$INSTALL_ISTIO" = "true" ]; then
  echo "==> Step 1 of 2: Istio with SSO sign-in"
  SSO_ENV_FILE=/dev/null \
  SSO_HOST="$APP_HOST" \
  KEYCLOAK_HOST="$KEYCLOAK_HOST" \
  KEYCLOAK_REALM="$KEYCLOAK_REALM" \
  KEYCLOAK_INTERNAL_URL="http://keycloak.$KEYCLOAK_NAMESPACE.svc.cluster.local:8080" \
  OIDC_ISSUER_URL="" \
  OIDC_CLIENT_ID="$OIDC_CLIENT_ID" \
  OIDC_CLIENT_SECRET="$OIDC_CLIENT_SECRET" \
  TLS_ENABLED="$TLS_ENABLED" \
  TLS_SECRET_NAME="$TLS_SECRET_NAME" \
  EXTERNAL_PORT="$EXTERNAL_PORT" \
  GATEWAY_SERVICE_TYPE="$GATEWAY_SERVICE_TYPE" \
  GATEWAY_NODE_PORT_HTTP="$GATEWAY_NODE_PORT_HTTP" \
  GATEWAY_NODE_PORT_HTTPS="$GATEWAY_NODE_PORT_HTTPS" \
  ISTIO_VERSION="$ISTIO_VERSION" \
    ../istio/helm/install.sh
fi

# Route Keycloak through the Istio gateway only when Istio is there.
istio_enabled=false
kubectl get crd virtualservices.networking.istio.io >/dev/null 2>&1 && istio_enabled=true
[ "$istio_enabled" = "true" ] || echo "note: Istio is not installed; Keycloak will only be reachable inside the cluster."

# --- 2. Keycloak ----------------------------------------------------------------
echo "==> Step 2 of 2: Keycloak (first start takes a few minutes)"
values="$(mktemp)"
trap 'rm -f "$values"' EXIT
cat > "$values" <<VALUES
hostname: "$KEYCLOAK_HOST"
externalUrl: "$keycloak_url"
admin:
  username: "$KEYCLOAK_ADMIN_USER"
  password: "$KEYCLOAK_ADMIN_PASSWORD"
realm:
  name: "$KEYCLOAK_REALM"
  client:
    id: "$OIDC_CLIENT_ID"
    secret: "$OIDC_CLIENT_SECRET"
    redirectUris:
      - "$app_url/oauth2/callback"
  demoUser:
    enabled: $DEMO_USER
istio:
  enabled: $istio_enabled
VALUES
[ -z "$KEYCLOAK_IMAGE_TAG" ] || printf 'image:\n  tag: "%s"\n' "$KEYCLOAK_IMAGE_TAG" >> "$values"

helm upgrade --install keycloak ./chart -n "$KEYCLOAK_NAMESPACE" --create-namespace \
  -f "$values" --wait --timeout 15m

echo
echo "Done. Installed on context: $context"
echo
echo "  Try sign-in:          $app_url/headers"
[ "$DEMO_USER" != "true" ] || echo "                        sign in as  demo / demo"
echo "  Sign out:             $app_url/oauth2/sign_out"
echo "  Keycloak admin:       $keycloak_url/admin"
echo "                        sign in as  $KEYCLOAK_ADMIN_USER / (the admin password you set)"
echo
if [ "$GATEWAY_SERVICE_TYPE" = "LoadBalancer" ]; then
  echo "Point DNS for $APP_HOST and $KEYCLOAK_HOST at the address shown by:"
  echo "  kubectl get service istio-ingress -n istio-ingress"
fi
echo "Keycloak treats the first admin as temporary: create your own admin user in"
echo "the console (realm 'master'), then delete '$KEYCLOAK_ADMIN_USER'."
