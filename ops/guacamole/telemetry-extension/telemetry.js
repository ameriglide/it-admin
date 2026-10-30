/*
 * AG-1356: client-side Guacamole tunnel telemetry.
 *
 * Server logs only show that a user went silent or that a stream closed; they
 * cannot say what the browser saw. This records, for every Guacamole websocket
 * tunnel, how it ended -- who closed it, the close code, how long since data
 * last arrived/left, whether the tab was hidden, and whether the browser
 * thought it was online -- and reports it as a GET to a URL that does not
 * exist. Tomcat answers 404 and its access log keeps the query string, so no
 * backend is needed. See README.md, "Client telemetry".
 *
 * Events are queued in localStorage and flushed on the next chance, so a
 * close caused by a dead network is still reported once the network is back.
 * Only the numeric connection id is sent (the DB maps it to a user).
 */
(function () {
    'use strict';

    var ENDPOINT = 'telemetry/ws.gif';
    var QUEUE_KEY = 'ag1356.telemetry.queue';
    var MAX_QUEUE = 50;
    var FLUSH_INTERVAL = 60000;

    var hiddenSince = document.visibilityState === 'hidden' ? Date.now() : 0;
    document.addEventListener('visibilitychange', function () {
        hiddenSince = document.visibilityState === 'hidden' ? Date.now() : 0;
    });

    // Guacamole client URLs are #/client/<base64 of "id\0type\0datasource">
    function connectionId() {
        var m = /#\/client\/([^?\/]+)/.exec(location.hash);
        if (!m) return '';
        try { return atob(decodeURIComponent(m[1])).split('\u0000')[0]; }
        catch (e) { return ''; }
    }

    function readQueue() {
        try { return JSON.parse(localStorage.getItem(QUEUE_KEY)) || []; }
        catch (e) { return []; }
    }

    function writeQueue(q) {
        try { localStorage.setItem(QUEUE_KEY, JSON.stringify(q.slice(-MAX_QUEUE))); }
        catch (e) { /* storage unavailable: events for this page are lost */ }
    }

    var flushing = false;
    function flush() {
        if (flushing || !navigator.onLine) return;
        var q = readQueue();
        if (!q.length) return;
        flushing = true;
        var item = q[0];
        var qs = Object.keys(item).map(function (k) {
            return encodeURIComponent(k) + '=' + encodeURIComponent(item[k]);
        }).join('&');
        // Any HTTP response (including the expected 404) means it was logged.
        fetch(ENDPOINT + '?' + qs, { cache: 'no-store', credentials: 'same-origin', keepalive: true })
            .then(function () {
                var cur = readQueue();
                if (cur.length && cur[0].t === item.t && cur[0].e === item.e) cur.shift();
                writeQueue(cur);
                flushing = false;
                flush();
            }, function () { flushing = false; });
    }

    function record(fields) {
        fields.t = Date.now();
        fields.cid = connectionId();
        fields.vis = document.visibilityState === 'hidden' ? 'h' : 'v';
        fields.hid = hiddenSince ? Date.now() - hiddenSince : 0;
        fields.on = navigator.onLine ? 1 : 0;
        var c = navigator.connection;
        if (c) { fields.ct = c.effectiveType || ''; fields.rtt = c.rtt || 0; }
        var q = readQueue();
        q.push(fields);
        writeQueue(q);
        flush();
    }

    function track(ws) {
        var s = { opened: 0, lastRecv: 0, lastSend: 0, recv: 0, sent: 0, closeCalled: 0 };
        var created = Date.now();

        ws.addEventListener('open', function () { s.opened = s.lastRecv = s.lastSend = Date.now(); });
        ws.addEventListener('message', function () { s.lastRecv = Date.now(); s.recv++; });

        var send = ws.send;
        ws.send = function (data) { s.lastSend = Date.now(); s.sent++; return send.call(ws, data); };

        // Remember when the page itself asked to close, and how stale the
        // stream was at that moment: Guacamole closes on a 15s receive timeout.
        var close = ws.close;
        ws.close = function () {
            if (!s.closeCalled) {
                s.closeCalled = Date.now();
                s.rgAtClose = s.lastRecv ? s.closeCalled - s.lastRecv : -1;
            }
            return close.apply(ws, arguments);
        };

        ws.addEventListener('close', function (ev) {
            var now = Date.now();
            record({
                e: 'close',
                code: ev.code,
                clean: ev.wasClean ? 1 : 0,
                by: s.closeCalled ? 'page' : 'net',
                age: Math.round((now - (s.opened || created)) / 1000),
                rg: s.closeCalled ? s.rgAtClose : (s.lastRecv ? now - s.lastRecv : -1),
                sg: s.lastSend ? now - s.lastSend : -1,
                recv: s.recv,
                sent: s.sent
            });
        });
    }

    var NativeWebSocket = window.WebSocket;
    function TrackedWebSocket(url, protocols) {
        var ws = protocols === undefined ? new NativeWebSocket(url) : new NativeWebSocket(url, protocols);
        try { if (/websocket-tunnel/.test(String(url))) track(ws); }
        catch (e) { /* telemetry must never break the tunnel */ }
        return ws;
    }
    TrackedWebSocket.prototype = NativeWebSocket.prototype;
    ['CONNECTING', 'OPEN', 'CLOSING', 'CLOSED'].forEach(function (k) {
        TrackedWebSocket[k] = NativeWebSocket[k];
    });
    window.WebSocket = TrackedWebSocket;

    /*
     * Fast reconnect. When a tunnel is cut, Guacamole shows "server is not
     * currently reachable" with a 15s countdown and then runs its own
     * Reconnect action -- but only for errors it already considers safe to
     * retry (TUNNEL_AUTO_RECONNECT / CLIENT_AUTO_RECONNECT in
     * guacClientNotification.js). The Windows session survives a cut, so the
     * wait buys nothing. Press Guacamole's own Reconnect button after ~1s,
     * only when its countdown is showing, at most once per FAST_RECONNECT_GAP
     * so a portal that is really down still gets the normal 15s pacing.
     */
    var FAST_RECONNECT_DELAY = 1000;
    var FAST_RECONNECT_GAP = 30000;
    var lastFastReconnect = 0;
    var pendingReconnect = null;

    function visible(el) {
        return el && !el.classList.contains('ng-hide') && el.offsetParent !== null;
    }

    function autoReconnectButton() {
        if (!/^#\/client\//.test(location.hash)) return null;
        var forms = document.querySelectorAll('form.notification');
        for (var i = 0; i < forms.length; i++) {
            var countdown = forms[i].querySelector('p.countdown-text');
            var button = forms[i].querySelector('button.reconnect');
            if (visible(countdown) && visible(button)) return button;
        }
        return null;
    }

    function checkFastReconnect() {
        if (pendingReconnect || !autoReconnectButton()) return;
        if (Date.now() - lastFastReconnect < FAST_RECONNECT_GAP) return;
        pendingReconnect = setTimeout(function () {
            pendingReconnect = null;
            var button = autoReconnectButton();
            if (!button) return;
            lastFastReconnect = Date.now();
            record({ e: 'fastrc' });
            button.click();
        }, FAST_RECONNECT_DELAY);
    }

    new MutationObserver(checkFastReconnect).observe(document.documentElement,
        { childList: true, subtree: true, attributes: true, attributeFilter: ['class'] });

    window.addEventListener('offline', function () { record({ e: 'offline' }); });
    window.addEventListener('online', function () { record({ e: 'online' }); });
    setInterval(flush, FLUSH_INTERVAL);
    flush();
})();
