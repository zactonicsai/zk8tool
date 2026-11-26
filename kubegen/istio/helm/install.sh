#!/usr/bin/env bash
# Installs Istio with SSO sign-in on the cluster of the CURRENT kubectl
# context, using the Helm CLI. This does the same as the Terraform in
# ../terraform; use one or the other, not both.
#
# Easiest: put the settings in a file and run the script.
#   cp sso.env.example sso.env      # then edit sso.env
#   ./install.sh
#
# Required settings (in sso.env or exported):
#   SSO_HOST            host name of your app, e.g. app.example.com
#   OIDC_CLIENT_ID      client ID registered with the identity provider
#   OIDC_CLIENT_SECRET  its client secret
# and ONE of:
#   OIDC_ISSUER_URL     issuer URL of an identity provider outside the cluster
#   KEYCLOAK_HOST       public host name of a Keycloak running IN this cluster
#                       (see ../../keycloak; that directory's install.sh sets
#                       all of this up for you)
#
# Optional:
#   TLS_ENABLED=true            false = plain HTTP, local testing only
#   TLS_SECRET_NAME=sso-gateway-tls   existing kubernetes.io/tls secret in istio-ingress
#   EXTERNAL_PORT=              port people type in the browser, if not 80/443
#   EMAIL_DOMAINS='*'           comma-separated e-mail domains allowed to sign in
#   PUBLIC_HOSTS=               comma-separated extra hosts served without sign-in
#   GATEWAY_SERVICE_TYPE=LoadBalancer
#   GATEWAY_NODE_PORT_HTTP=     fixed node ports when the type is NodePort
#   GATEWAY_NODE_PORT_HTTPS=
#   ISTIO_VERSION=              chart version, e.g. 1.31.0 (empty = latest)
#   DEMO_APP=true               install the httpbin test app
#   KEYCLOAK_REALM=sso          with KEYCLOAK_HOST
#   KEYCLOAK_INTERNAL_URL=http://keycloak.keycloak.svc.cluster.local:8080
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
# Settings can be exported in the shell or kept in a file next to this
# script: copy sso.env.example to sso.env and fill it in.
ENV_FILE="${SSO_ENV_FILE:-./sso.env}"
if [ -f "$ENV_FILE" ]; then
  echo "==> Reading settings from $ENV_FILE"
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
fi

KEYCLOAK_HOST="${KEYCLOAK_HOST:-}"
OIDC_ISSUER_URL="${OIDC_ISSUER_URL:-}"

# Report every missing setting at once, with how to provide them.
missing_settings=""
for name in SSO_HOST OIDC_CLIENT_ID OIDC_CLIENT_SECRET; do
  [ -n "${!name:-}" ] || missing_settings="$missing_settings $name"
done
[ -n "$OIDC_ISSUER_URL$KEYCLOAK_HOST" ] || missing_settings="$missing_settings OIDC_ISSUER_URL(or KEYCLOAK_HOST)"
if [ -n "$missing_settings" ]; then
  {
    echo "error: these required settings are not set:$missing_settings"
    echo
    echo "  SSO_HOST            host name people will open, e.g. app.example.com"
    echo "  OIDC_CLIENT_ID      client ID of the application registered with the identity provider"
    echo "  OIDC_CLIENT_SECRET  its client secret"
    echo "  OIDC_ISSUER_URL     issuer URL of your identity provider"
    echo "                      (or KEYCLOAK_HOST for a Keycloak running in this cluster)"
    echo
    echo "Provide them in a file (recommended):"
    echo "  cp sso.env.example sso.env    # then edit sso.env"
    echo "  ./install.sh"
    echo
    echo "or export them in the shell before running ./install.sh."
    echo
    echo "No identity provider yet? ../../keycloak/install.sh installs Keycloak"
    echo "and this Istio setup together, with nothing to fill in."
    echo
    echo "Where to find these values: ../README.md, Step 1."
  } >&2
  exit 2
fi

TLS_ENABLED="${TLS_ENABLED:-true}"
TLS_SECRET_NAME="${TLS_SECRET_NAME:-sso-gateway-tls}"
EXTERNAL_PORT="${EXTERNAL_PORT:-}"
EMAIL_DOMAINS="${EMAIL_DOMAINS:-*}"
PUBLIC_HOSTS="${PUBLIC_HOSTS:-}"
GATEWAY_SERVICE_TYPE="${GATEWAY_SERVICE_TYPE:-LoadBalancer}"
GATEWAY_NODE_PORT_HTTP="${GATEWAY_NODE_PORT_HTTP:-}"
GATEWAY_NODE_PORT_HTTPS="${GATEWAY_NODE_PORT_HTTPS:-}"
ISTIO_VERSION="${ISTIO_VERSION:-}"
DEMO_APP="${DEMO_APP:-true}"
KEYCLOAK_REALM="${KEYCLOAK_REALM:-sso}"
KEYCLOAK_INTERNAL_URL="${KEYCLOAK_INTERNAL_URL:-http://keycloak.keycloak.svc.cluster.local:8080}"

scheme=https
[ "$TLS_ENABLED" = "true" ] || scheme=http
port_suffix="${EXTERNAL_PORT:+:$EXTERNAL_PORT}"
external_url="$scheme://$SSO_HOST$port_suffix"
redirect_url="$external_url/oauth2/callback"

version_flag=()
[ -z "$ISTIO_VERSION" ] || version_flag=(--version "$ISTIO_VERSION")

context="$(kubectl config current-context 2>/dev/null)" || die "kubectl has no current context; check your kubeconfig"
kubectl cluster-info >/dev/null 2>&1 || die "kubectl cannot reach the cluster of context '$context'"
echo "==> Installing into the cluster of kubectl context: $context"
if [ "$TLS_ENABLED" = "true" ]; then
  echo "note: HTTPS needs the TLS secret '$TLS_SECRET_NAME' in namespace istio-ingress."
  echo "      create it with: kubectl create secret tls $TLS_SECRET_NAME -n istio-ingress --cert=<cert.pem> --key=<key.pem>"
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

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
# Fixed node ports, for local clusters that map host ports to them.
: > "$work/gateway.yaml"
if [ -n "$GATEWAY_NODE_PORT_HTTP" ]; then
  cat > "$work/gateway.yaml" <<GATEWAY
service:
  ports:
    - {name: status-port, port: 15021, targetPort: 15021, protocol: TCP}
    - {name: http2, port: 80, targetPort: 80, protocol: TCP, nodePort: $GATEWAY_NODE_PORT_HTTP}
    - {name: https, port: 443, targetPort: 443, protocol: TCP${GATEWAY_NODE_PORT_HTTPS:+, nodePort: $GATEWAY_NODE_PORT_HTTPS}}
GATEWAY
fi
# No --wait: a LoadBalancer service never becomes ready on a cluster that
# cannot provide one. The rollout is checked instead.
helm upgrade --install istio-ingress istio/gateway -n istio-ingress \
  -f values/gateway.yaml -f "$work/gateway.yaml" ${version_flag[@]+"${version_flag[@]}"} \
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
{
  echo "config:"
  echo "  configFile: |-"
  echo "    email_domains = [ \"$domains\" ]"
  echo "    upstreams = [ \"static://200\" ]"
  echo "extraArgs:"
  echo "  cookie-secure: \"$TLS_ENABLED\""
  echo "  redirect-url: \"$redirect_url\""
  if [ -n "$KEYCLOAK_HOST" ]; then
    # Keycloak in this cluster. Browsers use its public address; oauth2-proxy
    # itself talks to it over the cluster network. That works even when the
    # public address is not reachable from inside the cluster (local
    # clusters) or uses a certificate pods do not trust.
    kc_public="$scheme://$KEYCLOAK_HOST$port_suffix/realms/$KEYCLOAK_REALM"
    kc_internal="$KEYCLOAK_INTERNAL_URL/realms/$KEYCLOAK_REALM"
    echo "  oidc-issuer-url: \"${OIDC_ISSUER_URL:-$kc_public}\""
    echo "  skip-oidc-discovery: \"true\""
    echo "  login-url: \"$kc_public/protocol/openid-connect/auth\""
    echo "  redeem-url: \"$kc_internal/protocol/openid-connect/token\""
    echo "  oidc-jwks-url: \"$kc_internal/protocol/openid-connect/certs\""
    # Proof Key for Code Exchange; the Keycloak client requires it.
    echo "  code-challenge-method: S256"
  else
    echo "  oidc-issuer-url: \"$OIDC_ISSUER_URL\""
  fi
} > "$work/oauth2-proxy.yaml"

echo "==> Installing oauth2-proxy"
helm upgrade --install oauth2-proxy oauth2-proxy/oauth2-proxy -n oauth2-proxy \
  -f values/oauth2-proxy.yaml -f "$work/oauth2-proxy.yaml" --wait

# --- sign-in policy -----------------------------------------------------------
# Hosts served without sign-in: PUBLIC_HOSTS plus the Keycloak host.
public_hosts="$PUBLIC_HOSTS"
[ -z "$KEYCLOAK_HOST" ] || public_hosts="${public_hosts:+$public_hosts,}$KEYCLOAK_HOST"

echo "==> Installing the gateway and sign-in policy"
helm upgrade --install sso-config ./sso-config -n istio-ingress \
  --set "hosts={$SSO_HOST}" \
  --set "publicHosts={$public_hosts}" \
  --set gateway.tls.enabled="$TLS_ENABLED" \
  --set gateway.tls.credentialName="$TLS_SECRET_NAME" \
  --set demoApp.enabled="$DEMO_APP" \
  --wait

echo
echo "Istio with SSO sign-in is installed."
if [ -z "$KEYCLOAK_HOST" ]; then
  echo "1. Register this redirect URI in your identity provider:"
  echo "     $redirect_url"
  echo "2. Point DNS for $SSO_HOST at the gateway address shown by:"
  echo "     kubectl get service istio-ingress -n istio-ingress"
  echo "3. Open $external_url/headers - you should be sent to sign in first."
fi
