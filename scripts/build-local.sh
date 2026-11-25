#!/usr/bin/env bash
#
# Build the y623 firmware locally in the container defined by ./Dockerfile.
#
# The build does NOT run on the bind-mounted repo. Each run rsyncs the working
# tree into a named Docker volume ($WORK_VOLUME, mounted at /work), builds
# there, and copies build/ and out/ back into the repo. Why:
#
#   With colima (vz + virtiofs) the bind mount is not a POSIX filesystem: the
#   permission checks are done by macOS on behalf of the host user, so root in
#   the container cannot override them. GNU tar extracts a symlink whose target
#   contains ".." (live555 ships 17 of them, e.g. hlsProxy/COPYING ->
#   ../COPYING) by first creating an empty placeholder file with mode 000 and
#   swapping in the symlink at the end. On virtiofs that placeholder cannot be
#   opened ("Cannot open: Permission denied") and the leftovers cannot even be
#   deleted from inside the container. Running the container with the host
#   uid does not help (tested): the mode 000 file is unreadable to its owner
#   too. A Docker volume lives on the VM's own ext4, where tar, rm and the
#   compilers behave as on CI. Docker Desktop handles volumes the same way, so
#   one code path serves both.
#
# /work is an exact mirror of the repo (rsync --delete, only build/ and out/
# excluded), so it sees what a bind mount would: uncommitted edits, deleted
# files, ignored files. The source archives each module downloads
# (src/<module>/*.tar.gz ...) are copied back to the repo after the run, so
# the next sync brings them along and init scripts skip the download, as they
# did with the bind mount. Rebuilding a single module after an edit therefore
# takes seconds instead of the seven minutes a CI round-trip costs.
#
# Do not try to protect volume-only files with --filter=":- .gitignore":
# rsync reads "ipc_cmd/ipc_cmd" as "any path ending so", not as git's path
# anchored to the .gitignore, and it silently drops src/ipc_cmd/ipc_cmd/.
#
# Usage:
#   scripts/build-local.sh                 full build, then pack y623
#   scripts/build-local.sh <module>        compile one module only (e.g. dropbear)
#   scripts/build-local.sh shell           interactive shell in /work (the copy;
#                                          edits there are NOT copied back)
#   scripts/build-local.sh --rebuild ...   force the image to be rebuilt first
#   scripts/build-local.sh --clean ...     drop the work volume (cached
#                                          downloads included) first
#
# Note: compile.sh wipes build/ on every invocation, so a single-module run
# leaves build/ incomplete. Use it to check that a module still compiles; run a
# full build before packing or flashing.

set -euo pipefail

IMAGE="yi-hack-y623-build"
WORK_VOLUME="yi-hack-y623-work"
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

while [ $# -gt 0 ]; do
    case "$1" in
        --rebuild)
            shift
            docker build --platform linux/amd64 -t "$IMAGE" "$REPO_DIR"
            ;;
        --clean)
            shift
            docker volume rm "$WORK_VOLUME" >/dev/null 2>&1 || true
            ;;
        *) break ;;
    esac
done

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "Image $IMAGE not found, building it (this downloads the toolchain, once)..."
    docker build --platform linux/amd64 -t "$IMAGE" "$REPO_DIR"
fi

# CI checks out with submodules: recursive. Without them src/mqtt/mqttv4 is an
# empty directory, and init.mqtt's "cd mqttv4; git reset --hard" then resets
# the enclosing repo instead (harmless in /work, but the build fails).
if git -C "$REPO_DIR" submodule status --recursive | grep -q '^-'; then
    echo "error: git submodules are not initialised. Run:" >&2
    echo "    git -C \"$REPO_DIR\" submodule update --init --recursive" >&2
    exit 1
fi

# Rosetta breaks GNU make's jobserver for nested makes: a sub-make started by
# "make -jN" dies with "write jobserver: Bad file descriptor" (reproduced with
# a two-level Makefile: fails every time under Rosetta, passes on native arm64
# and on CI). snapshot (ffmpeg, libjpeg-turbo) hits it on every build. The
# module scripts all run "make -j $(nproc)", and coreutils nproc honours
# OMP_NUM_THREADS, so on Apple Silicon default to 1 job: no jobserver, slower
# but correct. Override with BUILD_JOBS=N (e.g. on an x86-64 host it is unset
# and nproc reports the real CPU count).
BUILD_JOBS="${BUILD_JOBS:-}"
if [ -z "$BUILD_JOBS" ] && [ "$(uname -m)" = "arm64" ]; then
    BUILD_JOBS=1
fi
JOBS_ENV=""
if [ -n "$BUILD_JOBS" ]; then
    JOBS_ENV="-e OMP_NUM_THREADS=$BUILD_JOBS"
fi

# -it only with a terminal on both ends, so the script also works from
# non-interactive callers (CI-like wrappers, editors, agents).
TTY_FLAGS=""
if [ -t 0 ] && [ -t 1 ]; then
    TTY_FLAGS="-it"
fi

# Runs "$1" (a bash command line) in /work after syncing the repo into it, then
# copies build/, out/ and the downloaded archives back to the repo even if the
# command failed, so a partial build/ is there to inspect. The exit status is
# the command's.
run() {
    # shellcheck disable=SC2086
    docker run --rm $TTY_FLAGS $JOBS_ENV \
        --platform linux/amd64 \
        -v "$REPO_DIR:/src" \
        -v "$WORK_VOLUME:/work" \
        -w /work \
        "$IMAGE" \
        /bin/bash -c '
            set -e
            # build/ and out/ are outputs, everything else mirrors the repo.
            rsync -a --delete --exclude=/build --exclude=/out /src/ /work/
            rc=0
            /bin/bash -c "$1" || rc=$?
            if [ -d /work/build ]; then
                mkdir -p /src/build
                rsync -a --delete /work/build/ /src/build/
            fi
            if [ -d /work/out ]; then
                mkdir -p /src/out
                rsync -a /work/out/ /src/out/
            fi
            # Cache the downloaded source archives in the repo (all ignored by
            # git); existing files are left alone.
            rsync -a --ignore-existing \
                --include="/*/" \
                --include="/*/*.tar.gz" --include="/*/*.tar.bz2" \
                --include="/*/*.tar.xz" --include="/*/*.tgz" --include="/*/*.zip" \
                --exclude="*" \
                /work/src/ /src/src/
            exit $rc
        ' run "$1"
}

case "${1:-}" in
    shell)
        run /bin/bash
        ;;
    "")
        run "bash -e scripts/compile.sh && bash -e scripts/pack_fw.sh $CAMERA"
        echo "Artifact: $REPO_DIR/out/$CAMERA/"
        ls -la "$REPO_DIR/out/$CAMERA/" 2>/dev/null || true
        ;;
    *)
        run "bash -e scripts/compile.sh $1"
        ;;
esac
