# yi-hack-Allwinner-v2 — y623, Home Assistant only

A fork of [roleoroleo/yi-hack-Allwinner-v2](https://github.com/roleoroleo/yi-hack-Allwinner-v2)
stripped down to **one camera model (y623, "Yi Pro 2K Home")** used as a
**stream-only source for Home Assistant**.

Everything that does not serve that goal has been removed: FTP, timelapse,
recording playback, the on-camera MQTT broker, the alternative RTSP daemons,
micropython, proxychains. What survives exists to get one clean H.264 stream,
ONVIF discovery, MQTT events and two-way audio into HA.

> **Wrong camera?** This build packs `y623` only and the other 19 models have
> been deleted from `sysroot/`, `sdhack/` and `unbrick/`. If your camera is not
> a y623 on firmware `12.0.51*` with an `RFUS` / `YFUS` / `ZFUS` serial, use
> [upstream](https://github.com/roleoroleo/yi-hack-Allwinner-v2) instead.

Read [NOT-DONE.md](NOT-DONE.md) before proposing a cut. It records what was
deliberately *not* removed and why — several obvious-looking cuts turn out to
break things, and a few are impossible in the first place.

---

## Contents

- [Security defaults that differ from upstream](#security-defaults-that-differ-from-upstream)
- [What is still here](#what-is-still-here)
- [What was removed](#what-was-removed)
- [Home Assistant setup](#home-assistant-setup)
- [What you cannot change from here](#what-you-cannot-change-from-here)
- [Install and flash](#install-and-flash)
- [Verify a running camera](#verify-a-running-camera)
- [Build](#build)
- [Recovery](#recovery)
- [Upstream, license, credit](#upstream-license-credit)

---

## Security defaults that differ from upstream

| Key / setting | Upstream | Here | Why |
|---|---|---|---|
| `TELNETD` | `yes` | `no` | Plaintext root shell on port 23, on by default. Nothing needs it; dropbear covers shell access. |
| `DISABLE_CLOUD` | `no` | `yes` | Stops the Yi cloud phone-home (`p2p_tnp`, `oss*`, `rtmp`) and installs the hosts/route blacklist. `rmm` and `start_buffer` still run, so the stream is unaffected. |
| `dropbear` flags | `-R -B -p 0.0.0.0:22` | `-R -p 0.0.0.0:22` | `-B` is dropbear's *allow blank password logins*. With `SSH_PASSWORD` empty by default, upstream ships **root SSH with no password on the LAN**. |

Two consequences worth knowing before you flash:

**SSH refuses every login until you set a password.** Removing `-B` means an
empty `SSH_PASSWORD` no longer means "let anyone in", it means "let nobody in".
Set `SSH_PASSWORD` in `yi-hack/etc/system.conf` on the card (or in the web UI)
if you want a shell. `system.sh` logs a line saying so at boot rather than
letting it look like sshd is broken.

**HTTP is still unauthenticated, on purpose.** `USERNAME` and `PASSWORD` are
empty, so `/tmp/httpd.conf` is never written and port 80 has no password —
anything on the LAN can reach `/cgi-bin/reset.sh`, `reboot.sh`, `save.sh`,
`speak.sh` and `load.sh`. That is a deliberate owner decision, documented with
its reasoning in [NOT-DONE.md](NOT-DONE.md#http-authentication--left-off-deliberately).
Put the camera on a VLAN that only Home Assistant can reach.

Setting `USERNAME`/`PASSWORD` closes it — but note upstream drives web, RTSP
*and* ONVIF auth from the same pair (`system.sh:153-162`), so switching it on
means updating Home Assistant in three places or the camera goes dark.

---

## What is still here

| Component | Role |
|---|---|
| `rRTSPServer` + `h264grabber` | The stream. `rtsp://<ip>:554/ch0_0.h264` |
| `onvif_simple_server` | ONVIF device/media/PTZ/events + WS-Discovery — how HA and Frigate find the camera |
| `snapshot` (`imggrabber`) | JPEG stills for the ONVIF snapurl and HA camera entities |
| `mqtt` / `mqttv4` / `mqtt-config` / wolfSSL | MQTT auto-discovery and event publishing. **This is the HA integration.** |
| `ipc_cmd` | IR / status LED / PTZ / detection toggles, surfaced as HA switches |
| `alsa-lib` + `speaker` + `pcmvol` | Two-way audio and TTS from HA |
| `www` + `proccgi` + `jq` | Config UI. Cannot be removed — ONVIF's snapurl points at `cgi-bin/snapshot.sh`. |
| `busybox` | httpd, ntpd, crond, coreutils |
| `dropbear` | SSH |
| `mdnsd`, `set_tz_offset`, `static` | Discovery, timezone, all config and boot scripts |

## What was removed

- **19 camera models** — `sysroot/`, `sdhack/`, `unbrick/`, and the `CAMERAS`
  array in `scripts/common.sh`
- **FTP entirely** — pure-ftpd, busybox `ftpd`/`ftpget`/`ftpput`/`tcpsvd`,
  `ftppush.sh`, all `FTP_*` keys. Port 21 is closed by construction, not by
  config.
- **`sftp-server`** — pulled the whole `openssh-portable` submodule to fetch
  recordings that no longer exist. `DROPBEAR_SFTPSERVER 0` in `localoptions.h`.
- **Recording playback** — the `eventsdir`/`eventsfile` pages, their modules,
  4 CGIs, `getlastrecordedvideo.sh`, and the `/tmp/sd/record` → `www/record`
  bind mount (which was an unauthenticated read of the whole card over HTTP).
- **Timelapse** — `minimp4`, `mjpeg-avi`, `create_avi.sh`. Recording thumbnails
  went with them (`thumb.sh` needed `minimp4_yi`).
- **`go2rtc`** — redundant. Home Assistant has shipped its own since 2024.11.
- **`rtsp_server_yi`** — alternative RTSP daemon, unused at `RTSP_ALT=standard`.
- **`mosquitto`** — on-camera broker. HA owns the broker.
- **`micropython`** — no consumers anywhere in `src/static` or `src/www`.
- **`proxychains-ng`** — disabled by default; a cloud-region-lock workaround.

Six of nine git submodules are gone, which is most of the clone time.

---

## Home Assistant setup

### Stream

Point HA's built-in go2rtc straight at the camera. Do **not** put ffmpeg or a
transcode in front of it — the whole point is that nothing re-encodes.

```yaml
# configuration.yaml
go2rtc:
  streams:
    yi_pro_2k: rtsp://192.168.1.20:554/ch0_0.h264#backchannel=0
```

`#backchannel=0` stops go2rtc negotiating the ONVIF backchannel on the view
stream. Leave it off unless you actually want two-way audio on that stream, in
which case add a second entry without the flag.

**Use WebRTC, not HLS, for the live card.** That is the difference between
~2 s and sub-second latency, and it dwarfs anything you can change on the
camera side.

Available URLs:

| URL | Contents |
|---|---|
| `rtsp://<ip>:554/ch0_0.h264` | high res, video + audio |
| `rtsp://<ip>:554/ch0_1.h264` | low res |
| `rtsp://<ip>:554/ch0_2.h264` | audio only |

### Audio

`RTSP_AUDIO` is set to `aac` here, not upstream's `yes`. Upstream's `yes` maps
to `convertTo = WA_PCMU` (`rRTSPServer.cpp:1137`), meaning the camera decodes
the AAC its own encoder produced and re-encodes it to G.711 on every frame.
`aac` is passthrough: less CPU on the camera, and one fewer transcode in HA,
which takes AAC natively.

### Snapshots

```
http://<ip>/cgi-bin/snapshot.sh                        high res, no watermark
http://<ip>/cgi-bin/snapshot.sh?res=low&watermark=yes
```

Snapshots are memory-hungry on this SoC. Don't poll them on a short interval.

### ONVIF

Endpoint `http://<ip>/onvif/device_service`, port 80. Discovery, PTZ and
motion events all work. Auth is off (see above), so leave user/password empty
in the HA ONVIF integration and in Frigate.

### MQTT

`MQTT` is left at `no` by default — the shipped `mqttv4.conf` has
`MQTT_IP=0.0.0.0`, so enabling it out of the box just gives you a retry loop.
Set your broker's IP in the web UI's MQTT page, *then* turn MQTT on. Entities
appear in HA via auto-discovery.

### Speak / TTS

```yaml
rest_command:
  camera_announce:
    url: http://192.168.1.20/cgi-bin/speak.sh?lang={{language}}&voldb={{volume}}
    method: POST
    payload: "{{message}}"
```

Requires the `nanotts` optional utility on the camera
([yi-hack-utils](https://github.com/roleoroleo/yi-hack-utils)).

---

## What you cannot change from here

`rRTSPServer` **does not encode.** Its entire CLI is `-m -r -a -b -p -s -u -w -d`
(`rRTSPServer.cpp:957-976`) — no bitrate, no framerate, no keyframe interval.
It relays H.264 that the *stock Yi firmware* encoder has already written to
shared memory.

**No change in this repository can raise stream quality.** Encoder settings
live in the stock firmware, reachable only through `camera.conf`, `ipc_cmd` or
the Yi app. "Faster" in this project means freeing the SoC — fewer daemons,
fewer SD writes, no needless transcode — not tuning the encoder.

Free RAM on this build is ~12.3 MB of 59.5 MB at 5 min uptime, against
10.9 MB on the unmodified hack. `SWAP_FILE=yes` stays on: swapping to SD is
slow, but a `h264grabber` killed by the OOM reaper is slower.

---

## Install and flash

The card is the firmware — this hack runs entirely from the microSD and the
camera's NAND is never written. The card is dedicated to the camera; don't
also use it for storage.

**First install**, on a freshly FAT32-formatted card (format it in the camera
if you can):

1. Download the newest `y623_*.tgz` from Actions, or build one (below).
2. Extract it to the root of the card. The result must look like:
   ```
   |-- Factory/
   |-- yi-hack/
   |-- lower_half_init.sh
   ```
3. Optional: `cp Factory/configure_wifi.cfg.ori Factory/configure_wifi.cfg` and
   put your SSID and PSK in it.
4. Insert the card, power on, wait ~60 s, open `http://<ip>`.

**Every flash after that**, use the script — never Finder, never Archive
Utility. A Finder copy of the payload bricked this camera once by silently
producing a partial tree, after which `lower_half_init.sh` ran nothing.

```bash
scripts/flash-sd.sh                        # newest successful CI build
scripts/flash-sd.sh --run <id>             # a specific workflow run
scripts/flash-sd.sh --tgz path/to.tgz      # a local build
scripts/flash-sd.sh --volume /Volumes/X    # pick the card explicitly
scripts/flash-sd.sh --yes                  # no confirmation prompt
```

It backs the card up to `~/yihack-backups/` first, wipes the old `yi-hack`
tree, extracts the new one, and carries your settings across.

> **Your `system.conf` wins over new defaults.** The script *merges* rather
> than copies: for every key the new build still defines, **your card's value
> is kept**. Right for `WIFI_*`, `TZ` and passwords — surprising for hardening.
> Flash a build that changes `TELNETD=yes` → `no` onto a card that already says
> `yes` and the card wins.
>
> The script prints every such key:
>
> ```
>     kept your value, build default differs:
>       TELNETD=yes   build default: no
>       RTSP_AUDIO=yes   build default: aac
> ```
>
> **Act on that list by hand** — edit `yi-hack/etc/system.conf` on the card, or
> change it in the web UI. Nothing else will apply those defaults for you.
> More on this in [NOT-DONE.md](NOT-DONE.md#changed-defaults-do-not-reach-a-card-that-already-has-the-key).

## Verify a running camera

```bash
scripts/flash-sd.sh --verify 192.168.1.20
```

Checks `status.json`, the snapshot CGI, the ONVIF endpoint, and probes the
RTSP stream with `ffprobe` if you have it (`brew install ffmpeg`). It touches
no card and flashes nothing.

```
==> Checking camera at 192.168.1.20
  status.json  OK
    "fw_version": "0.3.6", "model_suffix": "y623", ...
  snapshot     OK (74213 bytes)
  onvif        OK
  rtsp         OK (h264,2304,1296)
==> All checks passed.
```

After a hardening flash also confirm, by hand: `ssh` is refused (or accepts
your new password), `telnet <ip>` is refused, and `netstat -tlnp` on the camera
shows no listener you did not expect.

## Build

**Via GitHub Actions** (easiest, free on public repos, ~7-8 min):

Push to `y623-ha`, or trigger the workflow manually — `.github/workflows/build.yaml`
has `workflow_dispatch`. It runs `scripts/compile.sh` then `scripts/pack_fw.sh y623`
and uploads the `.tgz` as the `build` artifact. `scripts/flash-sd.sh` downloads
it for you.

**Locally**, if you'd rather not wait on CI:

```bash
colima start --vm-type=vz --vz-rosetta --cpu 4 --memory 8 --disk 60
scripts/build-local.sh
```

`build-local.sh` builds the `Dockerfile` (the same toolchain image CI uses) and
runs the compile inside it. Colima with `vz` + Rosetta is what makes the
`x86_64` toolchain usable at a reasonable speed on Apple silicon.

## Recovery

There is no brick this hack can cause that pulling the card does not fix. The
camera reverts to stock firmware the moment the card is absent or the payload
is unreadable.

To fix a bad config without reflashing, mount the card and edit
`yi-hack/etc/system.conf` directly. To roll a stage back, reflash the previous
`.tgz` you kept — `scripts/flash-sd.sh --tgz <path>`.

If the camera won't start even with the card removed, that is a genuine brick
and unrelated to this repo:
[Unbrick the cam](https://github.com/roleoroleo/yi-hack-Allwinner-v2/wiki/Unbrick-the-cam).

## Upstream, license, credit

Sync procedure and the list of files that will conflict: [UPSTREAM.md](UPSTREAM.md).

All of the hard work here is [roleoroleo](https://github.com/roleoroleo)'s, plus
the contributors to yi-hack-MStar and yi-hack-v4 whose work it builds on. This
fork only deletes things. If you find it useful, go
[buy roleo a beer](https://www.paypal.com/cgi-bin/webscr?cmd=_donations&business=JBYXDMR24FW7U&currency_code=EUR&source=url).

[MIT](LICENSE), same as upstream.

**NOBODY BUT YOU IS RESPONSIBLE FOR ANY USE OR DAMAGE THIS SOFTWARE MAY CAUSE.
THIS IS INTENDED FOR EDUCATIONAL PURPOSES ONLY. USE AT YOUR OWN RISK.**
