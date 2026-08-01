# What was deliberately not done, and why

This fork strips yi-hack-Allwinner-v2 down to a single camera model (y623) used
as a stream-only source for Home Assistant. Plenty of things looked like
obvious cuts and turned out not to be. This file records those, so nobody —
including a future me — re-litigates them from scratch.

Each entry is: what was proposed, why it was rejected, and what evidence
settled it. If the evidence changes, the decision is fair game again.

---

## Things that would have broken something

### `SAVE_VIDEO_ON_MOTION=no` — left at `yes`

**Proposed:** set it to `no` to stop the camera writing clips to the SD card.

**Why not:** it means the opposite of what it reads like.
`src/www/httpd/cgi-bin/load.sh:106-109` maps `no` → `ipc_cmd -v always` and
anything else → `ipc_cmd -v detect`, and `ipc_cmd.c:91` documents `-v` as
*"set save mode: ALWAYS or DETECT"*. So `no` means **record continuously**.

Recording is off on this build because `MOTION_DETECTION=no`, not because of
this key. There is no combination that yields motion *events* (which HA wants)
without motion *clips* — the stock firmware ties them together, and none of
that code lives in this repo.

### Deleting `script/clean_records.sh` — kept, with `FREE_SPACE=15`

**Proposed:** delete the hourly prune cron along with the rest of the
recording machinery, and set `FREE_SPACE=0`.

**Why not:** the events-browsing UI was deleted in the same stage, so there is
no longer any way to delete clips by hand short of pulling the card. If motion
detection ever gets switched on, the card fills silently and the first symptom
is the stream dying. The cron is now the only backstop, so it stays.
`FREE_SPACE=15` prunes oldest-first below 15% free.

---

## Things that are not actually possible here

### Raising stream bitrate / fps / GOP

**Why not:** `rRTSPServer` does not encode. It relays the H.264 the stock Yi
firmware encoder already writes to shared memory. Its entire CLI is
`-m -r -a -b -p -s -u -w -d` (`rRTSPServer.cpp:957-976`) — no bitrate, no
framerate, no keyframe interval.

**No change in this repo can raise stream quality.** Encoder settings live in
the stock firmware, reachable only through `camera.conf` / `ipc_cmd` / the Yi
app. "Faster" in this project means freeing the SoC, not tuning the encoder.

The one thing that *did* help was `RTSP_AUDIO`: it was `yes`, which
`rRTSPServer.cpp:1137` maps to `convertTo = WA_PCMU`, so the camera was
decoding its own AAC and re-encoding it to G.711 every frame. Now `aac`
(passthrough). That is a CPU win on the camera and one fewer transcode in HA.

### Client-side latency

Nothing on the camera competes with the HA-side setup: point go2rtc straight
at `rtsp://<ip>:554/ch0_0.h264` and use WebRTC rather than HLS for the live
card. That is the difference between ~2 s and sub-second. Camera-side work is
rounding error next to it.

---

## Things left alone on purpose

### The `MODEL_SUFFIX` branches in C and shell

19 of 20 models were removed from `sysroot/`, `sdhack/`, `unbrick/` and the
`CAMERAS` array. The per-model `if` branches inside `service.sh`,
`snapshot/imggrabber.c`, `h264grabber.c`, `rRTSPServer.cpp` and
`set_tz_offset.c` were **not** touched.

**Why not:** they cost a few bytes and one untaken branch. Editing them would
conflict on every single upstream merge, forever, for no measurable gain.

### `src/mqtt-config/mqtt-config/validate.c` — stale keys still whitelisted

It still accepts `FTPD`, `BUSYBOX_FTPD`, `FTP_*`, `EVENTS_TIME`, `TIMELAPSE*`
even though those keys and their daemons are gone.

**Why not:** the table length is fixed by `#define PARAM_NUM 81` in
`validate.h`, so removing rows means editing two files in lockstep for a table
that is only a *whitelist*. Accepting a key nothing reads is harmless — writing
`FTPD=yes` over MQTT now sets a string in a file no script consults.

### Swap — `SWAP_FILE=yes`, `SWAP_SWAPPINESS=15`

**Proposed:** disable swap; swapping to an SD card is slow.

**Why not:** measured free RAM is ~12.3 MB of 59.5 MB at 5 min uptime (the
36.8 MB reading taken seconds after boot was pre-cache and not real). Swap is
insurance against `h264grabber` being OOM-killed mid-stream. Swap-to-SD is
slow; a dead grabber is slower.

### `speaker` / `pcmvol` / `alsa-lib`

Kept, despite being cut candidates in a "stream-only" build. Two-way audio and
TTS from HA are a streaming feature, not a recording one.

### Dependency bumps

Dropped from the plan as unnecessary: dropbear 2026.91, wolfSSL 5.8.4, jq
1.8.1, busybox 1.36.1 are all current.

---

## Known rough edges

### `check_conf.sh` only ever adds keys

Its loops (`if [ -z "$MATCH" ]; then echo "$i" >> $CONF_FILE; fi`) add missing
keys and never remove obsolete ones. A card that was flashed before a key was
deleted keeps that key forever.

Harmless — nothing reads them — and `scripts/flash-sd.sh` merges rather than
copies `system.conf`, so a flash through that script does drop them. Worth
knowing if you ever hand-edit a card.

### Recording thumbnails and timelapse are gone as collateral

Not a decision so much as a consequence: `thumb.sh` needed `minimp4_yi` and
`create_avi.sh` shipped from `mjpeg-avi`, both removed in Stage 2. Accepted —
neither has a Home Assistant use.

### `camera.conf` is not applied at boot

It is only read by `www/cgi-bin/load.sh` (a web-UI action) and by
`mqtt-config`. `system.sh` does not apply it on startup. So editing
`camera.conf` on the card by hand does nothing until something triggers a load.
Not changed — that is upstream behaviour and rewiring it is out of scope.
