#!/usr/bin/env bash
# Builds kubegen.
#
#   ./build.sh            build bin/kubegen
#   ./build.sh examples   build, then regenerate everything under examples/output
#   ./build.sh clean      remove bin/
set -euo pipefail
cd "$(dirname "$0")"

MIN_GO="1.22"

case "${1:-build}" in
  build | examples) ;;
  clean)
    rm -rf ./bin
    echo "removed bin/"
    exit 0
    ;;
  *)
    echo "usage: ./build.sh [build|examples|clean]" >&2
    exit 2
    ;;
esac

# --- Go toolchain -----------------------------------------------------------
if ! command -v go >/dev/null 2>&1; then
  echo "error: Go is not installed or not in PATH" >&2
  echo "       install it from: https://go.dev/dl/" >&2
  exit 127
fi
have="$(go env GOVERSION | sed 's/^go//')"
if [ "$(printf '%s\n%s\n' "$MIN_GO" "$have" | sort -V | head -n1)" != "$MIN_GO" ]; then
  echo "error: Go $MIN_GO or newer is required (found $have)" >&2
  echo "       install it from: https://go.dev/dl/" >&2
  exit 1
fi

# --- Build ------------------------------------------------------------------
echo "==> Resolving dependencies"
go mod tidy

echo "==> Checking the code"
go vet ./...

echo "==> Building bin/kubegen (Go $have)"
mkdir -p bin
go build -trimpath -o bin/kubegen .
echo "built bin/kubegen"

# --- Examples ---------------------------------------------------------------
if [ "${1:-build}" = "examples" ]; then
  ./examples/generate-examples.sh
else
  echo
  echo "Try it:  ./bin/kubegen -f examples/kind.yaml -o -"
fi
