#!/usr/bin/env bash
#
# Build the y623 firmware locally in the container defined by ./Dockerfile.
#
# The repo is bind-mounted, so build/ and out/ land in the working tree and
# each module's downloaded sources persist between runs. That is the point:
# rebuilding a single module after an edit takes seconds instead of the seven
# minutes a CI round-trip costs.
#
# Usage:
#   scripts/build-local.sh                 full build, then pack y623
#   scripts/build-local.sh <module>        compile one module only (e.g. dropbear)
#   scripts/build-local.sh shell           interactive shell in the container
#   scripts/build-local.sh --rebuild ...   force the image to be rebuilt first
#
# Note: compile.sh wipes build/ on every invocation, so a single-module run
# leaves build/ incomplete. Use it to check that a module still compiles; run a
# full build before packing or flashing.

set -euo pipefail

IMAGE="yi-hack-y623-build"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CAMERA="y623"

if ! docker info >/dev/null 2>&1; then
    cat >&2 <<'MSG'
error: the Docker daemon is not running.

With colima on Apple Silicon, start it with Rosetta so the x86-64 toolchain
runs at native-ish speed instead of under full QEMU emulation:

    colima start --vm-type=vz --vz-rosetta --cpu 4 --memory 8 --disk 60

With Docker Desktop, just start the app (enable "Use Rosetta for x86_64/amd64
emulation" in Settings > General).
MSG
    exit 1
fi

if [ "${1:-}" = "--rebuild" ]; then
    shift
    docker build --platform linux/amd64 -t "$IMAGE" "$REPO_DIR"
elif ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "Image $IMAGE not found, building it (this downloads the toolchain, once)..."
    docker build --platform linux/amd64 -t "$IMAGE" "$REPO_DIR"
fi

run() {
    docker run --rm -it \
        --platform linux/amd64 \
        -v "$REPO_DIR:/src" \
        -w /src \
        "$IMAGE" \
        "$@"
}

case "${1:-}" in
    shell)
        run /bin/bash
        ;;
    "")
        run /bin/bash -c "bash -e scripts/compile.sh && bash -e scripts/pack_fw.sh $CAMERA"
        echo "Artifact: $REPO_DIR/out/$CAMERA/"
        ls -la "$REPO_DIR/out/$CAMERA/" 2>/dev/null || true
        ;;
    *)
        run /bin/bash -c "bash -e scripts/compile.sh $1"
        ;;
esac
