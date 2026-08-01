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

## Things removed that you might miss

### Online firmware upgrade — removed as a security fix

**Removed:** `www/cgi-bin/fw_upgrade.sh`, the Maintenance page's "Online FW
upgrade" block, and the second-phase installer in
`script/system.sh` (`YI_HACK_UPGRADE_PATH="/tmp/sd/.fw_upgrade"` plus the boot
block that copied whatever was staged there over the live install).

**Why it is a security fix, not a convenience cut:** the CGI fetched
`api.github.com/repos/roleoroleo/yi-hack-Allwinner-v2/releases/latest` and
installed `${MODEL_SUFFIX}_${LATEST_FW}.tgz` **from upstream**. One click
replaced this build — and every hardening decision in it — with stock
yi-hack: FTP back, telnet back, cloud phone-home back, blank-password root
SSH back. Port 80 has no authentication (owner's call, below), so *anything on
the LAN* could trigger that with a single unauthenticated GET, and the camera
would come back up as a different, weaker device with the same IP.

The two halves had to go together. Deleting only the CGI leaves a boot-time
installer that trusts an unauthenticated path on a world-writable card;
deleting only the boot block leaves a CGI that stages a payload nothing
consumes.

**Cost:** upgrades are SD-card flashes now — `scripts/flash-sd.sh`. That is
the same operation the fork already required for anything that changes a
config default, so in practice nothing was lost.

### PTZ — removed entirely, it was already dead

**Removed:** `cgi-bin/ptz.sh`, `cgi-bin/preset.sh`,
`script/ptz_presets.sh`, the PTZ page and its 225 lines of JS, the `CRUISE`
row and its handling in `camera_settings.sh` and `load.sh`, the `ptz` field in
`status.json`, and — beyond the plan — the **whole PTZ block in
`service.sh`**, not just the `ptz_presets.sh` call sites.

**Why the whole block:** it was gated on
`r30gb|r35gb|r37gb|r40gb|h51ga|h52ga|h60ga|q321br_lsx|qg311r|b091qp`. `y623`
is in none of them, so every line inside was unreachable on this hardware.
What it *did* do on the models it covers is hand `onvif_simple_server` a
PTZ profile — so leaving it would have meant advertising pan/tilt commands
over ONVIF that `ipc_cmd` cannot carry out. Home Assistant would show motor
controls that silently do nothing.

The camera has no motors. `status.json` already answered `"ptz":"no"` before
any of this was touched; the UI was the only thing pretending otherwise.

**Left alone:** the `ptz_preset)` case in
`mqtt_advertise/mqtt_set_config.sh` and the PTZ keys in
`mqtt-config/validate.c` — same reasoning as the `validate.c` entry below.

---

## Things the owner decided against

### HTTP authentication — left off, deliberately

**Proposed (Stage 3):** stop `httpd` serving unauthenticated, either by
refusing to start with an empty `USERNAME` or by generating a password on
first boot.

**Why not:** owner's call, made with the exposure spelled out. Port 80 has no
password, so anything on the LAN can reach `/cgi-bin/reset.sh` (factory
reset), `reboot.sh`, `save.sh` (rewrite any config), `speak.sh` (talk through
the speaker) and `load.sh` (read config back).

Worth knowing if that changes: upstream drives web, RTSP and ONVIF auth from
the *same* `USERNAME`/`PASSWORD` pair (`system.sh:153-162`), so switching it on
also puts credentials in front of the RTSP URL and the ONVIF integration —
Home Assistant needs updating in three places or the camera goes dark. The
`auth.patch` in `src/busybox/` makes a `path::` line mean "no auth for this
path", which is how `/onvif::` stays open, so a narrower policy that protects
only the mutating CGIs is possible if this is ever revisited.

### Dropbear compiler hardening — tried, reverted

**Proposed (Stage 3):** drop `--disable-harden` from `src/dropbear/init.dropbear`
so dropbear builds with `_FORTIFY_SOURCE=2`, `-fstack-protector-strong`, PIE,
RELRO and BIND_NOW.

**Tried it.** It *compiles* fine — the toolchain accepts every flag. The
resulting binary then dies in the module's own smoke test:

```
./_install/dropbearmulti: ELF 32-bit LSB pie executable, ARM, EABI5 ...
qemu: uncaught target signal 11 (Segmentation fault) - core dumped
```

**Why reverted:** PIE is the piece that breaks — `qemu-arm-static` cannot load
the ET_DYN executable. Whether it would also fault on the real SoC is unknown,
and there is no way to find out except flashing an SSH daemon that may not
start. Dropbear's `configure` has no switch to keep fortify and RELRO while
dropping PIE; the harden flags are one all-or-nothing block, and anything
passed in `LDFLAGS` is appended *before* its `-Wl,-pie`, so it cannot be
overridden from the outside either.

The route back in, if it is ever worth it: build with hardening, skip the qemu
test for that one module, flash, and confirm SSH on real hardware. That is a
hardware-verified answer, not a CI one. Not worth doing for a daemon that is
now refusing logins by default anyway.

`src/dropbear/qemutest.dropbear` keeps the improvement made while diagnosing
this: it prints the binary's output instead of piping it into `grep`, so the
next failure explains itself.

### `MQTT=yes` as a default — left at `no`

**Proposed (Stage 3):** default MQTT on, since HA is the point.

**Why not:** the shipped `mqttv4.conf` has `MQTT_IP=0.0.0.0`. Turning the
daemon on by default just gives every fresh install a connection-retry loop
against a broker address that cannot work. MQTT is one checkbox in the web UI
once you know your broker's IP. Enabling a daemon that is guaranteed to fail
is not a better default than leaving it off.

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

### Changed defaults do not reach a card that already has the key

`scripts/flash-sd.sh` merges `system.conf` by keeping **your** value for every
key the new build still defines. That is right for `WIFI_*`, `TZ` and
passwords, and wrong-feeling for hardening: flash a build that changes
`TELNETD=yes` → `no` onto a card that already says `yes`, and the card wins.

Not changed — silently overwriting settings on a flash is worse. Instead the
script now prints every such key as `kept your value, build default differs`,
so a default that did not take effect is visible rather than assumed. Act on
that list by hand.

### Recording thumbnails and timelapse are gone as collateral

Not a decision so much as a consequence: `thumb.sh` needed `minimp4_yi` and
`create_avi.sh` shipped from `mjpeg-avi`, both removed in Stage 2. Accepted —
neither has a Home Assistant use.

### Saving a setting still needs a reboot — the UI now says so instead

**Proposed:** make `cgi-bin/set_configs.sh` restart the affected daemon so
"Save" means "applied".

**Why not:** it is a loop of `sed -i` and nothing else. Making it reload
properly means teaching it which key belongs to which daemon and how to
restart each one without dropping the stream — a real init system, in shell,
in a CGI, on a camera. Getting it half right is worse than not doing it: a
save that kills `rRTSPServer` and fails to bring it back takes the camera off
HA until someone power-cycles it.

Instead the rewritten UI tells the truth. `app.js` treats `camera.conf` as the
one live conf — it goes through `camera_settings.sh` → `ipc_cmd`, which the
running firmware picks up immediately — and everything else (`system.conf`,
`mqttv4.conf`, `mqtt_advertise.conf`, Wi-Fi credentials) raises a sticky
banner naming the file and offering a Reboot button. No more "Saved" for a
change that has not happened.

### Config restore is capped at ~9 KB by `load.sh`

`cgi-bin/load.sh:24` does `if [ $CONTENT_LENGTH -gt 10000 ]; then exit; fi` —
no headers, no body, no error. The browser sees an empty reply and cannot tell
that apart from a crash.

Not fixed in the CGI (raising the cap means auditing its hand-rolled multipart
parser, which does `dd` arithmetic on byte offsets). The UI now refuses files
over 9000 bytes client-side with a message that names the limit, and checks
the response body for `successfully` rather than assuming HTTP 200 means it
worked. A real config tarball is well under 4 KB, so the cap is not binding in
practice — it was just silent.

### `camera.conf` is not applied at boot

It is only read by `www/cgi-bin/load.sh` (a web-UI action) and by
`mqtt-config`. `system.sh` does not apply it on startup. So editing
`camera.conf` on the card by hand does nothing until something triggers a load.
Not changed — that is upstream behaviour and rewiring it is out of scope.

### The watchdog was the load

Measured on hardware at `0.3.6`, over SSH: load average **1.19–1.22** with the
CPU **54.7% idle** and only 8 KB of swap touched. Those two numbers do not
contradict each other. This camera has **one core** (`grep -c processor
/proc/cpuinfo` = 1), and the load was not compute — it was fork churn. The
last-PID counter in `/proc/loadavg` advanced 3085 → 6214 in 420 s, i.e. **~7.4
new processes per second**. The run queue never emptied, so every new fork
queued behind the others and a shell CGI took ~0.5 s on a half-idle box.

A 400-sample `ps` sweep attributed the churn almost entirely to `wd.sh`:
`sleep 10` ×368, `top -b -n 2 -d 1` ×26, `grep rRTSPServer` ×26, `awk '{print
$8}'` ×26, `wpa_cli` ×7. The watchdog ran every 10 s, and each pass forked a
couple of dozen short-lived processes to answer questions that nothing needs
answered sub-minute.

The expensive one was `top -b -n 2 -d 1`, used purely to read one process's
CPU% column. It blocks a full second and walks all of `/proc` twice to do it.
`utime+stime` from `/proc/<pid>/stat` is the same signal — if the counter has
not moved since the previous pass, that process burned no CPU in the interval
— for three forks and no delay.

**What is not done, and why it matters:** the sleep was not left alone.
Upstream's main loop sleeps only `if [ $COUNTER -eq 0 ]`, and the reason that
was survivable is that `top` blocked for a second inside `check_rtsp` and
paced the loop by accident. Removing `top` without adding a sleep turns the
suspected-hang branch into a genuine busy-loop — a worse bug than the one
being fixed. Hence `SUSPECT_INTERVAL=5`: still catches a locked
`rRTSPServer` in under a minute, without spinning.

Two real defects surfaced while measuring, both fixed in the same pass:
`mqttv4` was running with `MQTT=no` in `system.conf` (upstream's `check_mqtt`
never consults the config before restarting it), and `camera.conf` had
`SAVE_VIDEO_ON_MOTION=yes` with `MOTION_DETECTION=no` on a build that is
supposed to record nothing.

**Not investigated further:** `rmm` sat at 34.3% CPU throughout. It is the
closed-source Yi process that owns the sensor and feeds the frame buffer
everything else reads, so it is not removable and not tunable from here. It is
the floor for this hardware, not a regression.

### The "1 fps in Home Assistant" was not the camera

Recorded because it cost a session to chase. The stream was measured straight
off the device: **391 frames in 20.008 s = 19.5 fps**, keyframe gaps 2.00–2.05 s
(GOP 40), 2304×1296, 1.17 Mbps — exactly what HA's HLS segmenter wants. A 60 s
capture of connections from the HA host returned nothing at all: HA held no
connection to the camera while the dashboard was open.

Cause: a `picture-entity` / `picture-glance` tile defaults to `camera_view:
auto`, which renders a **still image refreshed every ~10 s**, not video. Live
video starts only when the tile is clicked. Nothing on the camera was wrong,
and no firmware change fixes it. The fix is one line of HA config:

```yaml
type: picture-entity
entity: camera.yi_52f6
camera_view: live      # default is "auto" = still image
```

For a genuinely realtime tile, `custom:webrtc-camera` with `mode: webrtc`
passes the H.264 through without transcoding.
