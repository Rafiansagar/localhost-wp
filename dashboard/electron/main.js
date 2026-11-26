// ============================================================================
//  main.js  -  Electron shell for the localhost-wp Control Panel
//  ----------------------------------------------------------------------------
//  Portable: Electron sits unzipped in <stack>\electron\ as localhost-wp.exe
//  (scripts\helper\get-electron.ps1 fetches it). Its resources\app loader
//  requires this file, so the exe, the localhost-wp shortcut or a taskbar pin
//  open the Control Panel with no arguments. Nothing is installed.
//
//  The backend is unchanged: dashboard\server\server.ps1 serves the same page
//  and API. This shell only starts it, shows it in a window, and adds a tray.
//
//  One shell per stack folder. The profile (and so the single-instance lock)
//  lives inside the stack, so F:\localhost-wp-8.5 and E:\localhost-wp each get
//  their own app, window and tray icon, and a second launch of the same stack
//  just brings its window back.
//
//  Also: stops the stack gracefully when Windows shuts down or signs out,
//  shows a notification when a job finishes while the window is out of
//  sight, fills the taskbar button during long jobs, colours the tray icon
//  by stack state, and says when a newer GitHub release is out.
// ============================================================================
const { app, BrowserWindow, Tray, Menu, nativeImage, shell, dialog, screen, nativeTheme, Notification } = require('electron');
const path = require('path');
const fs = require('fs');
const crypto = require('crypto');
const { spawn, spawnSync } = require('child_process');

// Releases are checked here; the installed version is <stack>\VERSION.
const UPDATE_REPO = 'Rafiansagar/localhost-wp';

const DASH   = path.resolve(__dirname, '..');      // <stack>\dashboard
const BASE   = path.resolve(DASH, '..');           // <stack>
const SERVER = path.join(DASH, 'server', 'server.ps1');
const ICONS  = path.join(DASH, 'icons');

const APP_ICO = path.join(BASE, 'electron', 'localhost-wp.ico');
const APP_ID  = 'localhost-wp.' + crypto.createHash('sha1').update(BASE.toLowerCase()).digest('hex').slice(0, 12);

app.setPath('userData', path.join(BASE, 'electron', 'userdata'));
// Separate taskbar group (and pin) per stack folder.
app.setAppUserModelId(APP_ID);

let win = null;
let tray = null;
let port = 0;
let token = '';
let quitting = false;
let serverProc = null;         // the dashboard server (server.ps1) this app started
let hintShown = false;
let status = null;
let settings = null;          // config\app-settings.json, read through the dashboard API
// Started by Windows at sign-in (Settings > Startup), not by the user.
const atStartup = process.argv.includes('--startup');

// ---- backend ---------------------------------------------------------------
// server.ps1 picks a free port (7070 up) and prints "CP_PORT=<n>". If this
// stack's dashboard is already running it prints that port and exits.
function startServer() {
  return new Promise((resolve, reject) => {
    const ps = spawn('powershell.exe', [
      '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', SERVER,
      '-Base', BASE, '-NoWindow', '-ParentPid', String(process.pid),
    ], { windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] });
    serverProc = ps;

    let out = '', err = '';
    const timer = setTimeout(() => reject(new Error('The dashboard server did not answer within 30 seconds.')), 30000);
    ps.stdout.on('data', d => {
      out += d;
      const m = out.match(/CP_PORT=(\d+)/);
      if (m && !port) { port = +m[1]; clearTimeout(timer); resolve(port); }
    });
    ps.stderr.on('data', d => { err += d; });
    ps.on('error', e => { clearTimeout(timer); reject(e); });
    ps.on('exit', code => {
      if (!port) { clearTimeout(timer); reject(new Error(`server.ps1 exited (${code}).\n${err.trim()}`)); }
    });
  });
}

const origin = () => `http://localhost:${port}`;

// The page carries the per-run API token; the tray uses the same one.
async function readToken() {
  const html = await (await fetch(origin() + '/')).text();
  const m = html.match(/name="cp-token" content="([0-9a-f]+)"/);
  token = m ? m[1] : '';
}

async function api(method, p, body) {
  const r = await fetch(origin() + p, {
    method,
    headers: { 'X-Token': token, 'Content-Type': 'application/json' },
    body: body ? JSON.stringify(body) : undefined,
  });
  const j = await r.json();
  if (r.status === 403) await readToken();   // server restarted itself with a new token
  if (!r.ok) throw new Error(j.error || `HTTP ${r.status}`);
  return j;
}

// ---- window ----------------------------------------------------------------
function createWindow() {
  const wa = screen.getPrimaryDisplay().workAreaSize;
  win = new BrowserWindow({
    width: Math.min(1440, wa.width), height: Math.min(900, wa.height),
    minWidth: 1024, minHeight: 600,
    show: false,
    autoHideMenuBar: true,
    icon: fs.existsSync(APP_ICO) ? APP_ICO : path.join(ICONS, 'icon-192.png'),
    title: `localhost-wp - ${BASE}`,
    // No Windows title bar: the page draws a draggable band, and Windows keeps
    // its own minimise / maximise / close buttons (snap layouts included) on top.
    titleBarStyle: 'hidden',
    titleBarOverlay: { color: nativeTheme.shouldUseDarkColors ? '#161B22' : '#E9EDF1', symbolColor: nativeTheme.shouldUseDarkColors ? '#E3E8EE' : '#1B2330', height: 32 },
    backgroundColor: nativeTheme.shouldUseDarkColors ? '#161B22' : '#E9EDF1',
    webPreferences: { contextIsolation: true, sandbox: true, backgroundThrottling: false },
  });
  win.removeMenu();

  // A taskbar pin relaunches this exe (no arguments needed) with the app icon,
  // and is named after the stack folder so two stacks' pins are told apart.
  win.setAppDetails({
    appId: APP_ID,
    relaunchCommand: `"${process.execPath}"`,
    relaunchDisplayName: `localhost-wp (${path.basename(BASE)})`,
    ...(fs.existsSync(APP_ICO) ? { appIconPath: APP_ICO, appIconIndex: 0 } : {}),
  });

  // Title names the folder so two stacks are told apart in the taskbar.
  win.on('page-title-updated', (e, t) => { e.preventDefault(); win.setTitle(`${t} - ${BASE}`); });

  // Site links, WP Admin, docs: the user's own browser, never inside the shell.
  // The dashboard's own links (Ctrl/Shift/middle click on a site name) stay
  // in this window: the page needs the app's token, a browser tab has none.
  win.webContents.setWindowOpenHandler(({ url }) => {
    if (url.startsWith(origin() + '/')) {
      const hash = new URL(url).hash;
      if (hash) win.webContents.executeJavaScript(`location.hash = ${JSON.stringify(hash)}`).catch(() => { });
      showWindow();
    } else if (/^https?:\/\//.test(url)) shell.openExternal(url);
    return { action: 'deny' };
  });
  win.webContents.on('will-navigate', (e, url) => {
    if (!url.startsWith(origin() + '/')) { e.preventDefault(); if (/^https?:\/\//.test(url)) shell.openExternal(url); }
  });

  win.on('close', e => {
    if (quitting) return;
    e.preventDefault();
    onWindowClose();
  });

  // Windows shutdown, restart or sign-out.
  win.on('query-session-end', stopForShutdown);
  win.on('session-end', stopForShutdown);

  // The window buttons take the page's colours, following its theme (Settings >
  // Appearance or Windows). Read from the page: on load, on focus, and every 2 s
  // while shown, which is cheap and catches a theme switch.
  let overlayKey = '';
  const syncOverlay = async () => {
    if (!win || win.isDestroyed() || !win.isVisible()) return;
    try {
      const c = await win.webContents.executeJavaScript(`(() => { const s = getComputedStyle(document.documentElement);
        return [s.getPropertyValue('--paper').trim(), s.getPropertyValue('--ink').trim()]; })()`);
      const key = c.join('|');
      if (c[0] && c[1] && key !== overlayKey) { overlayKey = key; win.setTitleBarOverlay({ color: c[0], symbolColor: c[1], height: 32 }); }
    } catch { }
  };
  win.webContents.on('did-finish-load', syncOverlay);
  win.on('focus', syncOverlay);
  win.on('show', syncOverlay);
  setInterval(syncOverlay, 2000);

  // Opened by Windows at sign-in: stays in the tray unless "Show the window" is on.
  win.once('ready-to-show', () => { if (!atStartup || (settings && settings.startupShow)) win.show(); });
  win.loadURL(origin() + '/');
}

function hideToTray() {
  win.hide();
  if (!hintShown && tray) {
    hintShown = true;
    notify('localhost-wp', 'Still in the tray. Right-click the icon to quit.', 'info', showWindow);
  }
}

// Closing the window:
//   stack stopped           -> quit (the tray only exists to keep sites running)
//   stack stopping          -> hide, then quit once the stop is done
//   stack running / a job   -> Settings > Window: tray (default), ask, or stop and quit
// The decision uses a fresh status, not the last 4-second poll.
let closing = false;
async function onWindowClose() {
  if (closing) return;
  closing = true;
  try {
    let st = status;
    try { st = await Promise.race([api('GET', '/api/status'), new Promise((_, no) => setTimeout(no, 1500))]); status = st; } catch { }
    if (!st) { quit(); return; }                       // no server to keep: nothing is running
    const up = Object.values(st.services || {}).some(Boolean);
    const busy = st.busy || null;
    if (busy === 'stop' || busy === 'stop-nobackup') { win.hide(); await waitIdle(); quit(); return; }
    if (!up && !busy) { quit(); return; }
    const choice = (settings && settings.closeAction) || 'tray';
    if (choice === 'stop') { await stopAndQuit(); return; }
    if (choice === 'ask') { await askOnClose(); return; }
    hideToTray();
  } finally { closing = false; }
}

async function askOnClose() {
  const { response } = await dialog.showMessageBox(win, {
    type: 'question',
    title: 'localhost-wp',
    message: 'Close localhost-wp?',
    detail: 'Your sites keep working while it runs in the tray.',
    buttons: ['Keep running in the tray', 'Stop the stack and quit', 'Cancel'],
    defaultId: 0, cancelId: 2, noLink: true,
  });
  if (response === 0) hideToTray();
  else if (response === 1) await stopAndQuit();
}

// Until no job runs (at most 3 minutes, so a stuck job never keeps the app alive forever).
async function waitIdle() {
  for (let i = 0; i < 360; i++) {
    await new Promise(r => setTimeout(r, 500));
    try { if (!(await api('GET', '/api/status')).busy) return; } catch { return; }
  }
}

// Settings > Startup: a Run entry for this exe, named per stack folder so two
// stacks never overwrite each other's entry.
let loginApplied = null;
function applyLoginItem() {
  if (!settings || loginApplied === settings.startup) return;
  loginApplied = settings.startup;
  try {
    app.setLoginItemSettings({ openAtLogin: !!settings.startup, path: process.execPath, args: ['--startup'], name: APP_ID });
  } catch { }
}

function showWindow() {
  if (!win) return;
  if (win.isMinimized()) win.restore();
  win.show();
  win.focus();
}

// ---- Windows shutdown --------------------------------------------------------
// Windows would otherwise kill mysqld mid-write, and MySQL has to recover its
// tables on the next start. This runs synchronously, so Windows waits for it
// (a few seconds). No backup: there is no time for one.
let shutdownHandled = false;
function stopForShutdown() {
  if (shutdownHandled) return;
  shutdownHandled = true;
  quitting = true;
  const st = status;
  if (st && !st.busy && !Object.values(st.services || {}).some(Boolean)) return;   // already stopped
  spawnSync('powershell.exe', [
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', path.join(DASH, 'server', 'stop.ps1'), '-Base', BASE,
  ], { windowsHide: true, timeout: 90000 });
}

// ---- notifications -----------------------------------------------------------
// Windows toasts. Windows shows a desktop app's toasts only when a Start Menu
// shortcut carries the app's AppUserModelID, so one is kept in place (named
// after the stack folder, so two stacks get two). Without it, or if a toast
// fails, the tray balloon is used instead.
//   opts.sticky  stays on screen until closed (fatal errors)
//   opts.silent  no sound (notices, deprecations)
const SHORTCUT = path.join(app.getPath('appData'), 'Microsoft', 'Windows', 'Start Menu', 'Programs',
  `localhost-wp - ${BASE.replace(/[\\/:*?"<>|]+/g, ' ').replace(/\s+/g, ' ').trim()}.lnk`);
let toastReady = false;
function ensureToastShortcut() {
  try {
    let ok = false;
    if (fs.existsSync(SHORTCUT)) {
      const l = shell.readShortcutLink(SHORTCUT);
      ok = l.target.toLowerCase() === process.execPath.toLowerCase() && l.appUserModelId === APP_ID;
    }
    if (!ok) {
      ok = shell.writeShortcutLink(SHORTCUT, fs.existsSync(SHORTCUT) ? 'replace' : 'create', {
        target: process.execPath, appUserModelId: APP_ID, description: `localhost-wp - ${BASE}`,
        ...(fs.existsSync(APP_ICO) ? { icon: APP_ICO, iconIndex: 0 } : {}),
      });
    }
    toastReady = ok && Notification.isSupported();
  } catch { toastReady = false; }
}

let balloonAction = null;
const toasts = new Set();   // kept referenced until closed, or click handlers are lost
function notify(title, content, level, onClick, opts = {}) {
  const balloon = () => {
    if (!tray) return;
    balloonAction = onClick || null;
    tray.displayBalloon({ title, content, iconType: { err: 'error', warn: 'warning' }[level] || 'info', respectQuietTime: true });
  };
  if (!toastReady) return balloon();
  try {
    const n = new Notification({
      title: String(title).slice(0, 120), body: String(content).slice(0, 400),
      silent: !!opts.silent, timeoutType: opts.sticky ? 'never' : 'default',
      ...(fs.existsSync(APP_ICO) ? { icon: APP_ICO } : {}),
    });
    toasts.add(n);
    const done = () => toasts.delete(n);
    n.on('click', () => { done(); if (onClick) onClick(); });
    n.on('close', done);
    n.on('failed', () => { done(); balloon(); });
    n.show();
  } catch { balloon(); }
}

const DONE = { start: () => 'Start stack', stop: () => 'Stop stack', 'stop-nobackup': () => 'Stop stack', reload: () => 'Reload Nginx',
  setup: () => 'Setup', 'new-site': n => `New site: ${n}`, backup: n => `Backup: ${n}`, delete: n => `Delete site: ${n}`,
  'mail-on': () => 'Mail catcher on', 'mail-off': () => 'Mail catcher off' };

// A job just finished: tell how it went, unless the window is in front.
async function jobDone(job, task, afterSeq) {
  if (win && win.isVisible() && win.isFocused() && !win.isMinimized()) return;
  if (settings && settings.notifyJobs === false) return;
  let entries = [];
  try { entries = (await api('GET', `/api/log?after=${afterSeq}`)).entries || []; } catch { }
  const last = [...entries].reverse().find(e => e.level !== 'info') || entries[entries.length - 1];
  if (!last) return;
  notify(`localhost-wp - ${(DONE[job] || (() => job))(task)}`, String(last.msg).trim(), last.level, showWindow);
}

// A new email in the mail catcher: one notification per poll, naming the newest
// (or how many arrived together). Clicking it opens the inbox. The first look
// after launch only records what is there, so old mail never pops up.
let mailSeen = null;     // { id, total } of the newest message seen
function mailCheck(mail) {
  if (!mail || !mail.running) return;
  const id = mail.latest ? mail.latest.id : null;
  const prev = mailSeen;
  mailSeen = { id, total: mail.total || 0 };
  if (!prev || !id || id === prev.id) return;
  if (settings && settings.notifyMail === false) return;
  const fresh = Math.max(1, mailSeen.total - prev.total);
  const m = mail.latest;
  const title = fresh > 1 ? `${fresh} new emails` : `New email${m.from ? ` from ${m.from}` : ''}`;
  const body = `${m.subject || '(no subject)'}${m.to ? `\nTo: ${m.to}` : ''}`;
  notify(title.slice(0, 63), body.slice(0, 255), 'info', () => shell.openExternal('http://localhost:8025'));
}

// ---- error alerts ---------------------------------------------------------------
// The error catcher (scripts\php\error-catcher.php) appends each request's new
// errors to logs\errors\<site>.jsonl when the request ends. This watches that
// folder and reads only what was added, so an alert shows the moment it is
// caught. Settings > Notifications picks the level; a site can be muted from
// its Errors tab (config\error-alerts-muted.json).
//   fatal       stays on screen until closed, with a sound
//   warning     shows briefly, with a sound
//   notice / deprecated   silent
// The same error alerts at most once in 10 minutes, errors arriving together
// make one toast, and nothing pops up while that error list is on screen.
const ERR_DIR = path.join(BASE, 'logs', 'errors');
const ERR_MUTED = path.join(BASE, 'config', 'error-alerts-muted.json');
const SEV_RANK = { fatal: 3, warning: 2, notice: 1, deprecated: 1 };
const SEV_NAME = { fatal: 'Fatal error', warning: 'Warning', notice: 'Notice', deprecated: 'Deprecated' };
const LEVEL_MIN = { fatal: 3, warning: 2, all: 1 };
const errSeverity = t => (t & 4437) ? 'fatal' : (t & 674) ? 'warning' : (t & 24576) ? 'deprecated' : 'notice';
const errOffsets = new Map();   // file name -> bytes already read
const errAlerted = new Map();   // error key -> time of its last alert
let errTimer = null;

function startErrorWatch() {
  try {
    fs.mkdirSync(ERR_DIR, { recursive: true });
    // Start at the end of each file: errors from before launch never alert.
    for (const f of fs.readdirSync(ERR_DIR)) if (isErrLog(f)) errOffsets.set(f, fs.statSync(path.join(ERR_DIR, f)).size);
    const w = fs.watch(ERR_DIR, (_e, name) => {
      if (name && !isErrLog(String(name))) return;
      clearTimeout(errTimer);
      errTimer = setTimeout(readNewErrors, 200);   // errors arriving together make one alert
    });
    w.on('error', () => { });
  } catch { }
}
function isErrLog(f) { return f.endsWith('.jsonl') && !f.endsWith('.old.jsonl'); }

function readNewErrors() {
  const fresh = [];
  let names = [];
  try { names = fs.readdirSync(ERR_DIR).filter(isErrLog); } catch { return; }
  for (const f of names) {
    const file = path.join(ERR_DIR, f);
    let size = 0;
    try { size = fs.statSync(file).size; } catch { continue; }
    let from = errOffsets.has(f) ? errOffsets.get(f) : 0;   // a new site's file is read from the start
    if (size < from) from = 0;                               // cleared or rotated
    if (size === from) { errOffsets.set(f, size); continue; }
    const buf = Buffer.alloc(Math.min(size - from, 1048576));
    let got = 0;
    try { const fd = fs.openSync(file, 'r'); got = fs.readSync(fd, buf, 0, buf.length, from); fs.closeSync(fd); } catch { continue; }
    const text = buf.toString('utf8', 0, got);
    const end = text.lastIndexOf('\n');            // a line still being written waits for the next look
    if (end < 0) continue;
    errOffsets.set(f, from + Buffer.byteLength(text.slice(0, end + 1)));
    const site = f.replace(/\.jsonl$/, '');
    for (const ln of text.slice(0, end).split('\n')) {
      try { const e = JSON.parse(ln); e.site = site; fresh.push(e); } catch { }
    }
  }
  if (fresh.length) alertErrors(fresh);
}

function alertErrors(list) {
  const level = (settings && settings.errorAlerts) || 'fatal';
  if (level === 'off') return;
  let muted = [];
  try { muted = JSON.parse(fs.readFileSync(ERR_MUTED, 'utf8')); } catch { }
  const now = Date.now();
  const show = [];
  for (const e of list) {
    const sev = errSeverity(e.type);
    if (SEV_RANK[sev] < LEVEL_MIN[level] || muted.includes(e.site)) continue;
    const file = String(e.file || '').replace(/\//g, '\\');
    const key = `${e.site}|${e.type}|${file}|${e.line}|${e.msg}`;
    if (now - (errAlerted.get(key) || 0) < 600000) continue;
    errAlerted.set(key, now);
    show.push({ ...e, sev, file, key });
  }
  if (!show.length) return;
  for (const [k, t] of errAlerted) if (now - t > 600000) errAlerted.delete(k);
  show.sort((a, b) => SEV_RANK[b.sev] - SEV_RANK[a.sev]);
  const top = show[0];
  const sites = [...new Set(show.map(e => e.site))];

  // Already looking at that list: the window shows it, no toast.
  if (win && win.isVisible() && win.isFocused() && !win.isMinimized()) {
    const hash = decodeURIComponent((win.webContents.getURL().split('#')[1] || ''));
    if (hash.startsWith('errors') || (sites.length === 1 && hash === `site/${sites[0]}/errors`)) return;
  }

  const root = path.join(BASE, 'sites', top.site, 'public') + '\\';
  const rel = top.file.toLowerCase().startsWith(root.toLowerCase()) ? top.file.slice(root.length) : path.basename(top.file);
  const msg = String(top.msg || '').replace(` in ${top.file}:${top.line}`, '');
  const title = show.length === 1 ? `${SEV_NAME[top.sev]} · ${top.site}`
    : `${show.length} new errors · ${sites.length === 1 ? top.site : `${sites.length} sites`}`;
  const body = `${msg}\n${rel}:${top.line}${show.length > 1 ? `\n+${show.length - 1} more` : ''}`;
  // The dashboard's id for an error group: md5 of the same key, first 8 bytes.
  const id = crypto.createHash('md5').update(top.key).digest('hex').slice(0, 16);
  const target = show.length === 1 ? `#errors/${id}` : sites.length === 1 ? `#site/${encodeURIComponent(top.site)}/errors` : '#errors';
  notify(title, body, top.sev === 'fatal' ? 'err' : top.sev === 'warning' ? 'warn' : 'info', () => {
    showWindow();
    if (win) win.webContents.executeJavaScript(`location.hash = ${JSON.stringify(target)}`).catch(() => { });
  }, { sticky: top.sev === 'fatal', silent: SEV_RANK[top.sev] < 2 });
}

// ---- taskbar progress and tray colour -----------------------------------------
function showProgress(st) {
  if (!win) return;
  if (!st || !st.busy) return win.setProgressBar(-1);
  const p = st.progress;
  if (p && p.pct >= 0) win.setProgressBar(Math.min(p.pct, 100) / 100);
  else win.setProgressBar(1, { mode: 'indeterminate' });
}

// App icon with a status dot (green running, amber busy or partly up; no dot
// when stopped), drawn into the bitmap so no extra image files are needed.
const DOT = { live: [0x3D, 0xBB, 0x80], busy: [0xE3, 0xAA, 0x3A] };
const trayImages = {};
function trayImage(kind) {
  if (trayImages[kind]) return trayImages[kind];
  const S = 32;
  const src = nativeImage.createFromPath(path.join(ICONS, 'icon-192.png')).resize({ width: S, height: S, quality: 'best' });
  const px = Buffer.from(src.toBitmap());                     // BGRA, premultiplied
  const paint = (cx, cy, r, [R, G, B]) => {
    for (let y = 0; y < S; y++) for (let x = 0; x < S; x++) {
      const a = Math.max(0, Math.min(1, r + 0.5 - Math.hypot(x + 0.5 - cx, y + 0.5 - cy)));
      if (!a) continue;
      const i = (y * S + x) * 4;
      px[i]     = B * a + px[i]     * (1 - a);
      px[i + 1] = G * a + px[i + 1] * (1 - a);
      px[i + 2] = R * a + px[i + 2] * (1 - a);
      px[i + 3] = 255 * a + px[i + 3] * (1 - a);
    }
  };
  if (DOT[kind]) {                                           // stopped: plain icon, no dot
    paint(24, 24, 8.5, [0x14, 0x18, 0x1F]);                  // dark ring so the dot reads on any icon
    paint(24, 24, 6.5, DOT[kind]);
  }
  return (trayImages[kind] = nativeImage.createFromBitmap(px, { width: S, height: S, scaleFactor: 2 }));
}

function trayKind(st) {
  if (!st) return 'off';
  if (st.busy) return 'busy';
  const svc = Object.values(st.services || {});
  if (svc.length && svc.every(Boolean)) return 'live';
  return svc.some(Boolean) ? 'busy' : 'off';
}

// ---- update notice -------------------------------------------------------------
let update = null;   // { version, url } when GitHub has a newer release

const vparts = v => String(v).trim().replace(/^v/i, '').split('.').map(n => parseInt(n, 10) || 0);
function isNewer(a, b) {
  const x = vparts(a), y = vparts(b);
  for (let i = 0; i < Math.max(x.length, y.length); i++) {
    const d = (x[i] || 0) - (y[i] || 0);
    if (d) return d > 0;
  }
  return false;
}

async function checkUpdate() {
  let have = '';
  try { have = fs.readFileSync(path.join(BASE, 'VERSION'), 'utf8').trim(); } catch { return; }
  try {
    const r = await fetch(`https://api.github.com/repos/${UPDATE_REPO}/releases/latest`,
      { headers: { 'User-Agent': 'localhost-wp', Accept: 'application/vnd.github+json' } });
    if (!r.ok) return;
    const rel = await r.json();
    update = isNewer(rel.tag_name, have) ? { version: String(rel.tag_name).replace(/^v/i, ''), url: rel.html_url } : null;
  } catch { return; }   // offline: try again later
  if (tray) buildMenu();
  if (!update) return;
  // One notification per new version; the tray menu keeps the link.
  const seenFile = path.join(app.getPath('userData'), 'update-seen.txt');
  let seen = '';
  try { seen = fs.readFileSync(seenFile, 'utf8').trim(); } catch { }
  if (seen === update.version) return;
  try { fs.writeFileSync(seenFile, update.version); } catch { }
  const url = update.url;
  notify('localhost-wp - update available', `Version ${update.version} is out (you have ${have}). Click to open the release page.`, 'info',
    () => shell.openExternal(url));
}

// ---- tray ------------------------------------------------------------------
const LABEL = { start: 'Starting stack', stop: 'Stopping stack', 'stop-nobackup': 'Stopping stack', reload: 'Reloading Nginx',
  setup: 'Running setup', 'new-site': 'Creating site', backup: 'Backing up', delete: 'Deleting site',
  'mail-on': 'Turning mail catcher on', 'mail-off': 'Turning mail catcher off' };

function statusText(st) {
  if (!st) return 'Dashboard not reachable';
  if (st.busy) return `${LABEL[st.busy] || 'Working'}...`;
  if ((st.foreign || []).length) return `Another stack running: ${st.foreign[0].root}`;
  if (!st.setup) return 'Setup needed';
  const up = Object.values(st.services).filter(Boolean).length;
  return up === 3 ? 'All services running' : up ? `${up} of 3 services running` : 'Stack stopped';
}

// Same question the dashboard's switch asks, as a native box (the tray has no page).
async function toggleMailCatcher() {
  const st = status;
  buildMenu();   // undo the checkbox's own tick until the switch really happens
  if (!st || !st.mail || st.busy) return;
  const on = !st.mail.enabled;
  const { response } = await dialog.showMessageBox({
    type: on ? 'question' : 'warning',
    title: 'localhost-wp',
    message: on ? 'Turn the mail catcher on?' : 'Turn the mail catcher off?',
    detail: (on
      ? 'Mail from your sites lands in the local inbox and nothing goes out, SMTP plugins included.'
      : 'Sites send mail the normal way again. Sites with an SMTP plugin set up will really send to real addresses. Mail already in the inbox is kept.')
      + '\n\n' + (st.services.php
        ? 'PHP restarts for about a second to pick this up. MySQL and Nginx keep running.'
        : 'Applies the next time the stack starts.'),
    buttons: [on ? 'Turn on' : 'Turn off', 'Cancel'], defaultId: 0, cancelId: 1, noLink: true,
  });
  if (response === 0) act('/api/mail', { on });
}

function mailLabel(st) {
  const n = (st && st.mail && st.mail.unread) || 0;
  return n ? `Mail inbox (${n} unread)` : 'Mail inbox';
}

function buildMenu() {
  const st = status;
  const busy = !st || !!st.busy;
  const svc = st ? Object.values(st.services) : [];
  const all = svc.length && svc.every(Boolean);
  const any = svc.some(Boolean);
  const blocked = st && (st.foreign || []).length;

  tray.setImage(trayImage(trayKind(st)));
  tray.setToolTip(`localhost-wp - ${BASE}\n${statusText(st)}`.slice(0, 127));
  tray.setContextMenu(Menu.buildFromTemplate([
    { label: BASE, enabled: false },
    { label: statusText(st), enabled: false },
    ...(update ? [{ label: `Update available: ${update.version} (open release page)`, click: () => shell.openExternal(update.url) }] : []),
    { type: 'separator' },
    { label: 'Open Control Panel', click: showWindow },
    { label: 'Start stack', enabled: !busy && !!st.setup && !all && !blocked, click: () => act('/api/stack/start') },
    { label: 'Stop stack (with backup)', visible: any, enabled: !busy, click: () => act('/api/stack/stop', { backup: true }) },
    { label: 'Stop stack (no backup)', visible: any, enabled: !busy, click: () => act('/api/stack/stop', { backup: false }) },
    { label: 'phpMyAdmin', visible: !!all, click: () => shell.openExternal('http://localhost:8080') },
    { label: mailLabel(st), visible: !!(st && st.mail && st.mail.running), click: () => shell.openExternal('http://localhost:8025') },
    { label: 'Mail catcher', type: 'checkbox', checked: !!(st && st.mail && st.mail.enabled),
      visible: !!(st && st.mail && st.mail.enabled != null), enabled: !busy, click: toggleMailCatcher },
    { label: 'Open stack folder', click: () => shell.openPath(BASE) },
    { type: 'separator' },
    { label: 'Stop stack and quit', visible: any, enabled: !busy, click: stopAndQuit },
    { label: any ? 'Quit (stack keeps running)' : 'Quit', click: quit },
  ]));
}

// Results show up in the window's Activity log, like clicks made there.
function act(p, body) {
  api('POST', p, body).catch(() => { }).finally(poll);
}

let pollTimer = null;
let job = null;          // { name, task, afterSeq } while a job runs
let lastSeq = 0;
async function poll() {
  clearTimeout(pollTimer);
  try { status = await api('GET', '/api/status'); } catch { status = null; }
  if (status && status.settings) { settings = status.settings; applyLoginItem(); }
  const busy = status?.busy || null;
  if (busy && !job) job = { name: busy, task: status.task, afterSeq: lastSeq };
  else if (!busy && job && status) { jobDone(job.name, job.task, job.afterSeq); job = null; }
  if (status) lastSeq = status.seq;
  mailCheck(status && status.mail);
  showProgress(status);
  if (tray) buildMenu();
  pollTimer = setTimeout(poll, busy ? 1000 : 4000);
}

async function stopAndQuit() {
  showWindow();
  // Settings > Stack > "When I stop the stack" decides the database backup.
  let backup = (settings && settings.stopBackup) !== 'none';
  if (settings && settings.stopBackup === 'ask') {
    const { response } = await dialog.showMessageBox(win, {
      type: 'question',
      title: 'localhost-wp',
      message: 'Back up the databases before stopping?',
      detail: "Backups go to each site's sql folder.",
      buttons: ['Back up and quit', "Don't back up", 'Cancel'],
      defaultId: 0,
      cancelId: 2,
      noLink: true,
    });
    if (response === 2) return;
    backup = response === 0;
  }
  try { await api('POST', '/api/stack/stop', { backup }); }
  catch { return poll(); }   // busy with something else: stay open, the log says why
  await waitIdle();   // the stop (and its database backup) finishes before leaving
  quit();
}

// Quitting always ends the process: the dashboard server and the tray icon go
// first, and if Electron has not exited 3 s after app.quit() (a pending handle
// can keep it alive with no window and no tray), it is ended outright.
function quit() {
  quitting = true;
  stopServer();
  try { if (tray) { tray.destroy(); tray = null; } } catch { }
  app.quit();
  setTimeout(() => app.exit(0), 3000);
}

function stopServer() {
  if (!serverProc || serverProc.exitCode !== null) return;
  try { serverProc.kill(); } catch { }
}

// ---- start -----------------------------------------------------------------
if (!app.requestSingleInstanceLock()) {
  app.quit();
} else {
  app.on('second-instance', showWindow);
  app.on('window-all-closed', () => { if (quitting) app.quit(); });
  app.on('before-quit', () => { quitting = true; });
  // However the app ends (tray Quit, closing, Windows sign-out), its dashboard server ends with it.
  app.on('will-quit', stopServer);
  app.on('quit', stopServer);

  app.whenReady().then(async () => {
    try {
      await startServer();
      await readToken();
      try { settings = await api('GET', '/api/settings'); } catch { }
    } catch (e) {
      dialog.showErrorBox('localhost-wp', `The Control Panel could not start.\n\n${e.message}`);
      app.exit(1);
      return;
    }
    tray = new Tray(trayImage('off'));
    tray.on('click', showWindow);
    tray.on('balloon-click', () => { const f = balloonAction; balloonAction = null; if (f) f(); });
    createWindow();
    ensureToastShortcut();
    startErrorWatch();
    applyLoginItem();
    // Sign-in start with "Start the stack too": start it unless it already runs.
    if (atStartup && settings && settings.startupStack) {
      try {
        const st = await api('GET', '/api/status');
        if (st.setup && !st.busy && !(st.foreign || []).length && !Object.values(st.services).every(Boolean)) await api('POST', '/api/stack/start');
      } catch { }
    }
    poll();
    setTimeout(checkUpdate, 15000);
    setInterval(checkUpdate, 6 * 3600 * 1000);
  });
}
