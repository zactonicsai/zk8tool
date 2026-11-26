#!/usr/bin/env bash
# Removes everything install.sh installed, in reverse order.
set -euo pipefail

for tool in helm kubectl; do
  command -v "$tool" >/dev/null 2>&1 || { echo "error: $tool is not installed" >&2; exit 127; }
done

helm uninstall sso-config    -n istio-ingress --ignore-not-found
helm uninstall oauth2-proxy  -n oauth2-proxy  --ignore-not-found
helm uninstall istio-ingress -n istio-ingress --ignore-not-found
helm uninstall istiod        -n istio-system  --ignore-not-found
helm uninstall istio-base    -n istio-system  --ignore-not-found

kubectl delete secret oauth2-proxy-credentials -n oauth2-proxy --ignore-not-found
kubectl delete namespace oauth2-proxy istio-ingress istio-system --ignore-not-found

echo "Removed. Istio's custom resource definitions are left in place; delete them with:"
echo "  kubectl get crd -o name | grep 'istio.io' | xargs kubectl delete"
