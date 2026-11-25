#!/usr/bin/env bash
# Regenerates examples/output from the example cluster definitions:
#
#   output/shell/create-<name>.sh      kubegen -format shell
#   output/terraform/<provider>/       kubegen -format terraform
#   output/console.txt                 what kubegen printed while doing so
#
# -skip-tool-check is used so this works on a machine without the cloud CLIs;
# kubegen then lists missing tools as warnings instead of stopping.
set -euo pipefail
cd "$(dirname "$0")/.."

KUBEGEN="${KUBEGEN:-./bin/kubegen}"
if [ ! -x "$KUBEGEN" ]; then
  echo "error: $KUBEGEN not found; run ./build.sh first" >&2
  exit 1
fi

OUT=examples/output
mkdir -p "$OUT/shell" "$OUT/terraform"
: > "$OUT/console.txt"

# run prints a command to the console log, then runs it and logs its output.
run() {
  echo "\$ $*" >> "$OUT/console.txt"
  "$@" >> "$OUT/console.txt" 2>&1
  echo >> "$OUT/console.txt"
}

for provider in kind aks eks vks dks; do
  name="$(sed -n 's/^name: *//p' "examples/$provider.yaml")"
  echo "==> $provider ($name)"
  run "$KUBEGEN" -f "examples/$provider.yaml" -o "$OUT/shell/create-$name.sh" -skip-tool-check
  run "$KUBEGEN" -f "examples/$provider.yaml" -format terraform -o "$OUT/terraform/$provider" -skip-tool-check
done

# kind on Podman: its definition and output live in podman/.
echo "==> kind on podman (dev-podman)"
mkdir -p podman/output
run "$KUBEGEN" -f podman/kind-podman.yaml -o podman/output/create-dev-podman.sh -skip-tool-check
run "$KUBEGEN" -f podman/kind-podman.yaml -format terraform -o podman/output/terraform -skip-tool-check

echo "examples written to $OUT and podman/output"
