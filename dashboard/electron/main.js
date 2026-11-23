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
// ============================================================================
const { app, BrowserWindow, Tray, Menu, nativeImage, shell, dialog, screen } = require('electron');
const path = require('path');
const fs = require('fs');
const crypto = require('crypto');
const { spawn } = require('child_process');

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
      tray.displayBalloon({ iconType: 'info', title: 'localhost-wp', content: 'Still in the tray. Right-click the icon to quit.' });
    }
  });

  win.once('ready-to-show', () => win.show());
  win.loadURL(origin() + '/');
}

function showWindow() {
  if (!win) return;
  if (win.isMinimized()) win.restore();
  win.show();
  win.focus();
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

  tray.setToolTip(`localhost-wp - ${BASE}\n${statusText(st)}`.slice(0, 127));
  tray.setContextMenu(Menu.buildFromTemplate([
    { label: BASE, enabled: false },
    { label: statusText(st), enabled: false },
    { type: 'separator' },
    { label: 'Open Control Panel', click: showWindow },
    { label: 'Start stack', enabled: !busy && !!st.setup && !all && !blocked, click: () => act('/api/stack/start') },
    { label: 'Stop stack (backs up databases)', enabled: !busy && any, click: () => act('/api/stack/stop', { backup: true }) },
    { label: 'Open stack folder', click: () => shell.openPath(BASE) },
    { type: 'separator' },
    { label: 'Stop stack and quit', enabled: !busy && any, click: stopAndQuit },
    { label: 'Quit (stack keeps running)', click: quit },
  ]));
}

// Results show up in the window's Activity log, like clicks made there.
function act(p, body) {
  api('POST', p, body).catch(() => { }).finally(poll);
}

let pollTimer = null;
async function poll() {
  clearTimeout(pollTimer);
  try { status = await api('GET', '/api/status'); } catch { status = null; }
  if (tray) buildMenu();
  pollTimer = setTimeout(poll, status?.busy ? 1000 : 4000);
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
    tray = new Tray(fs.existsSync(APP_ICO) ? APP_ICO : nativeImage.createFromPath(path.join(ICONS, 'icon-32.png')));
    tray.on('click', showWindow);
    createWindow();
    poll();
  });
}
