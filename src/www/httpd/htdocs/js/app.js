/*
 * yi-hack web UI.
 *
 * One document, five views, no framework. Every CGI endpoint it talks to is
 * unchanged from upstream; only the front-end was rewritten.
 *
 * ES5 only - see the note in dom.js.
 */

var VIEWS = ['status', 'stream', 'camera', 'ha', 'system'];

/*
 * set_configs.sh is a loop of `sed -i` over the conf file and nothing else:
 * no daemon is signalled, no service is reloaded. Anything written through it
 * therefore takes effect at the next boot, and the UI has to say so.
 * camera.conf is the exception - camera_settings.sh drives ipc_cmd, which the
 * running firmware picks up straight away.
 */
var LIVE_CONF = 'camera';

/* camera_settings.sh reads its arguments positionally. Order matters. */
var CAM_ORDER = [
    'SAVE_VIDEO_ON_MOTION', 'MOTION_DETECTION', 'SENSITIVITY',
    'AI_HUMAN_DETECTION', 'AI_VEHICLE_DETECTION', 'AI_ANIMAL_DETECTION',
    'FACE_DETECTION', 'MOTION_TRACKING', 'SOUND_DETECTION',
    'SOUND_SENSITIVITY', 'LED', 'IR', 'ROTATE', 'SWITCH_ON'
];

var AI_KEYS = ['AI_HUMAN_DETECTION', 'AI_VEHICLE_DETECTION', 'AI_ANIMAL_DETECTION'];

var loadedConf = {};
var statusTimer = null;
var linksDone = false;
var tzMap = null;

/* --------------------------------------------------------------- chrome */

function toast(msg, bad) {
    var el = $('#toast');
    el.textContent = msg;
    el.className = bad ? 'bad' : '';
    el.hidden = false;
    clearTimeout(el.timer);
    el.timer = setTimeout(function () { el.hidden = true; }, 4000);
}

function fail(e) {
    toast(e && e.message ? e.message : 'Request failed', true);
}

function needsReboot(what) {
    text('#banner-text', what + ' written to the camera. Nothing re-reads it until a reboot.');
    $('#banner-reboot').hidden = false;
    show($('#banner'), true);
}

function applyTheme(t) {
    document.documentElement.setAttribute('data-theme', t);
    try { localStorage.setItem('theme', t); } catch (e) { /* private mode */ }
}

/* ---------------------------------------------------------------- forms */

function setControl(el, value) {
    if (el.type === 'checkbox') {
        el.checked = (value === 'yes');
    } else if (el.tagName === 'TEXTAREA') {
        el.value = String(value).replace(/\t/g, '\n');
    } else {
        el.value = value;
    }
}

function readControl(el) {
    if (el.type === 'checkbox') {
        return el.checked ? 'yes' : 'no';
    }
    return el.value;
}

function fillConf(conf, data) {
    $$('[data-conf="' + conf + '"] [data-key]').forEach(function (el) {
        var k = el.getAttribute('data-key');
        if (data[k] !== undefined) {
            setControl(el, data[k]);
        }
    });
}

function loadConf(conf) {
    if (loadedConf[conf]) {
        return Promise.resolve(null);
    }
    return getJSON('cgi-bin/get_configs.sh?conf=' + conf).then(function (data) {
        loadedConf[conf] = true;
        fillConf(conf, data);
        return data;
    });
}

function confLabel(conf) {
    if (conf === 'system') { return 'system.conf'; }
    if (conf === 'mqtt') { return 'mqttv4.conf'; }
    return conf + '.conf';
}

function saveView(view) {
    var groups = {};
    $$('#view-' + view + ' [data-conf]').forEach(function (card) {
        var conf = card.getAttribute('data-conf');
        var bag = groups[conf] || (groups[conf] = {});
        $$('[data-key]', card).forEach(function (el) {
            bag[el.getAttribute('data-key')] = readControl(el);
        });
    });

    var names = Object.keys(groups);
    var pending = names.map(function (conf) {
        return conf === LIVE_CONF
            ? saveCamera(groups[conf])
            : postJSON('cgi-bin/set_configs.sh?conf=' + conf, groups[conf]);
    });

    return Promise.all(pending).then(function () {
        var stored = names.filter(function (c) { return c !== LIVE_CONF; });
        if (stored.length) {
            needsReboot(stored.length > 1 ? 'Settings' : confLabel(stored[0]));
        } else {
            toast('Applied');
        }
    })['catch'](fail);
}

/* --------------------------------------------------------------- router */

function route() {
    var name = location.hash.replace('#', '');
    if (VIEWS.indexOf(name) < 0) {
        name = 'status';
    }
    VIEWS.forEach(function (v) {
        show($('#view-' + v), v === name);
    });
    $$('#nav a').forEach(function (a) {
        a.className = a.getAttribute('href') === '#' + name ? 'on' : '';
    });

    if (name === 'status') {
        startStatus();
    } else {
        stopStatus();
    }
    if (name === 'stream') {
        loadConf('system')['catch'](fail);
    }
    if (name === 'camera') {
        loadCamera();
    }
    if (name === 'ha') {
        loadConf('system')['catch'](fail);
        loadConf('mqtt')['catch'](fail);
        loadConf('mqtt_advertise')['catch'](fail);
    }
    if (name === 'system') {
        loadConf('system')['catch'](fail);
        loadTz();
    }
}

/* --------------------------------------------------------------- status */

function startStatus() {
    refreshStatus();
    if (!linksDone) {
        refreshLinks();
    }
    if (!statusTimer) {
        statusTimer = setInterval(function () {
            if (!document.hidden) {
                refreshStatus();
            }
        }, 10000);
    }
}

function stopStatus() {
    if (statusTimer) {
        clearInterval(statusTimer);
        statusTimer = null;
    }
}

function refreshStatus() {
    getJSON('cgi-bin/status.json').then(function (s) {
        var host = s.hostname || 'yi-hack';
        text('#dev-name', host);
        document.title = host;
        text('#s-hostname', s.hostname);
        text('#s-fw', s.fw_version);
        text('#s-home', s.home_version);
        text('#s-model', s.model_suffix);
        text('#s-serial', s.serial_number);
        text('#s-time', s.local_time);
        text('#s-uptime', fmtUptime(s.uptime));
        text('#s-load', s.load_avg);
        text('#s-mem', fmtKB(s.free_memory) + ' of ' + fmtKB(s.total_memory));
        /* status.json reports free SD as an already-formatted percentage. */
        text('#s-sd', s.free_sd);
        text('#s-ip', s.local_ip);
        text('#s-mask', s.netmask);
        text('#s-gw', s.gateway);
        text('#s-mac', s.mac_addr);
        text('#s-wifi', s.wlan_essid ? s.wlan_essid + ' (' + s.wlan_strength + ')' : '-');
    })['catch'](fail);
}

function refreshLinks() {
    getJSON('cgi-bin/links.sh').then(function (l) {
        linksDone = true;
        text('#u-high', l.high_res_stream || '-');
        text('#u-low', l.low_res_stream || '-');
        text('#u-audio', l.audio_stream || '-');
        text('#u-onvif', location.protocol + '//' + location.host + '/onvif/device_service');
        if (l.high_res_snapshot) { $('#u-snap-high').href = l.high_res_snapshot; }
        if (l.low_res_snapshot) { $('#u-snap-low').href = l.low_res_snapshot; }
        buildGo2rtc(l);
    })['catch'](fail);
}

function buildGo2rtc(l) {
    var name = ($('#s-hostname').textContent || 'yi_camera').replace(/[^A-Za-z0-9_]/g, '_');
    var lines = ['streams:'];
    if (l.high_res_stream) {
        lines.push('  ' + name + ':');
        lines.push('    - ' + l.high_res_stream);
    }
    if (l.low_res_stream) {
        lines.push('  ' + name + '_sub:');
        lines.push('    - ' + l.low_res_stream);
    }
    text('#go2rtc', lines.length > 1 ? lines.join('\n') : 'RTSP is off - enable it on the Stream view.');
}

function takeSnapshot() {
    var img = $('#snap');
    fetch('cgi-bin/snapshot.sh?res=high&watermark=yes&base64=yes', { cache: 'no-store' })
        .then(function (r) { return r.text(); })
        .then(function (b64) {
            img.src = 'data:image/jpeg;base64,' + b64;
            img.hidden = false;
        })['catch'](fail);
}

/* --------------------------------------------------------------- camera */

function loadCamera() {
    loadConf('camera').then(function (data) {
        if (!data) {
            return;
        }
        /*
         * Base firmware 11.x and 12.x expose motion detection plus three AI
         * detectors; anything older exposes face detection and tracking
         * instead. Showing the wrong set means switches that write nowhere.
         */
        var hv = String(data.HOMEVER || '').substring(0, 2);
        var fw12 = (hv === '11' || hv === '12');
        $$('.fw12').forEach(function (el) { el.hidden = !fw12; });
        $$('.no-fw12').forEach(function (el) { el.hidden = fw12; });
    })['catch'](fail);
}

/* Motion detection and the AI detectors are mutually exclusive downstream. */
function syncDetection(changed) {
    if (changed === 'MOTION_DETECTION') {
        if ($('#k-MOTION_DETECTION').checked) {
            AI_KEYS.forEach(function (k) { $('#k-' + k).checked = false; });
        }
    } else if (AI_KEYS.indexOf(changed) >= 0 && $('#k-' + changed).checked) {
        $('#k-MOTION_DETECTION').checked = false;
    }
}

function saveCamera(values) {
    var qs = CAM_ORDER.map(function (k) {
        var v = values[k] === undefined ? 'no' : values[k];
        return k.toLowerCase() + '=' + encodeURIComponent(v);
    }).join('&');
    return getJSON('cgi-bin/camera_settings.sh?' + qs).then(function (r) {
        if (r && r.error === 'true') {
            throw new Error('The camera rejected those settings');
        }
    });
}

/* -------------------------------------------------------------- speaker */

function fillVolumes() {
    $$('select.vol').forEach(function (sel) {
        var html = '';
        for (var db = 12; db >= -12; db -= 2) {
            html += '<option value="' + db + '"' + (db === 0 ? ' selected' : '') + '>' +
                (db > 0 ? '+' : '') + db + ' dB</option>';
        }
        sel.innerHTML = html;
    });
}

function speak() {
    var t = $('#tts-text').value;
    if (!t) {
        toast('Nothing to say', true);
        return;
    }
    fetch('cgi-bin/speak.sh?lang=' + encodeURIComponent($('#tts-lang').value) +
          '&voldb=' + encodeURIComponent($('#tts-vol').value),
          { method: 'POST', body: t })
        .then(function () { toast('Sent to the speaker'); })
        ['catch'](fail);
}

function playWav() {
    var f = $('#wav-file').files[0];
    if (!f) {
        toast('Pick a WAV file first', true);
        return;
    }
    var fd = new FormData();
    fd.append('file', f);
    fetch('cgi-bin/speaker.sh?voldb=' + encodeURIComponent($('#wav-vol').value),
          { method: 'POST', body: fd })
        .then(function () { toast('Sent to the speaker'); })
        ['catch'](fail);
}

/* ----------------------------------------------------------------- wifi */

function escapeHTML(s) {
    return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

function scanWifi() {
    var sel = $('#wifi-list');
    sel.innerHTML = '<option value="">scanning...</option>';
    getJSON('cgi-bin/wifi.sh?action=scan').then(function (d) {
        var html = '';
        /* wifi.sh closes its array with an empty string. Skip it. */
        (d.wifi || []).forEach(function (essid) {
            if (essid) {
                html += '<option>' + escapeHTML(essid) + '</option>';
            }
        });
        sel.innerHTML = html + '<option value="__other">Other...</option>';
        toggleWifiManual();
    })['catch'](fail);
}

function toggleWifiManual() {
    show($('#wifi-manual-row'), $('#wifi-list').value === '__other');
}

function saveWifi() {
    var essid = $('#wifi-list').value === '__other' ? $('#wifi-manual').value : $('#wifi-list').value;
    var pw = $('#wifi-pw').value;
    if (!essid) {
        toast('Pick a network first', true);
        return;
    }
    if (!pw) {
        toast('The password is blank', true);
        return;
    }
    if (pw !== $('#wifi-pw2').value) {
        toast('The two passwords do not match', true);
        return;
    }
    postJSON('cgi-bin/wifi.sh?action=save',
             { WIFI_ESSID: essid, WIFI_PASSWORD: pw, WIFI_PASSWORD2: $('#wifi-pw2').value })
        .then(function (r) {
            if (!r || r.error !== 'false') {
                throw new Error('The camera refused those Wi-Fi settings');
            }
            needsReboot('Wi-Fi credentials');
        })['catch'](fail);
}

/* ---------------------------------------------------------- maintenance */

function backup() {
    fetch('cgi-bin/save.sh').then(function (r) {
        return r.blob();
    }).then(function (b) {
        var url = URL.createObjectURL(b);
        var a = document.createElement('a');
        a.href = url;
        a.download = 'config.tar.bz2';
        document.body.appendChild(a);
        a.click();
        document.body.removeChild(a);
        URL.revokeObjectURL(url);
    })['catch'](fail);
}

function restore() {
    var f = $('#restore-file').files[0];
    if (!f) {
        toast('Pick a backup file first', true);
        return;
    }
    /*
     * load.sh bails out with no output at all above CONTENT_LENGTH 10000, so
     * without this the browser just sees an empty reply and no explanation.
     */
    if (f.size > 9000) {
        toast('That file is too large for load.sh (limit is roughly 9 KB)', true);
        return;
    }
    var fd = new FormData();
    fd.append('files[]', f);
    fetch('cgi-bin/load.sh', { method: 'POST', body: fd }).then(function (r) {
        return r.text();
    }).then(function (body) {
        /* load.sh answers 200 with plain text either way. */
        if (body.indexOf('successfully') < 0) {
            throw new Error('The camera could not unpack that backup');
        }
        needsReboot('The backup');
    })['catch'](fail);
}

function waitForCamera() {
    text('#banner-text', 'Rebooting. This page reloads once the camera answers again.');
    $('#banner-reboot').hidden = true;
    show($('#banner'), true);
    setInterval(function () {
        fetch('index.html', { cache: 'no-store' }).then(function () {
            location.reload();
        })['catch'](function () { /* still down */ });
    }, 5000);
}

function reboot() {
    if (!confirm('Reboot the camera now? The stream drops for about a minute.')) {
        return;
    }
    /* The connection dies with the daemon, so a rejected fetch is expected. */
    fetch('cgi-bin/reboot.sh')['catch'](function () { });
    waitForCamera();
}

function factoryReset() {
    if (!confirm('Reset every yi-hack setting to its default, Wi-Fi credentials included?')) {
        return;
    }
    fetch('cgi-bin/reset.sh')['catch'](function () { });
    waitForCamera();
}

/* ------------------------------------------------------------- timezone */

function loadTz() {
    if (tzMap) {
        return;
    }
    fetch('tz.json').then(function (r) {
        return r.json();
    }).then(function (m) {
        tzMap = m;
        var html = '';
        Object.keys(m).forEach(function (loc) {
            html += '<option value="' + escapeHTML(loc) + '"></option>';
        });
        $('#tz-list').innerHTML = html;
    })['catch'](function () { /* the TZ string field still works by hand */ });
}

/* ------------------------------------------------------------------ run */

function init() {
    var saved = null;
    try { saved = localStorage.getItem('theme'); } catch (e) { /* private mode */ }
    if (saved) {
        applyTheme(saved);
    }
    on($('#theme'), 'click', function () {
        var dark = document.documentElement.getAttribute('data-theme') === 'dark';
        applyTheme(dark ? 'light' : 'dark');
    });

    fillVolumes();

    on(document, 'click', '[data-save]', function () {
        var btn = this;
        var view = btn.parentNode.parentNode.id.replace('view-', '');
        btn.disabled = true;
        saveView(view).then(function () { btn.disabled = false; });
    });

    on(document, 'click', '.copy', function () {
        var src = $('#' + this.getAttribute('data-copy'));
        if (navigator.clipboard) {
            navigator.clipboard.writeText(src.textContent).then(function () {
                toast('Copied');
            })['catch'](function () {
                toast('Copy blocked - select it by hand', true);
            });
        } else {
            /* No clipboard API without HTTPS on some browsers. */
            toast('Copy blocked - select it by hand', true);
        }
    });

    on(document, 'change', '[data-key]', function () {
        if (this.closest('#view-camera')) {
            syncDetection(this.getAttribute('data-key'));
        }
    });

    on($('#btn-snap'), 'click', takeSnapshot);
    on($('#btn-tts'), 'click', speak);
    on($('#btn-wav'), 'click', playWav);
    on($('#btn-wifi-scan'), 'click', scanWifi);
    on($('#btn-wifi-save'), 'click', saveWifi);
    on($('#wifi-list'), 'change', toggleWifiManual);
    on($('#btn-backup'), 'click', backup);
    on($('#btn-restore'), 'click', restore);
    on($('#btn-reboot'), 'click', reboot);
    on($('#btn-reset'), 'click', factoryReset);
    on($('#banner-reboot'), 'click', reboot);
    on($('#banner-close'), 'click', function () { show($('#banner'), false); });

    on($('#tz-search'), 'change', function () {
        if (tzMap && tzMap[this.value]) {
            $('#k-TIMEZONE').value = tzMap[this.value];
        }
    });

    on(window, 'hashchange', route);
    route();
}

if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
} else {
    init();
}
