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
# ============================================================================
param([string]$Base, [int]$Port = 7070, [switch]$NoWindow)

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

$url = "http://localhost:$Port/"

function Open-Window {
    if (-not $NoWindow) {
        try { Start-Process 'msedge' -ArgumentList "--app=$url", '--window-size=1440,900' -ErrorAction Stop }
        catch { Start-Process $url }
    }
}

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add($url)
try { $listener.Start() }
catch {
    # Already running: just bring up another window on it.
    Open-Window
    exit 0
}

# ---- shared state (read by this thread, written by the worker too) ---------
$shared = [hashtable]::Synchronized(@{
    Log      = New-Object System.Collections.ArrayList
    Seq      = 0
    Busy     = $null
    Progress = $null
})

. (Join-Path $PSScriptRoot 'bridge.ps1')

$token      = [guid]::NewGuid().ToString('N')
$indexPath  = Join-Path $Root 'index.html'
$workerPath = Join-Path $PSScriptRoot 'worker.ps1'
$hosts      = @('localhost')
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
        $html = [System.IO.File]::ReadAllText($indexPath).Replace('__CP_TOKEN__', $token)
        Send-Bytes $ctx ([System.Text.Encoding]::UTF8.GetBytes($html)) 'text/html; charset=utf-8'
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
            Send-Json $ctx @{
                setup    = [bool](Test-IsSetup)
                services = $svc
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
        '^POST /api/setup$'        { Send-Started $ctx 'setup'; return }
        '^POST /api/stack/start$'  { Send-Started $ctx 'start'; return }
        '^POST /api/stack/reload$' { Send-Started $ctx 'reload'; return }
        '^POST /api/stack/stop$' {
            $body = Read-Body $req
            if ($body -and $body.backup -eq $false) { Send-Started $ctx 'stop-nobackup' } else { Send-Started $ctx 'stop' }
            return
        }
        '^POST /api/sites$' {
            $name = "$((Read-Body $req).name)".Trim()
            if ($name -notmatch '^[a-zA-Z0-9_-]+$') { Send-Error $ctx 400 'Use letters, numbers, - or _ in the site name.'; return }
            Send-Started $ctx 'new-site' $name
            return
        }
        '^POST /api/sites/([^/]+)/(backup|delete|open-dir)$' {
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
Open-Window

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
        if ($script:exitAt -and (Get-Date) -gt $script:exitAt) { break }
        # No window has polled for 3 minutes (minimised windows still poll about once a minute).
        if (((Get-Date) - $lastHit).TotalSeconds -gt 180) { break }
    }
}
$listener.Stop()
