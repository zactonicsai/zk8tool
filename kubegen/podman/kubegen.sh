#!/usr/bin/env bash
# Runs kubegen in a Podman container, so neither Go nor a local build is
# needed. Use it exactly like the kubegen binary, from the directory that
# holds your cluster definition:
#
#   podman/kubegen.sh -f podman/kind-podman.yaml
#   podman/kubegen.sh -f examples/aks.yaml -format terraform
#
# The current directory is mounted into the container, so -f and -o paths
# must be inside it and relative.
#
# The container holds only kubegen, not kind, az, terraform and so on, so
# the tool check is skipped here. Generated shell scripts still check for
# their tools when you run them on the host.
set -euo pipefail

IMAGE="${KUBEGEN_IMAGE:-localhost/kubegen:latest}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if ! command -v podman >/dev/null 2>&1; then
  echo "error: podman is not installed or not in PATH" >&2
  echo "       install it from: https://podman.io/docs/installation" >&2
  exit 127
fi

# Build the image on first use (KUBEGEN_REBUILD=1 forces a rebuild).
if [ -n "${KUBEGEN_REBUILD:-}" ] || ! podman image exists "$IMAGE"; then
  echo "==> Building $IMAGE" >&2
  podman build -t "$IMAGE" -f "$ROOT/podman/Containerfile" "$ROOT" >&2
fi

# :Z relabels the mount for SELinux hosts (Fedora, RHEL); harmless elsewhere.
# kubegen cannot see the host's container engines from inside the
# container. You are running Podman, so kind definitions that do not set
# kind.runtime default to Podman (override: KUBEGEN_KIND_RUNTIME=docker).
exec podman run --rm -v "$PWD":/work:Z -w /work \
  -e KUBEGEN_KIND_RUNTIME="${KUBEGEN_KIND_RUNTIME:-podman}" \
  "$IMAGE" -skip-tool-check "$@"
