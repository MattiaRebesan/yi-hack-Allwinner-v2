# Staying in sync with upstream

Upstream is [roleoroleo/yi-hack-Allwinner-v2](https://github.com/roleoroleo/yi-hack-Allwinner-v2).
This fork lives on the `y623-ha` branch of
[MattiaRebesan/yi-hack-Allwinner-v2](https://github.com/MattiaRebesan/yi-hack-Allwinner-v2).

```
origin    MattiaRebesan/yi-hack-Allwinner-v2   (this fork)
upstream  roleoroleo/yi-hack-Allwinner-v2      (read-only in practice)
```

If `upstream` is missing after a fresh clone:

```bash
git remote add upstream https://github.com/roleoroleo/yi-hack-Allwinner-v2.git
```

## The procedure

```bash
git fetch upstream
git checkout y623-ha
git merge upstream/master
# resolve (see below), then:
git submodule update --init
scripts/build-local.sh          # or push and let Actions build it
```

Push only after the build is green. Then flash and re-run
`scripts/flash-sd.sh --verify <ip>` — a merge can reintroduce a daemon or a
default without any compile error at all.

## Conflicts are expected, not a sign something went wrong

This fork deletes ~10,000 lines. Any upstream commit that touches deleted
files produces a conflict. Two kinds:

**Deleted-by-us conflicts.** Upstream edits a file this fork removed — a model
directory, `src/go2rtc`, an events page. Resolve with `git rm`, always. Never
take the upstream side unless you are deliberately reinstating the feature.

```bash
git status --short | grep '^DU'      # deleted by us, modified by them
git rm <path>
```

**Content conflicts** in files that both sides edit. These need judgement.
The full current list:

| File | What this fork changed | On conflict |
|---|---|---|
| `scripts/common.sh` | `CAMERAS` reduced to `y623` | Keep ours. Never re-add models. |
| `.github/workflows/build.yaml` | `pack_fw.all.sh` → `pack_fw.sh y623`; added `workflow_dispatch` | Keep ours; take any upstream toolchain/runner fixes. |
| `.gitmodules` | 6 submodule entries removed | Keep ours. |
| `src/static/static/yi-hack/etc/system.conf` | `TELNETD=no`, `DISABLE_CLOUD=yes`, `RTSP_AUDIO=aac`, `FREE_SPACE=15`; all `FTP_*` and `EVENTS_TIME` gone | Keep our values. Add any genuinely new upstream key, then mirror it into `check_conf.sh`. |
| `src/static/static/yi-hack/script/check_conf.sh` | Must list exactly the keys `system.conf` defines | **Always resolve in lockstep with `system.conf`.** A key in one and not the other is a real bug. |
| `src/static/static/yi-hack/script/system.sh` | dropbear `-B` removed; empty-`SSH_PASSWORD` warning; **second-phase firmware-upgrade block and `YI_HACK_UPGRADE_PATH` removed** | Keep ours. Re-check the dropbear line by eye after every merge — it is the single most important diff in the fork. Never let the `/tmp/sd/.fw_upgrade` block back in; see [NOT-DONE.md](NOT-DONE.md#online-firmware-upgrade--removed-as-a-security-fix). |
| `src/static/static/yi-hack/script/service.sh` | Dead `RTSP_ALT` branches for `alternative`/`go2rtc` removed; **the whole PTZ block removed** | Keep ours. The PTZ block was gated on ten model suffixes, none of them `y623` — reinstating it advertises pan/tilt over ONVIF that the hardware cannot perform. |
| `src/static/static/yi-hack/script/wd.sh` | Watchdog no longer watches removed daemons. **Also rewritten for fork cost on a single-core CPU:** `top -b -n 2 -d 1` in `check_rtsp` replaced by `utime+stime` from `/proc/<pid>/stat`; `INTERVAL` 10 → 30; the suspected-hang branch now sleeps `SUSPECT_INTERVAL=5` instead of not sleeping at all; `check_mqtt` returns early unless `MQTT=yes`; `check_wifi` tries `ifconfig` before `wpa_cli`; single `netstat` counted twice; `grep\|grep\|grep` chains collapsed into one `awk`. | Keep ours; add upstream's new entries only for daemons that still exist here. **Four of these are not cosmetic and must not be merged away:** (1) the blocking `top` cost more CPU than anything it watched — see [NOT-DONE.md](NOT-DONE.md#the-watchdog-was-the-load); (2) upstream's loop only sleeps when `COUNTER -eq 0` and got away with it *because* `top` blocked for a second — restoring `top` without the sleep, or removing the sleep without `top`, gives a busy-loop either way; (3) upstream's `check_mqtt` restarts `mqttv4` whether or not MQTT is enabled, which resurrects a daemon the config says is off; (4) `pidof` is not in this busybox (`CONFIG_PIDOF` is unset), so PID lookup must stay `ps` + `awk`. |
| `src/dropbear/localoptions.h` | `DROPBEAR_SFTPSERVER 0` instead of `SFTPSERVER_PATH` | Keep ours — the binary is not on the card. |
| `src/dropbear/init.dropbear` | `--disable-harden` **kept** (upstream default) | Deliberate; see [NOT-DONE.md](NOT-DONE.md#dropbear-compiler-hardening--tried-reverted). Don't "fix" it. |
| `src/dropbear/qemutest.dropbear` | Prints the binary's output instead of piping into `grep` | Keep ours — it is a diagnostic improvement, worth upstreaming. |
| `src/busybox/.config` | `ftpd` / `ftpget` / `ftpput` / `tcpsvd` applets switched off | Keep ours. (`telnetd` was already off upstream — the telnet daemon on the camera is the stock one, gated by `TELNETD` in `system.conf`.) |
| `src/busybox/install.busybox` | Stubs for those applets removed | Keep ours, and check any new stub name against `CONFIG_<NAME>=y` in `.config` — a stub for a disabled applet is a 30-byte file pointing at nothing. |
| `src/www/httpd/**` | **Front-end rewritten from scratch.** jQuery, the `?page=` router, `js/utils.js`, all 13 `js/modules/*.js` and all 13 `htdocs/pages/*.html` are gone, replaced by one `index.html` with five `<section>` views plus `js/dom.js` + `js/app.js` (vanilla ES5). `cgi-bin/ptz.sh`, `preset.sh`, `fw_upgrade.sh` and `hostname.js` deleted; `status.json`, `camera_settings.sh` and `load.sh` pruned of PTZ. | **Always keep ours, wholesale.** There is no meaningful three-way merge between this and upstream's SPA — take upstream's file only if you are deliberately reverting the rewrite. New upstream *CGI* endpoints can be cherry-picked; new upstream *pages* cannot. |
| `src/onvif_simple_server/init.onvif_simple_server` | Build tweak | Take upstream unless it breaks the build. |
| `src/static/static/yi-hack/bin/cloudAPI` | Local change | Inspect; usually keep ours. |

Fork-only files, which never conflict: `NOT-DONE.md`, `UPSTREAM.md`,
`Dockerfile`, `scripts/build-local.sh`, `scripts/flash-sd.sh`.

## After the merge, before you trust it

```bash
grep -n 'dropbear -R' src/static/static/yi-hack/script/system.sh
grep -nE '^(TELNETD|DISABLE_CLOUD|RTSP_AUDIO|FREE_SPACE)=' \
     src/static/static/yi-hack/etc/system.conf
grep -rn 'fw_upgrade\|jquery\|pages/' src/www src/static/static/yi-hack/script
```

Expect `dropbear -R -p 0.0.0.0:22` with no `-B`, and `no` / `yes` / `aac` / `15`.
A merge that quietly restores `-B` gives you blank-password root SSH again and
nothing will complain. The third grep must return nothing but comments — a hit
in live code means the merge dragged the old front-end or the self-updater back.

Then diff the key sets, which is the failure mode `check_conf.sh` cannot catch
by itself:

```bash
diff <(grep -oE '^[A-Z_0-9]+=' src/static/static/yi-hack/etc/system.conf | sort -u) \
     <(grep -oE '^[A-Z_0-9]+=' src/static/static/yi-hack/script/check_conf.sh | sort -u)
```

## Why the divergence is worth it

Every merge costs some manual resolution. The alternative is carrying 19 unused
camera models, an FTP server, a blank-password SSH default and a cloud
phone-home forever. That trade was made deliberately; see
[NOT-DONE.md](NOT-DONE.md) for the parts of it that were reconsidered and kept.
