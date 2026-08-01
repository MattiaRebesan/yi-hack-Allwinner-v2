#!/usr/bin/env bash
#
# Flash the latest CI build to the camera's microSD card, on macOS.
#
# Downloads the newest successful build artifact from the fork, wipes the old
# yi-hack tree off the card, extracts the new one, and carries your settings
# across. Always use this instead of Finder or Archive Utility: a Finder copy
# of the payload is what bricked the camera before, because it silently
# produced a partial tree and lower_half_init.sh then ran nothing.
#
# Usage:
#   scripts/flash-sd.sh                    download latest build, flash it
#   scripts/flash-sd.sh --run <id>         flash a specific workflow run
#   scripts/flash-sd.sh --tgz <path>       flash a local .tgz (no download)
#   scripts/flash-sd.sh --volume /Volumes/X   target a specific card
#   scripts/flash-sd.sh --yes              skip the confirmation prompt
#   scripts/flash-sd.sh --verify <ip>      check a booted camera, flash nothing
#
# The card must already be out of the camera and mounted.

set -euo pipefail

REPO="MattiaRebesan/yi-hack-Allwinner-v2"
BRANCH="y623-ha"
BACKUP_ROOT="$HOME/yihack-backups"

# Settings files that hold your data rather than defaults. Carried across a
# flash. system.conf is handled separately: its values are merged, not copied,
# so keys a build has removed do not come back.
PRESERVE=(camera.conf mqttv4.conf mqtt_advertise.conf ptz_presets.conf hostname)

RUN_ID=""
TGZ=""
VOLUME=""
ASSUME_YES=0
VERIFY_IP=""

die() { echo "error: $*" >&2; exit 1; }
say() { echo "==> $*"; }

while [ $# -gt 0 ]; do
    case "$1" in
        --run)     RUN_ID="${2:?--run needs a run id}"; shift 2 ;;
        --tgz)     TGZ="${2:?--tgz needs a path}"; shift 2 ;;
        --volume)  VOLUME="${2:?--volume needs a path}"; shift 2 ;;
        --verify)  VERIFY_IP="${2:?--verify needs an ip}"; shift 2 ;;
        --yes|-y)  ASSUME_YES=1; shift ;;
        -h|--help) sed -n '3,26p' "$0"; exit 0 ;;
        *)         die "unknown option: $1" ;;
    esac
done

# ---------------------------------------------------------------- verify mode

verify() {
    local ip="$1" ok=0
    say "Checking camera at $ip"

    # Not a ping check: the camera drops ICMP but serves HTTP fine.
    local status
    status=$(curl -s --max-time 15 "http://$ip/cgi-bin/status.json" || true)
    if [ -z "$status" ]; then
        die "$ip is not serving http. Give it ~60s after power-on, then retry."
    fi
    echo "  status.json  OK"
    echo "$status" | grep -E '"(fw_version|model_suffix|uptime|free_memory|total_memory)"' | sed 's/^/    /'

    # The \n matters: without it read hits EOF, returns 1, and set -e aborts.
    local code size
    read -r code size < <(curl -s -o /dev/null --max-time 20 \
        -w '%{http_code} %{size_download}\n' "http://$ip/cgi-bin/snapshot.sh" || echo "000 0")
    if [ "$code" = "200" ] && [ "$size" -gt 10000 ]; then
        echo "  snapshot     OK ($size bytes)"
    else
        echo "  snapshot     FAIL (http $code, $size bytes)"; ok=1
    fi

    code=$(curl -s -o /dev/null --max-time 10 -w '%{http_code}' \
        "http://$ip/onvif/device_service" || echo 000)
    if [ "$code" = "200" ]; then echo "  onvif        OK"; else echo "  onvif        FAIL (http $code)"; ok=1; fi

    if command -v ffprobe >/dev/null 2>&1; then
        local res
        res=$(ffprobe -v error -rtsp_transport tcp -select_streams v:0 \
                -show_entries stream=codec_name,width,height -of csv=p=0 \
                "rtsp://$ip:554/ch0_0.h264" 2>/dev/null || true)
        if [ -n "$res" ]; then echo "  rtsp         OK ($res)"; else echo "  rtsp         FAIL"; ok=1; fi
    else
        echo "  rtsp         SKIPPED (no ffprobe; brew install ffmpeg)"
    fi

    [ $ok -eq 0 ] && say "All checks passed." || say "Some checks failed — see above."
    return $ok
}

if [ -n "$VERIFY_IP" ]; then
    verify "$VERIFY_IP"
    exit $?
fi

# ------------------------------------------------------------- find the card

if [ -z "$VOLUME" ]; then
    candidates=()
    for v in /Volumes/*; do
        [ -d "$v" ] || continue
        if [ -d "$v/yi-hack" ] || [ -d "$v/Factory" ] || [ -d "$v/Factory.done" ]; then
            candidates+=("$v")
        fi
    done
    case ${#candidates[@]} in
        0) die "no yi-hack SD card found under /Volumes. Insert the card, or pass --volume." ;;
        1) VOLUME="${candidates[0]}" ;;
        *) printf 'multiple candidate cards found:\n'; printf '  %s\n' "${candidates[@]}"
           die "pass --volume to pick one" ;;
    esac
fi

[ -d "$VOLUME" ] || die "$VOLUME is not a directory"
[ "$VOLUME" != "/" ] || die "refusing to touch /"
case "$VOLUME" in /Volumes/*) ;; *) die "$VOLUME is not under /Volumes — refusing" ;; esac
[ -w "$VOLUME" ] || die "$VOLUME is not writable (card locked?)"

# A yi-hack card carries at least one of these. Guards against flashing a
# random USB stick that happens to be mounted.
if [ ! -d "$VOLUME/yi-hack" ] && [ ! -d "$VOLUME/Factory" ] && [ ! -d "$VOLUME/Factory.done" ]; then
    die "$VOLUME has no yi-hack, Factory or Factory.done — this does not look like the camera card"
fi

# Fresh card: keep Factory/, it is the one-shot installer that patches
# /backup/init.sh. Already-hacked card: skip it, init.sh is patched and
# re-running it only costs an extra reboot.
if [ -d "$VOLUME/Factory.done" ] || [ -d "$VOLUME/yi-hack" ]; then
    MODE="update"
else
    MODE="install"
fi

# --------------------------------------------------------------- get the tgz

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

if [ -n "$TGZ" ]; then
    [ -f "$TGZ" ] || die "$TGZ not found"
else
    command -v gh >/dev/null 2>&1 || die "gh not installed and no --tgz given"

    if [ -z "$RUN_ID" ]; then
        say "Looking up the latest successful build on $BRANCH"
        RUN_ID=$(gh run list -R "$REPO" -b "$BRANCH" --status success -L 1 \
                    --json databaseId -q '.[0].databaseId')
        [ -n "$RUN_ID" ] || die "no successful run found on $BRANCH"
    fi

    say "Downloading artifact from run $RUN_ID"
    gh run download "$RUN_ID" -R "$REPO" -n build -D "$WORK/artifact" >/dev/null
    TGZ=$(find "$WORK/artifact" -name '*.tgz' | head -1)
    [ -n "$TGZ" ] || die "no .tgz in the artifact"
fi

gzip -t "$TGZ" || die "$TGZ is not a valid gzip — download it again"

# Keep every image we flash. Reflashing the previous one is the rollback.
mkdir -p "$BACKUP_ROOT/images"
cp -f "$TGZ" "$BACKUP_ROOT/images/"
KEPT="$BACKUP_ROOT/images/$(basename "$TGZ")"

# ------------------------------------------------------------------- confirm

echo
echo "  image   $(basename "$TGZ")"
echo "  card    $VOLUME"
echo "  mode    $MODE ($([ "$MODE" = update ] && echo 'Factory/ skipped, hack already installed' || echo 'fresh install, Factory/ included'))"
echo "  action  delete $VOLUME/yi-hack, extract the image, restore your settings"
echo

if [ $ASSUME_YES -eq 0 ]; then
    read -r -p "Proceed? [y/N] " reply
    case "$reply" in [yY]|[yY][eE][sS]) ;; *) echo "Aborted."; exit 1 ;; esac
fi

# -------------------------------------------------------------------- backup

STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP="$BACKUP_ROOT/etc-$STAMP"
OLD_CONF=""

if [ -d "$VOLUME/yi-hack/etc" ]; then
    mkdir -p "$BACKUP"
    cp -a "$VOLUME/yi-hack/etc/." "$BACKUP"/
    say "Backed up current config to $BACKUP"
    [ -f "$BACKUP/system.conf" ] && OLD_CONF="$BACKUP/system.conf"
fi

# --------------------------------------------------------------------- flash

if [ -d "$VOLUME/yi-hack" ]; then
    say "Removing the old yi-hack tree"
    rm -rf "$VOLUME/yi-hack"
fi

say "Extracting $(basename "$TGZ")"
if [ "$MODE" = "update" ]; then
    tar xzf "$TGZ" --exclude 'Factory*' -C "$VOLUME"
else
    tar xzf "$TGZ" -C "$VOLUME"
fi

[ -d "$VOLUME/yi-hack/bin" ] && [ -d "$VOLUME/yi-hack/script" ] && [ -d "$VOLUME/yi-hack/www" ] \
    || die "extraction looks incomplete — do not boot this card"

# ------------------------------------------------------------ restore config

if [ -n "$BACKUP" ] && [ -d "$BACKUP" ]; then
    for f in "${PRESERVE[@]}"; do
        if [ -f "$BACKUP/$f" ]; then
            cp -f "$BACKUP/$f" "$VOLUME/yi-hack/etc/$f"
            echo "    restored $f"
        fi
    done
fi

# Merge system.conf rather than copying it: take the old value for every key
# the new build still defines, and silently drop keys it no longer reads.
if [ -n "$OLD_CONF" ] && [ -f "$VOLUME/yi-hack/etc/system.conf" ]; then
    python3 - "$OLD_CONF" "$VOLUME/yi-hack/etc/system.conf" <<'PY'
import sys
old_path, new_path = sys.argv[1], sys.argv[2]

def parse(path):
    out = {}
    for line in open(path):
        line = line.rstrip("\n")
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, _, v = line.partition("=")
        out[k] = v
    return out

old = parse(old_path)
lines, carried, dropped = [], [], []
for line in open(new_path):
    stripped = line.rstrip("\n")
    if "=" in stripped and not stripped.startswith("#"):
        k, _, v = stripped.partition("=")
        if k in old and old[k] != v:
            lines.append(f"{k}={old[k]}\n")
            carried.append(k)
            continue
    lines.append(line)

new_keys = {l.partition("=")[0] for l in lines if "=" in l and not l.startswith("#")}
dropped = sorted(set(old) - new_keys)

open(new_path, "w").writelines(lines)
if carried:
    print("    carried over: " + ", ".join(sorted(carried)))
if dropped:
    print("    dropped (no longer used): " + ", ".join(dropped))
PY
fi

# ---------------------------------------------------------------------- eject

# macOS keeps .Spotlight-V100 / .fseventsd SIP-protected, so both dot_clean and
# find fail on them. Those dirs never hold ._* files and the camera ignores
# them, so prune them and drop the noise.
say "Cleaning AppleDouble files"
dot_clean -m "$VOLUME" 2>/dev/null || true
leftover=$(find "$VOLUME" \
    \( -name '.Spotlight-V100' -o -name '.fseventsd' -o -name '.Trashes' \) -prune -o \
    -name '._*' -print 2>/dev/null | wc -l | tr -d ' ')
[ "$leftover" = "0" ] || echo "    warning: $leftover ._* files remain"

sync
say "Ejecting $VOLUME"
diskutil eject "$VOLUME" >/dev/null

VERSION=$(basename "$TGZ" .tgz)
cat <<EOF

Done. Flashed $VERSION

  rollback  $KEPT
  config    $BACKUP

Put the card back in the camera, power on, wait ~60s, then:

  scripts/flash-sd.sh --verify 192.168.1.20
EOF
