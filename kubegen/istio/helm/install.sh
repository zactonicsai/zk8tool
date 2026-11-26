#!/usr/bin/env bash
# Installs Istio with SSO sign-in using the Helm CLI. This does the same as
# the Terraform in ../terraform; use one or the other, not both.
#
# Required settings (environment variables):
#   SSO_HOST            host name of your app, e.g. app.example.com
#   OIDC_ISSUER_URL     issuer URL of your identity provider
#   OIDC_CLIENT_ID      client (application) ID registered there
#   OIDC_CLIENT_SECRET  its client secret
#
# Optional:
#   TLS_ENABLED=true            false = plain HTTP, local testing only
#   TLS_SECRET_NAME=sso-gateway-tls   existing kubernetes.io/tls secret in istio-ingress
#   EXTERNAL_PORT=              port people type in the browser, if not 80/443
#   EMAIL_DOMAINS='*'           comma-separated e-mail domains allowed to sign in
#   GATEWAY_SERVICE_TYPE=LoadBalancer
#   ISTIO_VERSION=              chart version, e.g. 1.31.0 (empty = latest)
#   DEMO_APP=true               install the httpbin test app
#
# Example:
#   export SSO_HOST=app.example.com
#   export OIDC_ISSUER_URL=https://login.microsoftonline.com/<tenant-id>/v2.0
#   export OIDC_CLIENT_ID=... OIDC_CLIENT_SECRET=...
#   ./install.sh
set -euo pipefail
cd "$(dirname "$0")"

die() { echo "error: $*" >&2; exit 1; }

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
: "${SSO_HOST:?set SSO_HOST, e.g. app.example.com}"
: "${OIDC_ISSUER_URL:?set OIDC_ISSUER_URL to your identity provider issuer URL}"
: "${OIDC_CLIENT_ID:?set OIDC_CLIENT_ID}"
: "${OIDC_CLIENT_SECRET:?set OIDC_CLIENT_SECRET}"
TLS_ENABLED="${TLS_ENABLED:-true}"
TLS_SECRET_NAME="${TLS_SECRET_NAME:-sso-gateway-tls}"
EXTERNAL_PORT="${EXTERNAL_PORT:-}"
EMAIL_DOMAINS="${EMAIL_DOMAINS:-*}"
GATEWAY_SERVICE_TYPE="${GATEWAY_SERVICE_TYPE:-LoadBalancer}"
ISTIO_VERSION="${ISTIO_VERSION:-}"
DEMO_APP="${DEMO_APP:-true}"

scheme=https
[ "$TLS_ENABLED" = "true" ] || scheme=http
external_url="$scheme://$SSO_HOST${EXTERNAL_PORT:+:$EXTERNAL_PORT}"
redirect_url="$external_url/oauth2/callback"

version_flag=()
[ -z "$ISTIO_VERSION" ] || version_flag=(--version "$ISTIO_VERSION")

kubectl cluster-info >/dev/null 2>&1 || die "kubectl cannot reach a cluster; check your kubeconfig"
if [ "$TLS_ENABLED" = "true" ]; then
  echo "note: HTTPS needs the TLS secret '$TLS_SECRET_NAME' in namespace istio-ingress."
  echo "      create it with: kubectl create secret tls $TLS_SECRET_NAME -n istio-ingress --cert=<cert.pem> --key=<key.pem>"
fi

# --- namespaces ---------------------------------------------------------------
echo "==> Creating namespaces"
for ns in istio-system istio-ingress oauth2-proxy; do
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -
done

# --- Istio ---------------------------------------------------------------------
echo "==> Adding Helm repositories"
helm repo add istio https://istio-release.storage.googleapis.com/charts >/dev/null
helm repo add oauth2-proxy https://oauth2-proxy.github.io/manifests >/dev/null
helm repo update >/dev/null

echo "==> Installing Istio base (CRDs)"
helm upgrade --install istio-base istio/base -n istio-system \
  -f values/istio-base.yaml ${version_flag[@]+"${version_flag[@]}"} --wait

echo "==> Installing istiod (control plane)"
helm upgrade --install istiod istio/istiod -n istio-system \
  -f values/istiod.yaml ${version_flag[@]+"${version_flag[@]}"} --wait

echo "==> Installing the ingress gateway"
# No --wait when the service is a LoadBalancer on a cluster that cannot
# provide one (it would wait forever); the rollout is checked instead.
helm upgrade --install istio-ingress istio/gateway -n istio-ingress \
  -f values/gateway.yaml ${version_flag[@]+"${version_flag[@]}"} \
  --set service.type="$GATEWAY_SERVICE_TYPE"
kubectl rollout status deployment/istio-ingress -n istio-ingress --timeout=5m

# --- oauth2-proxy -------------------------------------------------------------
echo "==> Storing sign-in credentials in a Kubernetes secret"
# Keep the existing cookie secret so current sessions survive a re-run.
cookie_secret="$(kubectl get secret oauth2-proxy-credentials -n oauth2-proxy \
  -o jsonpath='{.data.cookie-secret}' 2>/dev/null | base64 -d 2>/dev/null || true)"
[ -n "$cookie_secret" ] || cookie_secret="$(openssl rand -base64 32 | tr -- '+/' '-_')"
kubectl create secret generic oauth2-proxy-credentials -n oauth2-proxy \
  --from-literal=client-id="$OIDC_CLIENT_ID" \
  --from-literal=client-secret="$OIDC_CLIENT_SECRET" \
  --from-literal=cookie-secret="$cookie_secret" \
  --dry-run=client -o yaml | kubectl apply -f -

# email_domains = [ "a.com", "b.com" ]
domains="$(printf '%s' "$EMAIL_DOMAINS" | sed 's/ *, */", "/g')"
config_file="$(mktemp)"
trap 'rm -f "$config_file"' EXIT
cat > "$config_file" <<CONFIG
config:
  configFile: |-
    email_domains = [ "$domains" ]
    upstreams = [ "static://200" ]
CONFIG

echo "==> Installing oauth2-proxy"
helm upgrade --install oauth2-proxy oauth2-proxy/oauth2-proxy -n oauth2-proxy \
  -f values/oauth2-proxy.yaml -f "$config_file" \
  --set-string extraArgs.oidc-issuer-url="$OIDC_ISSUER_URL" \
  --set-string extraArgs.redirect-url="$redirect_url" \
  --set-string extraArgs.cookie-secure="$TLS_ENABLED" \
  --wait

# --- sign-in policy -----------------------------------------------------------
echo "==> Installing the gateway and sign-in policy"
helm upgrade --install sso-config ./sso-config -n istio-ingress \
  --set "hosts={$SSO_HOST}" \
  --set gateway.tls.enabled="$TLS_ENABLED" \
  --set gateway.tls.credentialName="$TLS_SECRET_NAME" \
  --set demoApp.enabled="$DEMO_APP" \
  --wait

echo
echo "Done."
echo "1. Register this redirect URI in your identity provider:"
echo "     $redirect_url"
echo "2. Point DNS for $SSO_HOST at the gateway address shown by:"
echo "     kubectl get service istio-ingress -n istio-ingress"
echo "3. Open $external_url/headers - you should be sent to sign in first."
