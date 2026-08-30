/* SQL Express Backup - console behaviour.
 *
 * Talks only to the local process that served this page, and every request carries
 * the per-launch token that process minted. No external origin is reachable: the
 * CSP in index.html allows 'self' and nothing else.
 *
 * GSAP is used for STATE changes only - a card whose tone changed, a pip coming
 * alive, a row arriving. Nothing animates the log pane or the settings inputs; see
 * the note in app.css for why.
 */
(function () {
  'use strict';

  var TOKEN = document.body.getAttribute('data-token');
  var reduced = window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  var logCursor = 0;
  var busy = false;
  var lastTone = {};

  function url(path, extra) {
    var u = path + (path.indexOf('?') === -1 ? '?' : '&') + 't=' + encodeURIComponent(TOKEN);
    return extra ? u + '&' + extra : u;
  }

  // `extra` must be forwarded: without it the caller's "since" is silently dropped,
  // the server answers from cursor 0 every time, and the log pane repeats itself on
  // every tick forever.
  function get(path, extra) {
    return fetch(url(path, extra), { credentials: 'omit', cache: 'no-store' }).then(function (r) {
      if (!r.ok) { throw new Error(path + ' -> ' + r.status); }
      return r.json();
    });
  }

  function post(path, body) {
    return fetch(url(path), {
      method: 'POST',
      credentials: 'omit',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: body || ''
    }).then(function (r) {
      if (!r.ok) { throw new Error(path + ' -> ' + r.status); }
      return r.json();
    });
  }

  function el(id) { return document.getElementById(id); }

  // Skip motion entirely when the tab is not visible: rAF is throttled or stopped
  // there, so a tween started now would sit unfinished.
  function canAnimate() {
    return !reduced && window.gsap && document.visibilityState !== 'hidden';
  }

  function tone(result) {
    if (result === 'ok') { return 'ok'; }
    if (result === 'partial') { return 'partial'; }
    if (result === 'failed') { return 'failed'; }
    return 'unknown';
  }

  // Glow, but only when the tone actually CHANGED. Re-pulsing every poll would make
  // a healthy console flicker every two seconds, which trains people to ignore it.
  function setTone(node, key, value) {
    if (!node) { return; }
    var changed = lastTone[key] !== value;
    lastTone[key] = value;
    if (value === 'unknown') { node.removeAttribute('data-tone'); return; }
    node.setAttribute('data-tone', value);
    if (changed && canAnimate()) {
      gsap.fromTo(node, { scale: 0.985 }, { scale: 1, duration: 0.45, ease: 'power2.out', clearProps: 'transform' });
    }
  }

  function ago(iso) {
    if (!iso) { return null; }
    var then = Date.parse(iso);
    if (isNaN(then)) { return null; }
    var mins = Math.floor((Date.now() - then) / 60000);
    if (mins < 1) { return 'just now'; }
    if (mins < 60) { return mins + ' min ago'; }
    var hrs = Math.floor(mins / 60);
    if (hrs < 48) { return hrs + ' h ago'; }
    return Math.floor(hrs / 24) + ' days ago';
  }

  function renderStatus(s) {
    el('hostName').textContent = s.hostName || '';
    el('instance').textContent = s.instance || 'not configured';
    el('sharePath').textContent = s.sharePath || 'no share configured';

    var result = s.lastResult || 'never';
    el('lastResult').textContent = result;
    el('lastRunAt').textContent = ago(s.lastRunUtc) || 'never run';
    var t = tone(s.lastResult);
    setTone(el('cardState'), 'state', t);
    el('pip').setAttribute('data-state', t);

    el('scheduleState').textContent = s.scheduleState || 'absent';
    el('scheduleNext').textContent = s.scheduleNext ? ('next ' + s.scheduleNext) : 'not installed';
    setTone(el('cardSchedule'), 'sched', s.scheduleState === 'Ready' || s.scheduleState === 'Running' ? 'ok' : 'unknown');

    var pending = (typeof s.pendingCount === 'number') ? s.pendingCount : null;
    el('pendingCount').textContent = pending === null ? '-' : String(pending);
    setTone(el('cardPending'), 'pending', pending === null ? 'unknown' : (pending > 0 ? 'partial' : 'ok'));

    var body = el('dbTable').getElementsByTagName('tbody')[0];
    var rows = s.databases || [];
    if (!rows.length) {
      body.innerHTML = '<tr><td colspan="5" class="muted">' +
        (s.shareReadable ? 'No backups on the share yet.' : 'Share not readable from here.') + '</td></tr>';
    } else {
      var html = '';
      for (var i = 0; i < rows.length; i++) {
        var r = rows[i];
        var age = ago(r.newestUtc);
        var stale = r.ageHours !== null && r.ageHours !== undefined && r.ageHours > (s.intervalHours || 6) * 2;
        html += '<tr><td>' + esc(r.name) + '</td><td>' + r.hourly + '</td><td>' + r.daily +
          '</td><td>' + esc(r.newestLocal || '-') + '</td><td' + (stale ? ' class="stale"' : '') + '>' +
          esc(age || '-') + '</td></tr>';
      }
      body.innerHTML = html;
      if (canAnimate()) {
        gsap.from(body.getElementsByTagName('tr'), { y: -4, duration: 0.3, stagger: 0.03, ease: 'power1.out' });
      }
    }
    el('shareNote').textContent = s.shareNote || '';

    if (!s.configured) {
      el('actionNote').textContent = 'Not set up on this host yet. Fill in the share path and save settings first.';
    }
  }

  function esc(v) {
    return String(v === null || v === undefined ? '' : v)
      .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
  }

  function fillSettings(s) {
    if (document.activeElement && document.activeElement.tagName === 'INPUT') { return; }
    if (s.sharePath) { el('setShare').value = s.sharePath; }
    if (s.stagingPath) { el('setStaging').value = s.stagingPath; }
    if (s.intervalHours) { el('setInterval').value = s.intervalHours; }
    if (s.hourlyKeep) { el('setHourly').value = s.hourlyKeep; }
    if (s.dailyKeepDays) { el('setDaily').value = s.dailyKeepDays; }
    if (s.configured && typeof s.useWindowsAuth === 'boolean') {
      el('setAuth').value = s.useWindowsAuth ? 'windows' : 'sql';
    }
  }

  function pollStatus() {
    get('/api/status').then(function (s) {
      renderStatus(s);
      fillSettings(s);
    }).catch(function (e) {
      el('shareNote').textContent = 'status unavailable: ' + e.message;
    });
  }

  var logInFlight = false;
  function pollLog() {
    // One at a time. Two overlapping requests both carry the SAME cursor - the first
    // has not returned to advance it - so both append the same lines and the pane
    // shows every line twice.
    if (logInFlight) { return; }
    logInFlight = true;
    get('/api/log', 'since=' + logCursor).then(function (d) {
      if (d.lines && d.lines.length) {
        var pane = el('log');
        if (pane.textContent === 'Waiting.') { pane.textContent = ''; }
        pane.textContent += d.lines.join('\n') + '\n';
        pane.scrollTop = pane.scrollHeight;
      }
      logCursor = d.next;
      if (busy && d.idle) { setBusy(false); pollStatus(); }
      logInFlight = false;
    }).catch(function () {
      // The process may be shutting down; the next tick retries.
      logInFlight = false;
    });
  }

  function setBusy(state) {
    busy = state;
    var btns = document.querySelectorAll('.act, .primary');
    for (var i = 0; i < btns.length; i++) { btns[i].disabled = state; }
  }

  function runAction(action) {
    setBusy(true);
    el('actionNote').textContent = action === 'selftest'
      ? 'Running the self test. This creates and drops its own scratch database.'
      : 'Windows will ask for an administrator. The output appears below when it starts.';
    post('/api/action', 'action=' + encodeURIComponent(action)).catch(function (e) {
      el('actionNote').textContent = 'could not start: ' + e.message;
      setBusy(false);
    });
  }

  var acts = document.querySelectorAll('.act[data-action]');
  for (var i = 0; i < acts.length; i++) {
    acts[i].addEventListener('click', function () { runAction(this.getAttribute('data-action')); });
  }

  el('settingsForm').addEventListener('submit', function (ev) {
    ev.preventDefault();
    var share = el('setShare').value.trim();
    if (!share) { el('actionNote').textContent = 'A share path is required before setup can run.'; return; }
    setBusy(true);
    el('actionNote').textContent = 'Windows will ask for an administrator. Setup proves the connection, the staging folder and the share before writing anything.';
    post('/api/settings', 'share=' + encodeURIComponent(share) +
      '&staging=' + encodeURIComponent(el('setStaging').value.trim()) +
      '&interval=' + encodeURIComponent(el('setInterval').value) +
      '&hourly=' + encodeURIComponent(el('setHourly').value) +
      '&daily=' + encodeURIComponent(el('setDaily').value) +
      '&auth=' + encodeURIComponent(el('setAuth').value)
    ).catch(function (e) {
      el('actionNote').textContent = 'could not start: ' + e.message;
      setBusy(false);
    });
  });

  // Full install: revealed, explained, and gated on the typed phrase. The same phrase
  // is required by the server, so removing this block would not bypass anything.
  var CONFIRM_PHRASE = 'FULL INSTALL';
  function fullTargetText() {
    var folder = el('fullFolder').value.trim() || 'C:\\SqlBackups';
    var share = el('fullShare').value.trim() || 'SqlBackups';
    var host = el('hostName').textContent || 'this host';
    return 'Will create ' + folder + ' and share it as \\\\' + host + '\\' + share;
  }
  function refreshFull() {
    el('fullTarget').textContent = fullTargetText();
    el('fullGo').disabled = (el('fullConfirm').value.trim() !== CONFIRM_PHRASE);
  }
  el('fullBtn').addEventListener('click', function () {
    var panel = el('fullPanel');
    panel.hidden = !panel.hidden;
    if (!panel.hidden) {
      refreshFull();
      if (canAnimate()) { gsap.from(panel, { y: -6, duration: 0.35, ease: 'power2.out' }); }
      el('fullConfirm').focus();
    }
  });
  el('fullCancel').addEventListener('click', function () {
    el('fullPanel').hidden = true;
    el('fullConfirm').value = '';
    el('fullGo').disabled = true;
  });
  el('fullConfirm').addEventListener('input', refreshFull);
  el('fullFolder').addEventListener('input', refreshFull);
  el('fullShare').addEventListener('input', refreshFull);
  el('fullGo').addEventListener('click', function () {
    setBusy(true);
    el('fullPanel').hidden = true;
    el('actionNote').textContent = 'Windows will ask for an administrator. The full install creates the share, sets up, schedules, and then runs one backup as SYSTEM.';
    post('/api/action', 'action=fullinstall' +
      '&confirm=' + encodeURIComponent(el('fullConfirm').value.trim()) +
      '&shareName=' + encodeURIComponent(el('fullShare').value.trim()) +
      '&shareFolder=' + encodeURIComponent(el('fullFolder').value.trim()) +
      '&interval=' + encodeURIComponent(el('setInterval').value) +
      '&hourly=' + encodeURIComponent(el('setHourly').value) +
      '&daily=' + encodeURIComponent(el('setDaily').value)
    ).catch(function (e) {
      el('actionNote').textContent = 'could not start: ' + e.message;
      setBusy(false);
    });
    el('fullConfirm').value = '';
    el('fullGo').disabled = true;
  });

  el('quitBtn').addEventListener('click', function () {
    post('/api/quit').catch(function () { });
    document.body.innerHTML = '<main><section class="panel"><h2>Closed</h2>' +
      '<p class="note">The console has shut down. Any scheduled backups keep running without it. ' +
      'You can close this tab.</p></section></main>';
  });

  // Theme: follow the OS unless the operator overrode it, and remember that choice.
  var THEME_KEY = 'seb.theme';
  function applyTheme(v) {
    if (v === 'light' || v === 'dark') { document.documentElement.setAttribute('data-theme', v); }
    else { document.documentElement.removeAttribute('data-theme'); }
  }
  try { applyTheme(localStorage.getItem(THEME_KEY)); } catch (e) { /* private window */ }
  el('themeBtn').addEventListener('click', function () {
    var cur = document.documentElement.getAttribute('data-theme');
    var next = cur === 'dark' ? 'light' : (cur === 'light' ? '' : 'dark');
    applyTheme(next);
    try { next ? localStorage.setItem(THEME_KEY, next) : localStorage.removeItem(THEME_KEY); } catch (e) { }
  });

  // Position only - NEVER opacity. requestAnimationFrame is paused in a background
  // tab, so an opacity-from-0 intro freezes mid-stagger and leaves the page partly
  // blank until someone focuses the tab. Content must not depend on a tween
  // finishing; the motion is decoration layered on something already readable.
  if (canAnimate()) {
    gsap.from('.card', { y: 8, duration: 0.4, stagger: 0.05, ease: 'power2.out' });
    gsap.from('.panel', { y: 10, duration: 0.45, stagger: 0.06, delay: 0.1, ease: 'power2.out' });
  }

  pollStatus();
  pollLog();
  setInterval(pollLog, 1200);
  setInterval(pollStatus, 4000);
})();
