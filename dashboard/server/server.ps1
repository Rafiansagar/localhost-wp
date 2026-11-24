# ============================================================================
#  server.ps1  -  localhost-wp web dashboard (no install; .NET HttpListener)
#  ----------------------------------------------------------------------------
#  Serves index.html on http://localhost:<Port>/ and a small JSON API that
#  calls the stack's own scripts\cp-*.ps1 functions (via bridge.ps1).
#  Long operations run in worker.ps1 on a background runspace, one at a time.
#
#  Safety: listens on localhost only, checks the Host header, and every API
#  call must carry the per-run token embedded in the served page.
#  Exits by itself a few seconds after the dashboard window closes.
#
#  Each stack folder gets its own port: 7070 if free, else the next one up, so
#  two stacks side by side never answer for each other.
#  -ParentPid: started by the Electron shell; exit when that process is gone.
# ============================================================================
param([string]$Base, [int]$Port = 7070, [switch]$NoWindow, [switch]$Restarted, [int]$ParentPid = 0)

$baseArg = $Base

Add-Type -AssemblyName System.Windows.Forms

$Root = Split-Path -Parent $PSScriptRoot

function Test-Stack([string]$dir) { $dir -and (Test-Path (Join-Path $dir 'scripts\cp-core.ps1')) }

# Stack root: -Base, else the nearest folder at or above this dashboard that
# holds scripts\cp-core.ps1, else the path in base.txt (dashboard kept elsewhere).
if (-not $Base) {
    $dir = $Root
    while ($dir -and -not (Test-Stack $dir)) { $dir = Split-Path -Parent $dir }
    $Base = $dir
}
if (-not $Base) {
    $baseFile = Join-Path $Root 'base.txt'
    if (Test-Path $baseFile) { $Base = "$(Get-Content -LiteralPath $baseFile -TotalCount 1)".Trim() }
}
if (-not (Test-Stack $Base)) {
    [System.Windows.Forms.MessageBox]::Show(
        "No localhost-wp stack found above:`r`n$Root`r`n`r`nKeep the dashboard folder inside the stack folder, or write the stack path in dashboard\base.txt.",
        'localhost-wp dashboard', 'OK', 'Error') | Out-Null
    exit 1
}
$Base = (Resolve-Path -LiteralPath $Base).Path

function Open-Window {
    if (-not $NoWindow) {
        try { Start-Process 'msedge' -ArgumentList "--app=$url", '--window-size=1440,900' -ErrorAction Stop }
        catch { Start-Process $url }
    }
}

# The Electron shell reads the chosen port from this line on stdout.
function Write-PortLine {
    try { [Console]::Out.WriteLine("CP_PORT=$Port"); [Console]::Out.Flush() } catch { }
}

# Stack folder served by the dashboard on $p, or $null if none answers there.
function Get-DashboardBase([int]$p) {
    try {
        $r = Invoke-RestMethod -Uri "http://localhost:$p/api/whoami" -TimeoutSec 2 -UseBasicParsing
        if ($r.app -eq 'localhost-wp') { return "$($r.base)".TrimEnd('\') }
    } catch { }
    return $null
}

# First free port from $Port up. One held by this same stack's dashboard means
# it is already running: open a window on that one instead of starting twice.
$listener = $null
for ($p = $Port; $p -lt $Port + 30; $p++) {
    $l = New-Object System.Net.HttpListener
    $l.Prefixes.Add("http://localhost:$p/")
    try { $l.Start(); $listener = $l; $Port = $p; break }
    catch {
        $l.Close()
        if ((Get-DashboardBase $p) -eq $Base.TrimEnd('\')) {
            $Port = $p
            $url = "http://localhost:$Port/"
            Write-PortLine
            Open-Window
            exit 0
        }
    }
}
if (-not $listener) {
    [System.Windows.Forms.MessageBox]::Show(
        "No free port for the dashboard between $Port and $($Port + 29).",
        'localhost-wp dashboard', 'OK', 'Error') | Out-Null
    exit 1
}
$url = "http://localhost:$Port/"

# ---- shared state (read by this thread, written by the worker too) ---------
$shared = [hashtable]::Synchronized(@{
    Log      = New-Object System.Collections.ArrayList
    Seq      = 0
    Busy     = $null
    Progress = $null
})

. (Join-Path $PSScriptRoot 'bridge.ps1')

# Version lookup shared with setup.ps1 (absent in stacks older than versions.json).
$versionsHelper = Join-Path $script:HelperDir 'versions.ps1'
if (Test-Path $versionsHelper) { . $versionsHelper }
$script:phpVersionList = @()

# What the setup dialog offers: PHP builds from windows.php.net, the fixed parts from versions.json.
function Get-SetupOptions {
    if (-not (Get-Command Get-StackVersions -ErrorAction SilentlyContinue) -or -not (Test-Path (Join-Path $script:BASE 'versions.json'))) {
        return @{ php = $null; fixed = $null }
    }
    $v = Get-StackVersions $script:BASE
    # windows.php.net is fetched once per server run (an empty list, i.e. offline, is retried);
    # the minimum is applied on every call so edits to versions.json show up straight away.
    if (-not $script:phpVersionList.Count) { $script:phpVersionList = @(Get-PhpVersionList '0.0') }
    $allowed = @($script:phpVersionList | Where-Object { [version]$_ -ge [version]$v.php.min })
    $installed = $null
    if (Test-Path (Join-Path $script:BASE 'php\php-cgi.exe')) {
        $installed = Get-BinVersion 'php' 'php\php.exe' @('-v') 'PHP\s+([\d.]+)'
    }
    @{
        php   = @{ default = $v.php.default; min = $v.php.min; versions = $allowed; installed = $installed }
        fixed = [ordered]@{ nginx = $v.nginx.version; mysql = $v.mysql.version; phpmyadmin = $v.phpmyadmin.version }
    }
}

$token      = [guid]::NewGuid().ToString('N')
$indexPath  = Join-Path $Root 'index.html'
$workerPath = Join-Path $PSScriptRoot 'worker.ps1'
$hosts      = @('localhost')

# VS Code's own Code.exe: the code.cmd wrapper on PATH would flash a console window.
function Get-VsCodeExe {
    $c = @()
    $cmd = Get-Command code.cmd -ErrorAction SilentlyContinue
    if ($cmd) { $c += Join-Path (Split-Path -Parent (Split-Path -Parent $cmd.Source)) 'Code.exe' }   # <install>\bin\code.cmd
    $c += "$env:LOCALAPPDATA\Programs\Microsoft VS Code\Code.exe"
    if ($env:ProgramFiles) { $c += "$env:ProgramFiles\Microsoft VS Code\Code.exe" }
    $c | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
}
$script:VsCode = Get-VsCodeExe

$ip = Get-LocalIp
if ($ip -and $ip -ne '127.0.0.1') { $hosts += $ip }

# First number captured by $pattern in a stack config file, else $default.
function Get-ConfPort([string]$relPath, [string]$pattern, [int]$default) {
    $f = Join-Path $script:BASE $relPath
    if (Test-Path $f) {
        $m = [regex]::Match((Get-Content -Raw -LiteralPath $f), $pattern)
        if ($m.Success) { return [int]$m.Groups[1].Value }
    }
    return $default
}

function Get-Ports {
    [ordered]@{
        mysql = Get-ConfPort 'mysql\my.ini' '(?m)^\s*port\s*=\s*(\d+)' 3307
        php   = Get-ConfPort 'nginx\conf\nginx.conf' 'upstream\s+php\s*\{[^}]*?server\s+[\d.]+:(\d+)' 9000
        pma   = Get-ConfPort 'config\nginx\phpmyadmin.conf' 'listen\s+(\d+)' 8080
        home  = Get-ConfPort 'nginx\conf\nginx.conf' 'listen\s+(\d+)\s+default_server' 80
    }
}

# ---- stack info (what the stack's own index.html lists, read live) ---------
# Folders the dashboard may open in Explorer; nothing outside this list.
$script:Folders = [ordered]@{
    nginx      = @('nginx',        'Nginx binary and main config')
    mysql      = @('mysql',        'MySQL binaries, data, logs and my.ini')
    phpmyadmin = @('phpmyadmin',   'phpMyAdmin')
    mailpit    = @('mailpit',      'Mail catcher (Mailpit) and the mail it caught')
    sites      = @('sites',        'One folder per site; WordPress lives in sites\{name}\public')
    vhosts     = @('config\nginx', 'One .conf per site, loaded automatically')
    config     = @('config',       'ports.txt keeps the last assigned site port')
    logs       = @('logs',         'Per-site Nginx error logs and backup.log')
    dashboard  = @('dashboard',    'This Control Panel')
}

$script:verCache = @{}

# First match of $pattern in a binary's version output; cached once found.
function Get-BinVersion([string]$key, [string]$relExe, [string[]]$exeArgs, [string]$pattern) {
    if ($script:verCache[$key]) { return $script:verCache[$key] }
    $exe = Join-Path $script:BASE $relExe
    if (-not (Test-Path $exe)) { return $null }
    try {
        $out = (& $exe @exeArgs 2>&1 | ForEach-Object { "$_" }) -join "`n"
        $m = [regex]::Match($out, $pattern)
        if ($m.Success) { $script:verCache[$key] = $m.Groups[1].Value; return $m.Groups[1].Value }
    } catch { }
    return $null
}

function Get-StackInfo {
    $verFile = Join-Path $script:BASE 'VERSION'
    $pmaRel  = Get-ChildItem -LiteralPath (Join-Path $script:BASE 'phpmyadmin') -Filter 'RELEASE-DATE-*' -File -ErrorAction SilentlyContinue | Select-Object -First 1
    $myIni   = Join-Path $script:BASE 'mysql\my.ini'
    $dataDir = Join-Path $script:BASE 'mysql\data'
    if (Test-Path $myIni) {
        $m = [regex]::Match((Get-Content -Raw -LiteralPath $myIni), '(?m)^\s*datadir\s*=\s*(.+?)\s*$')
        if ($m.Success) { $dataDir = $m.Groups[1].Value.Replace('/', '\') }
    }
    [ordered]@{
        release  = if (Test-Path $verFile) { "$(Get-Content -LiteralPath $verFile -TotalCount 1)".Trim() } else { $null }
        base     = $script:BASE
        ports    = Get-Ports
        versions = [ordered]@{
            nginx      = Get-BinVersion 'nginx' 'nginx\nginx.exe' @('-v') 'nginx/([\d.]+)'
            mysql      = Get-BinVersion 'mysql' 'mysql\bin\mysqld.exe' @('--version') 'Ver\s+([\d.]+)'
            php        = Get-BinVersion 'php' 'php\php.exe' @('-v') 'PHP\s+([\d.]+)'
            phpmyadmin = if ($pmaRel) { $pmaRel.Name.Substring(13) } else { $null }
            mailpit    = Get-BinVersion 'mailpit' 'mailpit\mailpit.exe' @('version') 'v(\d+\.\d+\.\d+)'
        }
        mysql    = [ordered]@{ host = '127.0.0.1'; user = 'root'; config = $myIni; data = $dataDir }
        folders  = @($script:Folders.Keys | ForEach-Object {
            $p = Join-Path $script:BASE $script:Folders[$_][0]
            [ordered]@{ key = $_; path = $script:Folders[$_][0]; purpose = $script:Folders[$_][1]; exists = Test-Path $p }
        })
    }
}

# ---- background operations -------------------------------------------------
$script:op = $null
$script:opArg = ''
$script:wpZipSize = 0

# Content-Length of a download (0 if unknown), so progress can show a percentage.
function Get-RemoteSize([string]$url) {
    try {
        $req = [System.Net.WebRequest]::Create($url)
        $req.Method = 'HEAD'
        $req.Timeout = 4000
        $res = $req.GetResponse()
        $len = $res.ContentLength
        $res.Close()
        if ($len -gt 0) { return $len }
    } catch { }
    return 0
}

# Invoke-NewSite runs its download in a silent job, so progress is read from
# the files it leaves behind: wp.zip growing, then wp_tmp while extracting.
function Get-NewSiteProgress([string]$name) {
    $siteDir = Join-Path $script:SitesDir $name
    $zip = Join-Path $siteDir 'wp.zip'
    if (Test-Path (Join-Path $siteDir 'wp_tmp')) { return @{ pct = -1; text = 'Extracting WordPress...' } }
    if (Test-Path $zip) {
        $done  = (Get-Item -LiteralPath $zip).Length
        $total = $script:wpZipSize
        if ($total -gt 0 -and $done -ge $total) { return @{ pct = -1; text = 'Extracting WordPress...' } }
        if ($total -gt 0) {
            return @{ pct = [int](100 * $done / $total); text = ('Downloading WordPress - {0:N1} / {1:N1} MB' -f ($done / 1MB), ($total / 1MB)) }
        }
        return @{ pct = -1; text = ('Downloading WordPress - {0:N1} MB' -f ($done / 1MB)) }
    }
    if (Test-Path (Join-Path $siteDir 'public\wp-load.php')) { return @{ pct = -1; text = 'Writing wp-config and Nginx config...' } }
    return @{ pct = -1; text = 'Creating database...' }
}

function Start-Op([string]$action, [string]$arg = '') {
    if ($shared.Busy) { return $false }
    $shared.Busy = $action
    $script:opArg = $arg
    if ($action -eq 'new-site') { $script:wpZipSize = Get-RemoteSize 'https://wordpress.org/latest.zip' }
    $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    $iss.ExecutionPolicy = 'Bypass'
    $rs = [runspacefactory]::CreateRunspace($iss)
    $rs.Open()
    $rs.SessionStateProxy.SetVariable('shared', $shared)
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddCommand($workerPath).AddParameter('Base', $Base).AddParameter('Action', $action).AddParameter('Arg', $arg)
    $script:op = @{ ps = $ps; rs = $rs; handle = $ps.BeginInvoke() }
    return $true
}

# Called every loop pass: surfaces worker crashes and frees the busy slot.
function Complete-Op {
    $o = $script:op
    if (-not $o -or -not $o.handle.IsCompleted) { return }
    try { $o.ps.EndInvoke($o.handle) | Out-Null }
    catch { Write-Log "Operation '$($shared.Busy)' failed - $($_.Exception.InnerException.Message)" 'err' }
    foreach ($e in $o.ps.Streams.Error) { Write-Log "  $($e.Exception.Message)" 'err' }
    $o.ps.Dispose(); $o.rs.Dispose()
    $script:op = $null
    $shared.Progress = $null
    $shared.Busy = $null
}

# ---- read-only data (same checks as the WinForms site rows) ----------------
function Get-ServiceState {
    [ordered]@{
        mysql = Test-Proc 'mysqld'
        php   = Test-Proc 'php-cgi'
        nginx = Test-Proc 'nginx'
    }
}

# Mail catcher: separate from the three core services, so a stack without it
# still counts as fully running. Unread comes from Mailpit's own API.
function Get-MailState {
    $on = Test-Proc 'mailpit'
    $unread = 0; $total = 0; $latest = $null
    if ($on) {
        $res = $null
        try {
            $r = [System.Net.WebRequest]::Create('http://127.0.0.1:8025/api/v1/messages?limit=1')
            $r.Timeout = 500
            $res = $r.GetResponse()
            $sr = New-Object System.IO.StreamReader($res.GetResponseStream())
            $j = $sr.ReadToEnd() | ConvertFrom-Json
            $unread = [int]$j.unread
            $total  = [int]$j.total
            # Newest message, for the "new mail" notification.
            $m = @($j.messages)[0]
            if ($m) {
                $from = if ($m.From.Name) { $m.From.Name } else { $m.From.Address }
                $latest = [ordered]@{ id = $m.ID; subject = "$($m.Subject)"; from = "$from"; to = "$(@($m.To)[0].Address)" }
            }
        } catch { } finally { if ($res) { $res.Close() } }
    }
    [ordered]@{
        enabled   = [bool](Get-MailCatcherOn)
        installed = Test-Path (Join-Path $script:BASE 'mailpit\mailpit.exe')
        running   = $on
        unread    = $unread
        total     = $total
        latest    = $latest
        url       = 'http://localhost:8025'
    }
}

function Get-SiteRows {
    $dbList  = Get-DbList
    $mysqlUp = $null -ne $dbList
    foreach ($s in Get-Sites) {
        if (-not $s.Enabled)                                   { $srv = 'disabled' }
        elseif ($s.Http -and (Test-Port ([int]$s.Http)))       { $srv = 'live' }
        else                                                   { $srv = 'offline' }

        if (-not $mysqlUp)                 { $db = 'unknown' }
        elseif ($dbList -contains $s.Name) { $db = 'yes' }
        else                               { $db = 'no' }

        [pscustomobject]@{
            name   = $s.Name
            port   = $s.Http
            server = $srv
            db     = $db
            config = Test-Path (Join-Path $script:SitesDir "$($s.Name)\public\wp-config.php")
        }
    }
}

function Get-LogAfter([int]$after) {
    [System.Threading.Monitor]::Enter($shared.SyncRoot)
    try { return @($shared.Log | Where-Object { $_.id -gt $after }) }
    finally { [System.Threading.Monitor]::Exit($shared.SyncRoot) }
}

# Only names that exist as a vhost reach delete/backup (no path tricks).
function Test-KnownSite([string]$name) {
    if ($name -notmatch '^[a-zA-Z0-9_-]+$') { return $false }
    return [bool](Get-Sites | Where-Object { $_.Name -eq $name })
}

# ---- HTTP plumbing ---------------------------------------------------------
function Send-Bytes($ctx, [byte[]]$bytes, [string]$type, [int]$code = 200) {
    $r = $ctx.Response
    $r.StatusCode = $code
    $r.ContentType = $type
    $r.Headers['Cache-Control'] = 'no-store'
    $r.ContentLength64 = $bytes.Length
    $r.OutputStream.Write($bytes, 0, $bytes.Length)
    $r.Close()
}

function Send-Json($ctx, $obj, [int]$code = 200) {
    $json = ConvertTo-Json -InputObject $obj -Depth 6 -Compress
    Send-Bytes $ctx ([System.Text.Encoding]::UTF8.GetBytes($json)) 'application/json; charset=utf-8' $code
}

function Send-Error($ctx, [int]$code, [string]$msg) { Send-Json $ctx @{ error = $msg } $code }

function Read-Body($req) {
    if (-not $req.HasEntityBody) { return $null }
    $sr = New-Object System.IO.StreamReader($req.InputStream, [System.Text.Encoding]::UTF8)
    $txt = $sr.ReadToEnd(); $sr.Close()
    if ($txt) { return $txt | ConvertFrom-Json }
    return $null
}

function Send-Started($ctx, [string]$action, [string]$arg = '') {
    if (Start-Op $action $arg) { Send-Json $ctx @{ started = $action } 202 }
    else { Send-Error $ctx 409 "Busy with '$($shared.Busy)'. Wait for it to finish." }
}

function Handle-Request($ctx) {
    $req    = $ctx.Request
    $path   = $req.Url.AbsolutePath
    $method = $req.HttpMethod

    if ($req.Headers['Host'] -ne "localhost:$Port") { Send-Error $ctx 403 'Wrong host.'; return }

    if ($path -eq '/' -and $method -eq 'GET') {
        # Base, hosts and ports go into the page itself so the first paint is complete.
        $boot = (ConvertTo-Json -InputObject @{ base = $script:BASE; hosts = $hosts; ports = Get-Ports; vscode = [bool]$script:VsCode } -Compress).Replace('</', '<\/')
        $html = [System.IO.File]::ReadAllText($indexPath).Replace('__CP_TOKEN__', $token).Replace('__CP_BOOT__', $boot)
        Send-Bytes $ctx ([System.Text.Encoding]::UTF8.GetBytes($html)) 'text/html; charset=utf-8'
        return
    }
    # App icons (window and taskbar). The name pattern keeps requests inside dashboard\icons.
    if ($method -eq 'GET' -and $path -match '^/icons/(icon(-\d+)?\.(png|svg))$') {
        $file = Join-Path (Join-Path $Root 'icons') $Matches[1]
        if (Test-Path -LiteralPath $file) {
            $type = if ($Matches[3] -eq 'svg') { 'image/svg+xml' } else { 'image/png' }
            Send-Bytes $ctx ([System.IO.File]::ReadAllBytes($file)) $type
        } else { Send-Error $ctx 404 'Not found.' }
        return
    }
    # Tokenless on purpose: a second launch asks which stack owns this port.
    if ($path -eq '/api/whoami' -and $method -eq 'GET') {
        Send-Json $ctx @{ app = 'localhost-wp'; base = $script:BASE }
        return
    }
    if (-not $path.StartsWith('/api/')) { Send-Error $ctx 404 'Not found.'; return }

    $tok = $req.Headers['X-Token']
    if (-not $tok) { $tok = $req.QueryString['t'] }
    if ($tok -ne $token) { Send-Error $ctx 403 'Bad token. Reload the dashboard.'; return }

    $route = "$method $path"
    switch -Regex ($route) {
        '^GET /api/info$' {
            Send-Json $ctx @{ base = $script:BASE; hosts = $hosts; ports = Get-Ports }
            return
        }
        '^GET /api/setup-options$' {
            Send-Json $ctx (Get-SetupOptions)
            return
        }
        '^GET /api/stackinfo$' {
            Send-Json $ctx (Get-StackInfo)
            return
        }
        '^POST /api/open-path$' {
            $key = "$((Read-Body $req).key)"
            if (-not $script:Folders.Contains($key)) { Send-Error $ctx 404 'Unknown folder.'; return }
            $dir = Join-Path $script:BASE $script:Folders[$key][0]
            if (Test-Path $dir) { Start-Process explorer.exe $dir; Write-Log "Opened folder $($script:Folders[$key][0])" }
            else { Write-Log "Folder not created yet: $dir" 'warn' }
            Send-Json $ctx @{ ok = $true }
            return
        }
        '^GET /api/status$' {
            $svc = Get-ServiceState
            if ($req.QueryString['log'] -eq '1') {
                $running = @($svc.Keys | Where-Object { $svc[$_] })
                $stopped = @($svc.Keys | Where-Object { -not $svc[$_] })
                $names = @{ mysql = 'MySQL'; php = 'PHP'; nginx = 'Nginx' }
                $runTxt  = if ($running.Count) { ($running | ForEach-Object { $names[$_] }) -join ', ' } else { 'none' }
                $stopTxt = if ($stopped.Count) { ($stopped | ForEach-Object { $names[$_] }) -join ', ' } else { 'none' }
                $lvl = if (-not $stopped.Count) { 'ok' } elseif (-not $running.Count) { 'err' } else { 'warn' }
                Write-Log "Status -> running: $runTxt  |  stopped: $stopTxt" $lvl
            }
            # While this stack stops, its own processes are mid-exit; no check then.
            $foreign = @()
            if ($shared.Busy -notin 'stop', 'stop-nobackup') { $foreign = @(Get-ForeignStacks) }
            Send-Json $ctx @{
                setup    = [bool](Test-IsSetup)
                missing  = @(Get-MissingParts)
                services = $svc
                mail     = Get-MailState
                foreign  = $foreign
                busy     = $shared.Busy
                task     = $script:opArg
                progress = if ($shared.Busy -eq 'new-site') { Get-NewSiteProgress $script:opArg } else { $shared.Progress }
                seq      = $shared.Seq
            }
            return
        }
        '^GET /api/sites$' {
            Send-Json $ctx @{ sites = @(Get-SiteRows) }
            return
        }
        '^GET /api/log$' {
            $after = 0; [void][int]::TryParse("$($req.QueryString['after'])", [ref]$after)
            Send-Json $ctx @{ entries = @(Get-LogAfter $after) }
            return
        }
        '^POST /api/setup$' {
            $php = "$((Read-Body $req).php)".Trim()
            if ($php -and $php -notmatch '^\d+\.\d+\.\d+$') { Send-Error $ctx 400 "Invalid PHP version '$php'."; return }
            Send-Started $ctx 'setup' $php
            return
        }
        '^POST /api/stack/start$'  { Send-Started $ctx 'start'; return }
        '^POST /api/stack/reload$' { Send-Started $ctx 'reload'; return }
        '^POST /api/stack/stop$' {
            $body = Read-Body $req
            if ($body -and $body.backup -eq $false) { Send-Started $ctx 'stop-nobackup' } else { Send-Started $ctx 'stop' }
            return
        }
        '^POST /api/mail$' {
            # Mail catcher switch: { on: true | false }
            $body = Read-Body $req
            if (-not $body -or $body.on -isnot [bool]) { Send-Error $ctx 400 'Send { "on": true } or { "on": false }.'; return }
            Send-Started $ctx $(if ($body.on) { 'mail-on' } else { 'mail-off' })
            return
        }
        '^POST /api/sites$' {
            $name = "$((Read-Body $req).name)".Trim()
            if ($name -notmatch '^[a-zA-Z0-9_-]+$') { Send-Error $ctx 400 'Use letters, numbers, - or _ in the site name.'; return }
            Send-Started $ctx 'new-site' $name
            return
        }
        '^POST /api/sites/([^/]+)/(backup|delete|open-dir|open-code)$' {
            $name = [uri]::UnescapeDataString($Matches[1]); $act = $Matches[2]
            if (-not (Test-KnownSite $name)) { Send-Error $ctx 404 "No site named '$name'."; return }
            if ($act -eq 'backup') { Send-Started $ctx 'backup' $name; return }
            if ($act -eq 'delete') {
                if ("$((Read-Body $req).confirm)" -cne $name) {
                    Write-Log "Delete '$name' cancelled (name did not match)." 'warn'
                    Send-Error $ctx 400 'Type the site name exactly to confirm.'
                    return
                }
                Send-Started $ctx 'delete' $name
                return
            }
            $siteDir = Join-Path $script:SitesDir $name
            if ($act -eq 'open-code') {
                # The WordPress root (public\) when there is one, else the site folder.
                $dir = if (Test-Path (Join-Path $siteDir 'public')) { Join-Path $siteDir 'public' } else { $siteDir }
                $rel = $dir.Substring($script:BASE.Length).TrimStart('\')
                if (-not $script:VsCode)      { Write-Log 'VS Code not found on this PC.' 'err' }
                elseif (-not (Test-Path $dir)) { Write-Log "Directory not found: $dir" 'err' }
                else { Start-Process -FilePath $script:VsCode -ArgumentList "`"$dir`""; Write-Log "Opened $rel in VS Code" }
                Send-Json $ctx @{ ok = $true }
                return
            }
            if (Test-Path $siteDir) { Start-Process explorer.exe $siteDir; Write-Log "Opened folder sites\$name" }
            else { Write-Log "Directory not found: $siteDir" 'err' }
            Send-Json $ctx @{ ok = $true }
            return
        }
        '^POST /api/open$' {
            # Site links plus localhost on any port (phpMyAdmin, the stack's home page).
            $target = "$((Read-Body $req).url)"
            $hostRx = ($hosts | ForEach-Object { [regex]::Escape($_) }) -join '|'
            if ($target -notmatch "^http://($hostRx)(:\d+)?(/[^\s]*)?$") { Send-Error $ctx 400 'Only local site links can be opened.'; return }
            Open-Url $target
            Send-Json $ctx @{ ok = $true }
            return
        }
        '^POST /api/bye$' {
            # Window closing; a reload will hit us again within a few seconds and cancel this.
            $script:exitAt = (Get-Date).AddSeconds(5)
            Send-Json $ctx @{ ok = $true }
            return
        }
        default { Send-Error $ctx 404 'Unknown endpoint.' }
    }
}

# ---- main loop -------------------------------------------------------------
Write-Log "Base: $script:BASE"
if ($Restarted) { Write-Log 'Dashboard updated - server restarted with the new code.' 'ok' }
else { Open-Window }
Write-PortLine

# Newest change to this folder's scripts; when it moves, the server restarts
# itself so edits take effect without closing the window.
function Get-CodeStamp {
    (Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.ps1' -File | Sort-Object LastWriteTimeUtc | Select-Object -Last 1).LastWriteTimeUtc
}
$codeStamp = Get-CodeStamp
$seenStamp = $codeStamp
$restart = $false

$script:exitAt = $null
$lastHit = Get-Date
$pending = $listener.GetContextAsync()
while ($listener.IsListening) {
    if ($pending.Wait(1000)) {
        $ctx = $pending.Result
        $pending = $listener.GetContextAsync()
        $lastHit = Get-Date
        if ($ctx.Request.Url.AbsolutePath -ne '/api/bye') { $script:exitAt = $null }
        try { Handle-Request $ctx }
        catch {
            try { Send-Error $ctx 500 $_.Exception.Message } catch { }
        }
    }
    Complete-Op
    if (-not $shared.Busy) {
        if ($ParentPid -and -not (Get-Process -Id $ParentPid -ErrorAction SilentlyContinue)) { break }
        if ($script:exitAt -and (Get-Date) -gt $script:exitAt) { break }
        # No window has polled for 3 minutes (minimised windows still poll about once a minute).
        if (((Get-Date) - $lastHit).TotalSeconds -gt 180) { break }
        # Restart only once the files have stopped changing (no half-saved script).
        $now = Get-CodeStamp
        if ($now -ne $codeStamp -and $now -eq $seenStamp) { $restart = $true; break }
        $seenStamp = $now
    }
}
$listener.Stop()

if ($restart) {
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', "`"$PSCommandPath`"", '-Port', $Port, '-Restarted')
    if ($baseArg) { $argList += @('-Base', "`"$baseArg`"") }
    if ($NoWindow) { $argList += '-NoWindow' }
    if ($ParentPid) { $argList += @('-ParentPid', $ParentPid) }
    Start-Process powershell -ArgumentList $argList
}
