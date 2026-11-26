#!/usr/bin/env bash
# Removes Keycloak from the cluster of the current kubectl context.
#
#   ./uninstall.sh              remove Keycloak, keep its database volume
#   ./uninstall.sh --purge      also delete the database volume and namespace
#   ./uninstall.sh --with-istio also remove Istio and the sign-in setup
set -euo pipefail
cd "$(dirname "$0")"

for tool in helm kubectl; do
  command -v "$tool" >/dev/null 2>&1 || { echo "error: $tool is not installed" >&2; exit 127; }
done

purge=false
with_istio=false
for arg in "$@"; do
  case "$arg" in
    --purge) purge=true ;;
    --with-istio) with_istio=true ;;
    *) echo "usage: ./uninstall.sh [--purge] [--with-istio]" >&2; exit 2 ;;
  esac
done
NAMESPACE="${KEYCLOAK_NAMESPACE:-keycloak}"

echo "==> Removing Keycloak from context: $(kubectl config current-context)"
helm uninstall keycloak -n "$NAMESPACE" --ignore-not-found

if [ "$purge" = "true" ]; then
  # Deletes every user, realm and setting stored in the database.
  kubectl delete pvc -n "$NAMESPACE" -l app.kubernetes.io/name=keycloak-postgres --ignore-not-found
  kubectl delete pvc -n "$NAMESPACE" data-keycloak-postgres-0 --ignore-not-found
  kubectl delete namespace "$NAMESPACE" --ignore-not-found
else
  echo "The database volume was kept. Remove it too with: ./uninstall.sh --purge"
fi

[ "$with_istio" != "true" ] || ../istio/helm/uninstall.sh
