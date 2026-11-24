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
const { app, BrowserWindow, Tray, Menu, nativeImage, shell, dialog, screen } = require('electron');
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
let hintShown = false;
let status = null;

// ---- backend ---------------------------------------------------------------
// server.ps1 picks a free port (7070 up) and prints "CP_PORT=<n>". If this
// stack's dashboard is already running it prints that port and exits.
function startServer() {
  return new Promise((resolve, reject) => {
    const ps = spawn('powershell.exe', [
      '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', SERVER,
      '-Base', BASE, '-NoWindow', '-ParentPid', String(process.pid),
    ], { windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] });

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
    minWidth: 760, minHeight: 520,
    show: false,
    autoHideMenuBar: true,
    icon: fs.existsSync(APP_ICO) ? APP_ICO : path.join(ICONS, 'icon-192.png'),
    title: `localhost-wp - ${BASE}`,
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
  win.webContents.setWindowOpenHandler(({ url }) => {
    if (/^https?:\/\//.test(url)) shell.openExternal(url);
    return { action: 'deny' };
  });
  win.webContents.on('will-navigate', (e, url) => {
    if (!url.startsWith(origin() + '/')) { e.preventDefault(); if (/^https?:\/\//.test(url)) shell.openExternal(url); }
  });

  // Closing hides to the tray; the stack keeps running either way.
  win.on('close', e => {
    if (quitting) return;
    e.preventDefault();
    win.hide();
    if (!hintShown && tray) {
      hintShown = true;
      notify('localhost-wp', 'Still in the tray. Right-click the icon to quit.', 'info', showWindow);
    }
  });

  // Windows shutdown, restart or sign-out.
  win.on('query-session-end', stopForShutdown);
  win.on('session-end', stopForShutdown);

  win.once('ready-to-show', () => win.show());
  win.loadURL(origin() + '/');
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
// Tray balloons: Windows 10/11 shows them as normal notifications, and unlike
// Electron's Notification they need no Start-menu registration.
let balloonAction = null;
function notify(title, content, level, onClick) {
  if (!tray) return;
  balloonAction = onClick || null;
  tray.displayBalloon({ title, content, iconType: { err: 'error', warn: 'warning' }[level] || 'info', respectQuietTime: true });
}

const DONE = { start: () => 'Start stack', stop: () => 'Stop stack', 'stop-nobackup': () => 'Stop stack', reload: () => 'Reload Nginx',
  setup: () => 'Setup', 'new-site': n => `New site: ${n}`, backup: n => `Backup: ${n}`, delete: n => `Delete site: ${n}` };

// A job just finished: tell how it went, unless the window is in front.
async function jobDone(job, task, afterSeq) {
  if (win && win.isVisible() && win.isFocused() && !win.isMinimized()) return;
  let entries = [];
  try { entries = (await api('GET', `/api/log?after=${afterSeq}`)).entries || []; } catch { }
  const last = [...entries].reverse().find(e => e.level !== 'info') || entries[entries.length - 1];
  if (!last) return;
  notify(`localhost-wp - ${(DONE[job] || (() => job))(task)}`, String(last.msg).trim(), last.level, showWindow);
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
  setup: 'Running setup', 'new-site': 'Creating site', backup: 'Backing up', delete: 'Deleting site' };

function statusText(st) {
  if (!st) return 'Dashboard not reachable';
  if (st.busy) return `${LABEL[st.busy] || 'Working'}...`;
  if ((st.foreign || []).length) return `Another stack running: ${st.foreign[0].root}`;
  if (!st.setup) return 'Setup needed';
  const up = Object.values(st.services).filter(Boolean).length;
  return up === 3 ? 'All services running' : up ? `${up} of 3 services running` : 'Stack stopped';
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
  const busy = status?.busy || null;
  if (busy && !job) job = { name: busy, task: status.task, afterSeq: lastSeq };
  else if (!busy && job && status) { jobDone(job.name, job.task, job.afterSeq); job = null; }
  if (status) lastSeq = status.seq;
  showProgress(status);
  if (tray) buildMenu();
  pollTimer = setTimeout(poll, busy ? 1000 : 4000);
}

async function stopAndQuit() {
  showWindow();
  try { await api('POST', '/api/stack/stop', { backup: true }); }
  catch { return poll(); }   // busy with something else: stay open, the log says why
  // Wait for the stop (and its database backup) to finish before leaving.
  for (let i = 0; i < 360; i++) {
    await new Promise(r => setTimeout(r, 500));
    try { if (!(await api('GET', '/api/status')).busy) break; } catch { break; }
  }
  quit();
}

function quit() {
  quitting = true;
  app.quit();
}

// ---- start -----------------------------------------------------------------
if (!app.requestSingleInstanceLock()) {
  app.quit();
} else {
  app.on('second-instance', showWindow);
  app.on('window-all-closed', () => { if (quitting) app.quit(); });
  app.on('before-quit', () => { quitting = true; });

  app.whenReady().then(async () => {
    try {
      await startServer();
      await readToken();
    } catch (e) {
      dialog.showErrorBox('localhost-wp', `The Control Panel could not start.\n\n${e.message}`);
      app.exit(1);
      return;
    }
    tray = new Tray(trayImage('off'));
    tray.on('click', showWindow);
    tray.on('balloon-click', () => { const f = balloonAction; balloonAction = null; if (f) f(); });
    createWindow();
    poll();
    setTimeout(checkUpdate, 15000);
    setInterval(checkUpdate, 6 * 3600 * 1000);
  });
}
