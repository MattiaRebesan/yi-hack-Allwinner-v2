/*
 * Minimal DOM and HTTP helpers.
 *
 * Replaces jQuery, which was 30 KB gzipped of the 44 KB the old UI shipped
 * while using about fifteen of its methods. Everything below is ES5 on
 * purpose: compile.www minifies with yui-compressor, which is Rhino-based
 * and rejects arrow functions, template literals and spread.
 *
 * Rhino is in fact ES3, which means a reserved word cannot follow a dot:
 * `p.catch(fn)` fails to parse with "missing name after . operator". Promise
 * rejection is therefore handled as `p['catch'](fn)` throughout. That is the
 * only reason for the bracket notation - do not tidy it away.
 */

function $(sel, root) {
    return (root || document).querySelector(sel);
}

function $$(sel, root) {
    return Array.prototype.slice.call((root || document).querySelectorAll(sel));
}

function on(el, evt, sel, fn) {
    if (typeof sel === 'function') {
        el.addEventListener(evt, sel);
        return;
    }
    el.addEventListener(evt, function (e) {
        var t = e.target;
        while (t && t !== el) {
            if (t.matches && t.matches(sel)) {
                fn.call(t, e);
                return;
            }
            t = t.parentNode;
        }
    });
}

function text(sel, value) {
    var el = typeof sel === 'string' ? $(sel) : sel;
    if (el) {
        el.textContent = value === undefined || value === null ? '' : String(value);
    }
}

function show(el, visible) {
    if (el) {
        el.hidden = !visible;
    }
}

/*
 * get_configs.sh emits raw tab characters inside values (set_configs.sh
 * stores multi-line values with newlines swapped for tabs). A raw control
 * character is not legal inside a JSON string, so JSON.parse would throw on
 * any camera with a CRONTAB set. Escape them before parsing.
 */
function parseLooseJSON(body) {
    return JSON.parse(body.replace(/\t/g, '\\t'));
}

function httpJSON(method, url, body, contentType) {
    var opts = { method: method, cache: 'no-store' };
    if (body !== undefined && body !== null) {
        opts.body = body;
        opts.headers = { 'Content-Type': contentType || 'application/json' };
    }
    return fetch(url, opts).then(function (r) {
        if (!r.ok) {
            throw new Error(url + ' -> HTTP ' + r.status);
        }
        return r.text();
    }).then(function (t) {
        return t.length ? parseLooseJSON(t) : {};
    });
}

function getJSON(url) {
    return httpJSON('GET', url);
}

function postJSON(url, obj) {
    return httpJSON('POST', url, JSON.stringify(obj));
}

function fmtUptime(seconds) {
    var s = parseInt(seconds, 10);
    if (isNaN(s)) {
        return '-';
    }
    var d = Math.floor(s / 86400);
    var h = Math.floor((s % 86400) / 3600);
    var m = Math.floor((s % 3600) / 60);
    var out = '';
    if (d) {
        out += d + 'd ';
    }
    if (d || h) {
        out += h + 'h ';
    }
    return out + m + 'm';
}

function fmtKB(kb) {
    var n = parseInt(kb, 10);
    if (isNaN(n)) {
        return '-';
    }
    if (n >= 1048576) {
        return (n / 1048576).toFixed(1) + ' GB';
    }
    if (n >= 1024) {
        return (n / 1024).toFixed(1) + ' MB';
    }
    return n + ' KB';
}
