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
            wp     = Get-WpVersion $s.Name
        }
    }
}

# WordPress version from wp-includes\version.php, or $null (not WordPress, or not installed yet).
function Get-WpVersion([string]$name) {
    $f = Join-Path $script:SitesDir "$name\public\wp-includes\version.php"
    if (-not (Test-Path -LiteralPath $f)) { return $null }
    try {
        $m = [regex]::Match([System.IO.File]::ReadAllText($f), "\`$wp_version\s*=\s*'([^']+)'")
        if ($m.Success) { return $m.Groups[1].Value }
    } catch { }
    return $null
}

# Last part of a (possibly large) text file, read from the end.
function Read-Tail([string]$path, [int]$bytes = 262144) {
    try {
        $fs = [System.IO.File]::Open($path, 'Open', 'Read', 'ReadWrite')
        try {
            $start = [Math]::Max(0, $fs.Length - $bytes)
            $null = $fs.Seek($start, 'Begin')
            # NULs: a writer that kept its old position after a Clear pads the gap with them.
            $text = (New-Object System.IO.StreamReader($fs)).ReadToEnd() -replace "`0", ''
            $lines = $text -split "`r?`n"
            if ($start -gt 0 -and $lines.Count) { $lines = $lines[1..($lines.Count - 1)] }   # first line is cut
            return , @($lines | Where-Object { $_ })
        } finally { $fs.Dispose() }
    } catch { return , @() }
}

# A log file for the site page: size, last change, and what its recent part says.
function Get-LogSummary([string]$path, [string]$kind) {
    if (-not (Test-Path -LiteralPath $path)) { return [ordered]@{ exists = $false } }
    $f = Get-Item -LiteralPath $path
    $lines = Read-Tail $path
    $counts = [ordered]@{ fatal = 0; warning = 0; notice = 0 }
    $last = $null
    foreach ($l in $lines) {
        if ($kind -eq 'php') {
            if ($l -match 'PHP (Fatal|Parse) error|Uncaught') { $counts.fatal++; $last = $l }
            elseif ($l -match 'PHP Warning') { $counts.warning++; $last = $l }
            elseif ($l -match 'PHP (Notice|Deprecated)') { $counts.notice++; if (-not $last) { $last = $l } }
        } else {
            if ($l -match '\[(emerg|alert|crit|error)\]') { $counts.fatal++; $last = $l }
            elseif ($l -match '\[warn\]' -and $l -notmatch 'buffered to a temporary file') { $counts.warning++; $last = $l }
        }
    }
    if ($last -and $last.Length -gt 400) { $last = $last.Substring(0, 400) }
    [ordered]@{
        exists   = $true
        size     = $f.Length
        modified = $f.LastWriteTime.ToString('o')
        counts   = $counts
        last     = $last
        partial  = $f.Length -gt 262144
    }
}

function Get-SiteLogPaths([string]$name) {
    [ordered]@{
        php   = Join-Path $script:SitesDir "$name\public\wp-content\debug.log"
        nginx = Join-Path $script:BASE "logs\nginx\$name-error.log"
    }
}

# "size:time|size:time" for both logs; changes whenever either log does.
function Get-LogStamp([string]$name) {
    $parts = foreach ($p in (Get-SiteLogPaths $name).Values) {
        $f = Get-Item -LiteralPath $p -ErrorAction SilentlyContinue
        if ($f) { "$($f.Length):$($f.LastWriteTime.Ticks)" } else { '-' }
    }
    $parts -join '|'
}

# Everything the site page shows that comes from files, so it works while the stack is stopped.
function Get-SiteInfo([string]$name) {
    $dir = Join-Path $script:SitesDir $name
    $pub = Join-Path $dir 'public'
    $sql = @(Get-ChildItem -LiteralPath (Join-Path $dir 'sql') -Filter '*.sql' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
    $debug = $null; $prefix = $null
    $cfg = Join-Path $pub 'wp-config.php'
    if (Test-Path -LiteralPath $cfg) {
        $t = [System.IO.File]::ReadAllText($cfg)
        $debug = [ordered]@{}
        foreach ($k in 'WP_DEBUG', 'WP_DEBUG_LOG', 'WP_DEBUG_DISPLAY') {
            $m = [regex]::Match($t, "(?mi)^\s*define\s*\(\s*['""]$k['""]\s*,\s*([^)]+?)\s*\)")
            # Not defined: WordPress defaults (debug off, log off, display on).
            $debug[$k] = if ($m.Success) { $m.Groups[1].Value -notmatch '^(false|0|'''')$' } elseif ($k -eq 'WP_DEBUG_DISPLAY') { $true } else { $false }
        }
        $m = [regex]::Match($t, "(?m)^\s*\`$table_prefix\s*=\s*['""]([^'""]*)['""]")
        if ($m.Success) { $prefix = $m.Groups[1].Value }
        # A line of the user's own that forces errors onto pages, whatever WP_DEBUG_DISPLAY says.
        $debug['iniDisplay'] = [regex]::IsMatch($t, "(?mi)^\s*@?ini_set\s*\(\s*['""]display_errors['""]\s*,\s*(1|true|['""](1|on)['""])\s*\)")
    }
    $content = Join-Path $pub 'wp-content'
    $count = { param($sub) @(Get-ChildItem -LiteralPath (Join-Path $content $sub) -Directory -ErrorAction SilentlyContinue).Count }
    [ordered]@{
        name    = $name
        created = if (Test-Path -LiteralPath $dir) { (Get-Item -LiteralPath $dir).CreationTime.ToString('o') } else { $null }
        prefix  = $prefix
        debug   = $debug
        plugins = if (Test-Path -LiteralPath $content) { & $count 'plugins' } else { $null }
        themes  = if (Test-Path -LiteralPath $content) { & $count 'themes' } else { $null }
        backups = [ordered]@{
            count  = $sql.Count
            total  = [long](($sql | Measure-Object Length -Sum).Sum)
            latest = if ($sql.Count) { [ordered]@{ file = $sql[0].Name; size = $sql[0].Length; time = $sql[0].LastWriteTime.ToString('o') } } else { $null }
        }
        stamp   = Get-LogStamp $name
        logs    = [ordered]@{
            php   = Get-LogSummary (Join-Path $content 'debug.log') 'php'
            nginx = Get-LogSummary (Join-Path $script:BASE "logs\nginx\$name-error.log") 'nginx'
        }
    }
}

# Site page > Debugging switches: sets one debug constant in wp-config.php.
# The existing define(...) line is rewritten in place; a missing one is added
# next to the other debug lines (or above the "stop editing" comment / the
# ABSPATH block). Turning WP_DEBUG on also writes WP_DEBUG_LOG and
# WP_DEBUG_DISPLAY when they are missing, with WordPress's defaults, so the
# file says exactly what the switches show. Encoding, BOM and line endings are
# kept, and the file is replaced in one step.
function Set-WpDebug([string]$name, [string]$key, [bool]$on) {
    $cfg = Join-Path $script:SitesDir "$name\public\wp-config.php"
    if (-not (Test-Path -LiteralPath $cfg)) { throw "No wp-config.php in sites\$name\public." }
    $bytes = [System.IO.File]::ReadAllBytes($cfg)
    $bom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    $skip = if ($bom) { 3 } else { 0 }
    $text = (New-Object System.Text.UTF8Encoding($false)).GetString($bytes, $skip, $bytes.Length - $skip)
    $nl = if ($text -match "`r`n") { "`r`n" } else { "`n" }

    $lineRx = { param($k) [regex]"(?mi)^(\s*define\s*\(\s*['""]$k['""]\s*,\s*)([^)]+?)(\s*\))" }
    $set = {
        param($t, $k, [string]$v, [bool]$replace)
        $rx = & $lineRx $k
        if ($rx.IsMatch($t)) {
            if (-not $replace) { return $t }
            return $rx.Replace($t, [System.Text.RegularExpressions.MatchEvaluator] { param($m) $m.Groups[1].Value + $v + $m.Groups[3].Value }.GetNewClosure())
        }
        $line = "define( '$k', $v );"
        # After the last debug define, so the lines stay together.
        $last = [regex]::Matches($t, "(?mi)^\s*define\s*\(\s*['""]WP_DEBUG\w*['""][^\r\n]*")
        if ($last.Count) {
            $m = $last[$last.Count - 1]
            $end = $m.Index + $m.Length
            return $t.Insert($end, $nl + $line)
        }
        $anchor = [regex]::Match($t, "(?m)^.*(That's all, stop editing|if\s*\(\s*!\s*defined\s*\(\s*['""]ABSPATH['""]|require_once\s+ABSPATH).*$")
        if (-not $anchor.Success) { throw "Couldn't find where to add $k in wp-config.php." }
        return $t.Insert($anchor.Index, $line + $nl)
    }

    $val = if ($on) { 'true' } else { 'false' }
    $text = & $set $text $key $val $true
    if ($key -eq 'WP_DEBUG' -and $on) {
        $text = & $set $text 'WP_DEBUG_LOG' 'false' $false
        $text = & $set $text 'WP_DEBUG_DISPLAY' 'true' $false
    }
    $enc = New-Object System.Text.UTF8Encoding($bom)
    $tmp = "$cfg.localhost-wp.tmp"
    [System.IO.File]::WriteAllText($tmp, $text, $enc)
    Move-Item -LiteralPath $tmp -Destination $cfg -Force
    Write-Log "$name`: $key set to $val in wp-config.php" 'ok'
}

# ---- app settings (config\app-settings.json) ----------------------------------
# Read by the page (Settings) and by the Electron shell through /api/status:
# start with Windows, what closing the window does, backups on stop, notifications.
$script:SettingsDefaults = [ordered]@{
    startup      = $false   # open localhost-wp when signing in to Windows
    startupStack = $true    # ...and start the stack
    startupShow  = $false   # ...and show the window (off: tray only)
    closeAction  = 'tray'   # tray | ask | stop
    stopBackup   = 'backup' # backup | ask | none
    notifyMail   = $true
    notifyJobs   = $true
    errorAlerts  = 'fatal'  # toast for caught PHP errors: off | fatal | warning (fatal and warnings) | all
}
$script:SettingsChoices = @{ closeAction = @('tray', 'ask', 'stop'); stopBackup = @('backup', 'ask', 'none'); errorAlerts = @('off', 'fatal', 'warning', 'all') }
$script:SettingsFile = Join-Path $script:BASE 'config\app-settings.json'

function Get-AppSettings {
    $s = [ordered]@{}
    foreach ($k in $script:SettingsDefaults.Keys) { $s[$k] = $script:SettingsDefaults[$k] }
    if (Test-Path -LiteralPath $script:SettingsFile) {
        try {
            $saved = Get-Content -Raw -LiteralPath $script:SettingsFile | ConvertFrom-Json
            foreach ($k in $script:SettingsDefaults.Keys) {
                $v = $saved.$k
                if ($null -eq $v) { continue }
                if ($script:SettingsChoices.Contains($k)) { if ($script:SettingsChoices[$k] -contains "$v") { $s[$k] = "$v" } }
                elseif ($v -is [bool]) { $s[$k] = $v }
            }
            # 2.6 had an on/off "notifyErrors" (fatal only); off carries over.
            if ($null -eq $saved.errorAlerts -and $saved.notifyErrors -eq $false) { $s.errorAlerts = 'off' }
        } catch { }
    }
    return $s
}

# Merges known keys with valid values; anything else is refused.
function Set-AppSettings($body) {
    $s = Get-AppSettings
    foreach ($p in $body.PSObject.Properties) {
        $k = $p.Name; $v = $p.Value
        if (-not $script:SettingsDefaults.Contains($k)) { throw "Unknown setting '$k'." }
        if ($script:SettingsChoices.Contains($k)) {
            if ($script:SettingsChoices[$k] -notcontains "$v") { throw "Invalid value for '$k'." }
            $s[$k] = "$v"
        } elseif ($v -is [bool]) { $s[$k] = $v }
        else { throw "'$k' must be true or false." }
    }
    $dir = Split-Path -Parent $script:SettingsFile
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
    [System.IO.File]::WriteAllText($script:SettingsFile, (ConvertTo-Json -InputObject $s), (New-Object System.Text.UTF8Encoding $false))
    return $s
}

# ---- error catcher -------------------------------------------------------------
# scripts\php\error-catcher.php appends one JSON line per distinct error per
# request to logs\errors\<site>.jsonl (rotated to <site>.old.jsonl at 4 MB).
# Here they are grouped across requests by site, type, file, line and message.
# Read state lives in config\error-catcher-seen.json: a time per site, "*" for all.
$script:ErrDir      = Join-Path $script:BASE 'logs\errors'
$script:ErrSeenFile = Join-Path $script:BASE 'config\error-catcher-seen.json'
$script:ErrState    = Join-Path $script:BASE 'config\error-catcher.txt'
$script:ErrCache    = $null
$script:ErrStampWas = ''
$script:ErrTypes = @{
    1 = 'E_ERROR'; 2 = 'E_WARNING'; 4 = 'E_PARSE'; 8 = 'E_NOTICE'; 16 = 'E_CORE_ERROR'; 32 = 'E_CORE_WARNING'
    64 = 'E_COMPILE_ERROR'; 128 = 'E_COMPILE_WARNING'; 256 = 'E_USER_ERROR'; 512 = 'E_USER_WARNING'
    1024 = 'E_USER_NOTICE'; 2048 = 'E_STRICT'; 4096 = 'E_RECOVERABLE_ERROR'; 8192 = 'E_DEPRECATED'; 16384 = 'E_USER_DEPRECATED'
}

function Get-ErrSeverity([int]$t) {
    if ($t -band 4437)  { return 'fatal' }       # E_ERROR, E_PARSE, E_CORE_ERROR, E_COMPILE_ERROR, E_USER_ERROR, E_RECOVERABLE_ERROR
    if ($t -band 674)   { return 'warning' }     # E_WARNING, E_CORE_WARNING, E_COMPILE_WARNING, E_USER_WARNING
    if ($t -band 24576) { return 'deprecated' }  # E_DEPRECATED, E_USER_DEPRECATED
    return 'notice'
}

function Get-ErrorCatcherOn {
    -not ((Test-Path -LiteralPath $script:ErrState) -and "$(Get-Content -LiteralPath $script:ErrState -TotalCount 1)".Trim() -eq 'off')
}

# php.ini loads localhost-wp.php (Start stack puts it there); until then nothing is caught.
function Test-ErrorCatcherReady {
    $ini = Join-Path $script:BASE 'php\php.ini'
    if (-not (Test-Path -LiteralPath $ini)) { return $false }
    return [bool](Select-String -LiteralPath $ini -Pattern '^\s*auto_prepend_file\s*=\s*"?[^"]*/scripts/php/localhost-wp\.php' -Quiet)
}

$script:ErrMutedFile = Join-Path $script:BASE 'config\error-alerts-muted.json'
function Get-ErrMuted {
    if (-not (Test-Path -LiteralPath $script:ErrMutedFile)) { return @() }
    # ConvertFrom-Json in PowerShell 5.1 passes a JSON array down the pipeline as one object, so
    # unwrap it with foreach; entries that aren't a single site name (old, broken saves) are dropped.
    try { $data = Get-Content -LiteralPath $script:ErrMutedFile -Raw | ConvertFrom-Json } catch { return @() }
    return @(foreach ($x in @($data)) { $s = "$x".Trim(); if ($s -match '^\S+$') { $s } })
}

function Get-ErrFiles { @(Get-ChildItem -LiteralPath $script:ErrDir -Filter '*.jsonl' -File -ErrorAction SilentlyContinue) }

function Get-ErrSeen {
    $seen = @{ '*' = 0 }
    if (Test-Path -LiteralPath $script:ErrSeenFile) {
        try { foreach ($p in (Get-Content -LiteralPath $script:ErrSeenFile -Raw | ConvertFrom-Json).PSObject.Properties) { $seen[$p.Name] = [long]$p.Value } } catch { }
    }
    return $seen
}

function Set-ErrSeen($seen) {
    $dir = Split-Path -Parent $script:ErrSeenFile
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
    [System.IO.File]::WriteAllText($script:ErrSeenFile, (ConvertTo-Json -InputObject $seen -Compress), (New-Object System.Text.UTF8Encoding $false))
}

# Grouped errors, newest first. Re-read only when a log file changed.
function Get-ErrorGroups {
    $files = Get-ErrFiles
    $stamp = ($files | ForEach-Object { "$($_.Name):$($_.Length):$($_.LastWriteTimeUtc.Ticks)" }) -join '|'
    if ($null -ne $script:ErrCache -and $stamp -eq $script:ErrStampWas) { return , $script:ErrCache }
    if (-not $script:JsonSer) {
        Add-Type -AssemblyName System.Web.Extensions
        $script:JsonSer = New-Object System.Web.Script.Serialization.JavaScriptSerializer
        $script:JsonSer.MaxJsonLength = 16MB
    }
    $md5 = [System.Security.Cryptography.MD5]::Create()
    $groups = New-Object 'System.Collections.Generic.Dictionary[string,object]'
    # .old first, so the current file's newer lines win the "latest" fields.
    foreach ($f in ($files | Sort-Object { $_.Name -notlike '*.old.jsonl' }, Name)) {
        $site = $f.Name -replace '(\.old)?\.jsonl$', ''
        $siteRoot = (Join-Path $script:SitesDir "$site\public") + '\'
        foreach ($ln in (Read-Tail $f.FullName 3145728)) {
            if ($ln[0] -ne '{') { continue }
            try { $o = $script:JsonSer.DeserializeObject($ln) } catch { continue }
            $type = [int]$o['type']; $file = "$($o['file'])".Replace('/', '\'); $line = [int]$o['line']; $msg = "$($o['msg'])"
            $key = "$site|$type|$file|$line|$msg"
            $t = [long]$o['t']; $n = if ($o.ContainsKey('n')) { [int]$o['n'] } else { 1 }
            $g = $null
            if ($groups.TryGetValue($key, [ref]$g)) {
                $g.times += $n; $g.requests++
                if ($t -lt $g.first) { $g.first = $t }
                if ($t -ge $g.last) {
                    $g.last = $t; $g.url = "$($o['url'])"; $g.method = "$($o['method'])"
                    if ($o.ContainsKey('trace')) { $g.trace = "$($o['trace'])" }
                }
            } else {
                $id = -join ($md5.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($key))[0..7] | ForEach-Object { $_.ToString('x2') })
                $rel = if ($file.StartsWith($siteRoot, [StringComparison]::OrdinalIgnoreCase)) { $file.Substring($siteRoot.Length) }
                       elseif ($file.StartsWith($script:BASE + '\', [StringComparison]::OrdinalIgnoreCase)) { $file.Substring($script:BASE.Length + 1) }
                       else { $file }
                # "Uncaught X: ... in C:\path\file.php:12" repeats the file and line shown beside it.
                $short = $msg -replace (' in ' + [regex]::Escape($file) + ':' + $line + '$'), ''
                $groups[$key] = [ordered]@{
                    id = $id; site = $site; type = $type; typeName = "$($script:ErrTypes[$type])"; sev = Get-ErrSeverity $type
                    msg = $short; file = $file; rel = $rel; line = $line
                    times = $n; requests = 1; first = $t; last = $t
                    url = "$($o['url'])"; method = "$($o['method'])"; trace = if ($o.ContainsKey('trace')) { "$($o['trace'])" } else { '' }
                }
            }
        }
    }
    $md5.Dispose()
    $list = @($groups.Values | Sort-Object { $_.last } -Descending | Select-Object -First 1000)
    $script:ErrCache = $list
    $script:ErrStampWas = $stamp
    return , $list
}

function Test-ErrNew($g, $seen) {
    $since = [Math]::Max([long]$seen['*'], [long]$(if ($seen.ContainsKey($g.site)) { $seen[$g.site] } else { 0 }))
    return $g.last -gt $since
}

# For /api/status: small, cheap (the groups are cached).
function Get-ErrorSummary {
    $on = Get-ErrorCatcherOn
    $groups = Get-ErrorGroups
    $seen = Get-ErrSeen
    $fatal = @($groups | Where-Object { $_.sev -eq 'fatal' -and (Test-ErrNew $_ $seen) })
    $latest = $fatal | Select-Object -First 1
    $perSite = @{}
    foreach ($g in $fatal) { $perSite[$g.site] = 1 + [int]$perSite[$g.site] }
    [ordered]@{
        enabled     = $on
        ready       = Test-ErrorCatcherReady
        total       = $groups.Count
        newCount    = @($groups | Where-Object { Test-ErrNew $_ $seen }).Count
        fatalNew    = $fatal.Count
        fatalBySite = $perSite
        latestFatal = if ($latest) { [ordered]@{ id = $latest.id; site = $latest.site; msg = $latest.msg; last = $latest.last } } else { $null }
        stamp       = $script:ErrStampWas
    }
}

# ---- network catcher -----------------------------------------------------------
# scripts\php\network-catcher.php appends one JSON line per HTTP call a site
# makes to logs\network\<site>.jsonl, and blocks what config\network-rules.json
# says: { mode: log|slow|all, block: [hosts by hand], auto: [slow hosts],
# unblocked: { host: unix time } }. "auto" is kept here: a host whose call took
# 5 s or more, or timed out, in the last hour (unless unblocked since).
$script:NetDir       = Join-Path $script:BASE 'logs\network'
$script:NetRulesFile = Join-Path $script:BASE 'config\network-rules.json'
$script:NetState     = Join-Path $script:BASE 'config\network-catcher.txt'
$script:NetCache     = $null
$script:NetStampWas  = ''
$script:NetSlowMs    = 2000    # shown as slow
$script:NetBlockMs   = 5000    # makes its host "slow" for blocking
$script:NetBlockFor  = 3600    # ...for an hour

function Get-NetworkCatcherOn {
    -not ((Test-Path -LiteralPath $script:NetState) -and "$(Get-Content -LiteralPath $script:NetState -TotalCount 1)".Trim() -eq 'off')
}

function Get-NetRules {
    $r = [ordered]@{ mode = 'log'; block = @(); auto = @(); unblocked = @{} }
    if (Test-Path -LiteralPath $script:NetRulesFile) {
        try {
            $j = Get-Content -LiteralPath $script:NetRulesFile -Raw | ConvertFrom-Json
            if ($j.mode -in 'log', 'slow', 'all') { $r.mode = $j.mode }
            if ($j.block) { $r.block = @($j.block | ForEach-Object { "$_".ToLower() }) }
            if ($j.auto) { $r.auto = @($j.auto | ForEach-Object { "$_".ToLower() }) }
            if ($j.unblocked) { foreach ($p in $j.unblocked.PSObject.Properties) { $r.unblocked[$p.Name] = [long]$p.Value } }
        } catch { }
    }
    return $r
}

function Set-NetRules($r) {
    $json = ConvertTo-Json -InputObject ([ordered]@{ mode = $r.mode; block = @($r.block | Sort-Object -Unique); auto = @($r.auto | Sort-Object -Unique); unblocked = $r.unblocked }) -Compress
    if ((Test-Path -LiteralPath $script:NetRulesFile) -and (Get-Content -LiteralPath $script:NetRulesFile -Raw) -eq $json) { return }
    $dir = Split-Path -Parent $script:NetRulesFile
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
    [System.IO.File]::WriteAllText($script:NetRulesFile, $json, (New-Object System.Text.UTF8Encoding $false))
}

# Every recorded call, newest first. Re-read only when a log file changed.
function Get-NetCalls {
    $files = @(Get-ChildItem -LiteralPath $script:NetDir -Filter '*.jsonl' -File -ErrorAction SilentlyContinue)
    $stamp = ($files | ForEach-Object { "$($_.Name):$($_.Length):$($_.LastWriteTimeUtc.Ticks)" }) -join '|'
    if ($null -ne $script:NetCache -and $stamp -eq $script:NetStampWas) { return , $script:NetCache }
    if (-not $script:JsonSer) {
        Add-Type -AssemblyName System.Web.Extensions
        $script:JsonSer = New-Object System.Web.Script.Serialization.JavaScriptSerializer
        $script:JsonSer.MaxJsonLength = 16MB
    }
    $calls = New-Object System.Collections.Generic.List[object]
    foreach ($f in $files) {
        $site = $f.Name -replace '(\.old)?\.jsonl$', ''
        $i = 0
        foreach ($ln in (Read-Tail $f.FullName 2097152)) {
            if ($ln[0] -ne '{') { continue }
            try { $o = $script:JsonSer.DeserializeObject($ln) } catch { continue }
            $i++
            # A missing key reads as $null, so optional fields need no checks.
            $calls.Add([ordered]@{
                id = "$($f.Name):$i"; site = $site; t = [long]$o['t']; method = "$($o['method'])"; url = "$($o['url'])"; host = "$($o['host'])"
                caller = "$($o['caller'])"; ms = [int]$o['ms']; code = [int]$o['code']; size = [long]$o['size']
                error = "$($o['error'])"; blocked = "$($o['blocked'])"; local = [bool]$o['local']; async = [bool]$o['async']; page = "$($o['page'])"
            })
        }
    }
    $list = @($calls | Sort-Object { $_.t } -Descending)
    $script:NetCache = $list
    $script:NetStampWas = $stamp
    return , $list
}

function Test-NetFailed($c) { -not $c.blocked -and ($c.error -or $c.code -ge 500) }
function Test-NetSlow($c) { -not $c.blocked -and -not $c.async -and -not $c.local -and ($c.ms -ge $script:NetSlowMs -or ($c.error -and $c.error -match 'timed out|timeout|cURL error 28')) }
function Test-NetBlockable($c) { -not $c.blocked -and -not $c.async -and -not $c.local -and ($c.ms -ge $script:NetBlockMs -or ($c.error -and $c.error -match 'timed out|timeout|cURL error 28')) }

# Slow hosts of the last hour into the rules file, so the PHP side can block them.
function Update-NetAuto($calls) {
    $r = Get-NetRules
    $since = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - $script:NetBlockFor
    $auto = @($calls | Where-Object { $_.t -ge $since -and (Test-NetBlockable $_) -and (-not $r.unblocked.ContainsKey($_.host) -or $_.t -gt $r.unblocked[$_.host]) } | ForEach-Object { $_.host } | Sort-Object -Unique)
    if ((@($r.auto | Sort-Object -Unique) -join ',') -ne ($auto -join ',')) { $r.auto = $auto; Set-NetRules $r }
    $r.auto = $auto
    return $r
}

# One row per host: how often, how fast, how often it failed, blocked or not.
function Get-NetHosts($calls, $rules) {
    $by = @{}
    foreach ($c in $calls) {
        if (-not $c.host) { continue }
        if (-not $by.ContainsKey($c.host)) { $by[$c.host] = [ordered]@{ host = $c.host; local = $c.local; calls = 0; done = 0; failed = 0; slow = 0; blockedCalls = 0; totalMs = 0; maxMs = 0; last = 0; sites = @{}; callers = @{} } }
        $h = $by[$c.host]
        $h.calls++; $h.sites[$c.site] = 1; if ($c.caller) { $h.callers[$c.caller] = 1 }
        if ($c.t -gt $h.last) { $h.last = $c.t }
        if ($c.blocked) { $h.blockedCalls++; continue }
        if (Test-NetFailed $c) { $h.failed++ }
        if (Test-NetSlow $c) { $h.slow++ }
        if (-not $c.async) { $h.done++; $h.totalMs += $c.ms; if ($c.ms -gt $h.maxMs) { $h.maxMs = $c.ms } }
    }
    @($by.Values | ForEach-Object {
        [ordered]@{
            host = $_.host; local = $_.local; calls = $_.calls; failed = $_.failed; slow = $_.slow; blockedCalls = $_.blockedCalls
            avgMs = if ($_.done) { [int]($_.totalMs / $_.done) } else { 0 }; maxMs = $_.maxMs; last = $_.last
            sites = @($_.sites.Keys | Sort-Object); callers = @($_.callers.Keys | Sort-Object)
            blocked = if ($rules.block -contains $_.host) { 'manual' } elseif ($rules.auto -contains $_.host -and $rules.mode -eq 'slow') { 'slow' } elseif ($rules.mode -eq 'all' -and -not $_.local) { 'all' } else { '' }
            slowHost = $rules.auto -contains $_.host
        }
    } | Sort-Object { $_.last } -Descending)
}

# For /api/status: counts of the last hour, per site.
function Get-NetworkSummary {
    $calls = Get-NetCalls
    $rules = Update-NetAuto $calls
    $since = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - 3600
    $recent = @($calls | Where-Object { $_.t -ge $since -and -not $_.local })
    $slowBySite = @{}
    foreach ($c in $recent) { if ((Test-NetSlow $c) -or (Test-NetFailed $c)) { $slowBySite[$c.site] = 1 + [int]$slowBySite[$c.site] } }
    [ordered]@{
        enabled    = Get-NetworkCatcherOn
        ready      = Test-ErrorCatcherReady
        mode       = $rules.mode
        hourCalls  = $recent.Count
        hourSlow   = @($recent | Where-Object { (Test-NetSlow $_) -or (Test-NetFailed $_) }).Count
        slowBySite = $slowBySite
        blocked    = @($rules.block).Count + $(if ($rules.mode -eq 'slow') { @($rules.auto).Count } else { 0 })
        stamp      = $script:NetStampWas
    }
}

# ---- mail catcher inbox (Mailpit's API on 127.0.0.1:8025) ---------------------
$script:MailApi = 'http://127.0.0.1:8025/api/v1'

function Invoke-Mailpit([string]$method, [string]$path, $body) {
    $p = @{ Method = $method; Uri = "$script:MailApi$path"; TimeoutSec = 3; UseBasicParsing = $true }
    if ($null -ne $body) { $p.Body = [System.Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $body -Compress)); $p.ContentType = 'application/json' }
    Invoke-RestMethod @p
}

# Newest messages, light fields only. Site = the tag mail-catcher.php adds (X-Tags).
function Get-MailMessages([int]$limit) {
    $r = Invoke-Mailpit 'GET' "/messages?limit=$limit" $null
    @(foreach ($m in @($r.messages)) {
        if (-not $m) { continue }
        $from = if ($m.From.Name) { $m.From.Name } else { $m.From.Address }
        [ordered]@{
            id      = $m.ID
            subject = "$($m.Subject)"
            from    = "$from"
            to      = "$(@($m.To)[0].Address)"
            created = "$($m.Created)"
            read    = [bool]$m.Read
            site    = "$(@($m.Tags)[0])"
            snippet = "$($m.Snippet)"
        }
    })
}

# Only Mailpit message IDs (letters and digits) pass through.
function Get-MailIds($body) {
    $ids = @(@($body.ids) | Where-Object { $_ } | ForEach-Object { "$_" })
    foreach ($i in $ids) { if ($i -notmatch '^[A-Za-z0-9]{8,40}$') { throw 'Invalid message id.' } }
    return ,$ids
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

# ---- PHP & MySQL settings (Stack page) ---------------------------------------
# What was changed (config\php-tuning.json), the stack's own values (php.ini,
# my.ini; read again only when one of them changes) and the allowed choices.
$script:tuneStock = $null
$script:tuneStockKey = ''
function Get-TuningView {
    $stamp = foreach ($f in 'php\php.ini', 'mysql\my.ini') {
        $i = Get-Item -LiteralPath (Join-Path $script:BASE $f) -ErrorAction SilentlyContinue
        if ($i) { $i.LastWriteTimeUtc.Ticks } else { 0 }
    }
    $stamp = $stamp -join '|'
    if (-not $script:tuneStock -or $script:tuneStockKey -ne $stamp) {
        $script:tuneStock = Get-TuningStock $script:BASE
        $script:tuneStockKey = $stamp
    }
    $options = [ordered]@{}
    foreach ($k in $script:TuningSpec.Keys) { $options[$k] = @($script:TuningSpec[$k]) }
    [ordered]@{ set = Get-Tuning $script:BASE; stock = $script:tuneStock; options = $options }
}

# Asks a PHP worker through phpMyAdmin's port (localhost-wp.php answers before
# phpMyAdmin runs). $null when PHP doesn't answer within 1.5 s, which is
# itself the sign that every worker is busy.
function Invoke-PhpStatus([string]$what) {
    $port = (Get-Ports).pma
    try {
        $r = [Net.HttpWebRequest]::Create("http://127.0.0.1:$port/index.php?__localhost_wp=$what")
        $r.Timeout = 1500; $r.ReadWriteTimeout = 1500; $r.Proxy = $null; $r.KeepAlive = $false
        $r.Host = "localhost:$port"
        $res = $r.GetResponse()
        try { $txt = (New-Object IO.StreamReader($res.GetResponseStream())).ReadToEnd() } finally { $res.Close() }
        return $txt | ConvertFrom-Json
    } catch { return $null }
}

# Live numbers: PHP workers (busy = open connections from Nginx to PHP's port)
# and OPcache as the workers see it.
function Get-TuningLive {
    $out = [ordered]@{ php = $null; opcache = $null; answered = $false }
    $procs = @(Get-StackProc 'php-cgi')
    if (-not $procs.Count) { return $out }
    if (Test-Proc 'nginx') {
        $o = Invoke-PhpStatus 'status'
        if ($o) { $out.answered = $true; $out.opcache = $o }
    }
    $ids = @($procs | ForEach-Object { $_.Id })
    $phpPort = (Get-Ports).php
    $busy = @(Get-NetTCPConnection -LocalPort $phpPort -State Established -ErrorAction SilentlyContinue | Where-Object { $ids -contains $_.OwningProcess }).Count
    $out.php = [ordered]@{ workers = [math]::Max(1, $procs.Count - 1); busy = $busy }
    return $out
}

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
                errors   = Get-ErrorSummary
                network  = Get-NetworkSummary
                foreign  = $foreign
                busy     = $shared.Busy
                task     = $script:opArg
                progress = if ($shared.Busy -eq 'new-site') { Get-NewSiteProgress $script:opArg } else { $shared.Progress }
                seq      = $shared.Seq
                settings = Get-AppSettings
            }
            return
        }
        '^GET /api/settings$' {
            Send-Json $ctx (Get-AppSettings)
            return
        }
        '^POST /api/settings$' {
            $body = Read-Body $req
            if (-not $body) { Send-Error $ctx 400 'Send the settings to change.'; return }
            try { Send-Json $ctx (Set-AppSettings $body) } catch { Send-Error $ctx 400 $_.Exception.Message }
            return
        }
        '^GET /api/errors$' {
            Send-Json $ctx ([ordered]@{
                enabled = Get-ErrorCatcherOn
                ready   = Test-ErrorCatcherReady
                seen    = Get-ErrSeen
                muted   = @(Get-ErrMuted)
                groups  = Get-ErrorGroups
            })
            return
        }
        # Alerts for one site on or off (the app reads config\error-alerts-muted.json).
        '^POST /api/errors/mute$' {
            $b = Read-Body $req
            $site = "$($b.site)"
            if (-not (Test-KnownSite $site) -or $b.muted -isnot [bool]) { Send-Error $ctx 400 'Send a site and muted: true or false.'; return }
            $list = @(Get-ErrMuted | Where-Object { $_ -ne $site })
            if ($b.muted) { $list += $site }
            $dir = Split-Path -Parent $script:ErrMutedFile
            if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
            [System.IO.File]::WriteAllText($script:ErrMutedFile, (ConvertTo-Json -InputObject @($list | Sort-Object) -Compress), (New-Object System.Text.UTF8Encoding $false))
            Write-Log $(if ($b.muted) { "Error alerts muted for $site (its errors are still caught)." } else { "Error alerts on for $site." }) 'ok'
            Send-Json $ctx @{ ok = $true; muted = @($list) }
            return
        }
        # Mark as read: one site, or all ("*").
        '^POST /api/errors/read$' {
            $site = "$((Read-Body $req).site)"
            if ($site -and -not (Test-KnownSite $site)) { Send-Error $ctx 404 "No site named '$site'."; return }
            $seen = Get-ErrSeen
            $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
            if ($site) { $seen[$site] = $now } else { $seen = @{ '*' = $now } }
            Set-ErrSeen $seen
            Send-Json $ctx @{ ok = $true; seen = $seen }
            return
        }
        # Clear: one site's errors, or every site's.
        '^POST /api/errors/clear$' {
            $site = "$((Read-Body $req).site)"
            if ($site -and $site -notmatch '^[A-Za-z0-9_-]+$') { Send-Error $ctx 400 'Unknown site.'; return }
            $gone = 0
            foreach ($f in (Get-ErrFiles)) {
                if ($site -and ($f.Name -replace '(\.old)?\.jsonl$', '') -ne $site) { continue }
                try { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop; $gone++ } catch { Write-Log "Couldn't remove logs\errors\$($f.Name): $($_.Exception.Message)" 'err' }
            }
            $script:ErrCache = $null
            Write-Log $(if ($site) { "Cleared the errors caught from $site." } else { 'Cleared all caught errors.' }) 'ok'
            Send-Json $ctx @{ ok = $true; removed = $gone }
            return
        }
        # Opens the file at the error's line: VS Code when it is here, else the folder with the file selected.
        '^POST /api/errors/open$' {
            $id = "$((Read-Body $req).id)"
            $g = Get-ErrorGroups | Where-Object { $_.id -eq $id } | Select-Object -First 1
            if (-not $g) { Send-Error $ctx 404 'That error is no longer in the list.'; return }
            $file = $g.file
            if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { Write-Log "File not found: $file" 'warn'; Send-Error $ctx 404 "The file isn't there any more."; return }
            if ($script:VsCode) {
                Start-Process -FilePath $script:VsCode -ArgumentList '-g', "`"$($file):$($g.line)`""
                Write-Log "Opened $($g.rel) at line $($g.line) in VS Code"
            } else {
                Start-Process explorer.exe "/select,`"$file`""
                Write-Log "VS Code not found - showed $($g.rel) in its folder (line $($g.line))." 'warn'
            }
            Send-Json $ctx @{ ok = $true }
            return
        }
        '^POST /api/errors/enabled$' {
            $b = Read-Body $req
            if ($b.on -isnot [bool]) { Send-Error $ctx 400 'Send on: true or false.'; return }
            $cfg = Split-Path -Parent $script:ErrState
            if (-not (Test-Path $cfg)) { New-Item -ItemType Directory -Force $cfg | Out-Null }
            Set-Content -LiteralPath $script:ErrState -Value $(if ($b.on) { 'on' } else { 'off' })
            Write-Log $(if ($b.on) { 'Error catcher on - PHP errors from every site show on the Errors page.' } else { 'Error catcher off - PHP errors are no longer collected.' }) 'ok'
            Send-Json $ctx (Get-ErrorSummary)
            return
        }
        '^GET /api/network$' {
            $calls = Get-NetCalls
            $rules = Update-NetAuto $calls
            Send-Json $ctx ([ordered]@{
                enabled = Get-NetworkCatcherOn
                ready   = Test-ErrorCatcherReady
                rules   = [ordered]@{ mode = $rules.mode; block = @($rules.block); auto = @($rules.auto) }
                slowMs  = $script:NetSlowMs
                blockMs = $script:NetBlockMs
                calls   = @($calls | Select-Object -First 1000)
                hosts   = @(Get-NetHosts $calls $rules)
            })
            return
        }
        '^POST /api/network/enabled$' {
            $b = Read-Body $req
            if ($b.on -isnot [bool]) { Send-Error $ctx 400 'Send on: true or false.'; return }
            $cfg = Split-Path -Parent $script:NetState
            if (-not (Test-Path $cfg)) { New-Item -ItemType Directory -Force $cfg | Out-Null }
            Set-Content -LiteralPath $script:NetState -Value $(if ($b.on) { 'on' } else { 'off' })
            Write-Log $(if ($b.on) { 'Network catcher on - calls from your sites to the internet show on the Network page.' } else { 'Network catcher off - calls are no longer recorded or blocked.' }) 'ok'
            Send-Json $ctx (Get-NetworkSummary)
            return
        }
        '^POST /api/network/mode$' {
            $mode = "$((Read-Body $req).mode)"
            if ($mode -notin 'log', 'slow', 'all') { Send-Error $ctx 400 'Mode is log, slow or all.'; return }
            $r = Get-NetRules; $r.mode = $mode; Set-NetRules $r
            Write-Log $(switch ($mode) { 'log' { 'Network catcher: recording only, nothing blocked (except hosts blocked by hand).' } 'slow' { 'Network catcher: slow hosts are blocked for an hour.' } 'all' { 'Network catcher: every external call is blocked (local calls still work).' } }) 'ok'
            Send-Json $ctx (Get-NetworkSummary)
            return
        }
        # Block or unblock one host. Unblocking a slow host also forgets its slow calls until now.
        '^POST /api/network/block$' {
            $b = Read-Body $req
            $h = "$($b.host)".Trim().ToLower()
            if ($h -notmatch '^[a-z0-9]([a-z0-9.-]{0,251}[a-z0-9])?$' -or $b.block -isnot [bool]) { Send-Error $ctx 400 'Send a host name and block: true or false.'; return }
            $r = Get-NetRules
            if ($b.block) {
                $r.block = @(@($r.block) + $h | Sort-Object -Unique)
                Write-Log "Network catcher: $h blocked." 'ok'
            } else {
                $r.block = @($r.block | Where-Object { $_ -ne $h })
                $r.auto = @($r.auto | Where-Object { $_ -ne $h })
                $r.unblocked[$h] = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
                Write-Log "Network catcher: $h unblocked." 'ok'
            }
            Set-NetRules $r
            Send-Json $ctx (Get-NetworkSummary)
            return
        }
        '^POST /api/network/clear$' {
            $site = "$((Read-Body $req).site)"
            if ($site -and $site -notmatch '^[A-Za-z0-9_-]+$') { Send-Error $ctx 400 'Unknown site.'; return }
            foreach ($f in @(Get-ChildItem -LiteralPath $script:NetDir -Filter '*.jsonl' -File -ErrorAction SilentlyContinue)) {
                if ($site -and ($f.Name -replace '(\.old)?\.jsonl$', '') -ne $site) { continue }
                try { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop } catch { Write-Log "Couldn't remove logs\network\$($f.Name): $($_.Exception.Message)" 'err' }
            }
            $script:NetCache = $null
            Write-Log $(if ($site) { "Cleared the calls recorded from $site." } else { 'Cleared all recorded calls.' }) 'ok'
            Send-Json $ctx @{ ok = $true }
            return
        }
        '^GET /api/mail/messages$' {
            if (-not (Test-Proc 'mailpit')) { Send-Json $ctx @{ running = $false; messages = @() }; return }
            try { Send-Json $ctx @{ running = $true; messages = @(Get-MailMessages 200) } }
            catch { Send-Error $ctx 502 "The mail catcher didn't answer - $($_.Exception.Message)" }
            return
        }
        '^POST /api/mail/(read|delete)$' {
            # { ids: [...] }; no ids means every message.
            $op = $Matches[1]
            if (-not (Test-Proc 'mailpit')) { Send-Error $ctx 409 'The mail catcher is not running.'; return }
            try {
                $ids = Get-MailIds (Read-Body $req)
                if ($op -eq 'read') { Invoke-Mailpit 'PUT' '/messages' @{ IDs = $ids; Read = $true } | Out-Null }
                else { Invoke-Mailpit 'DELETE' '/messages' @{ IDs = $ids } | Out-Null }
                $what = if ($ids.Count) { "$($ids.Count) message$(if ($ids.Count -ne 1) { 's' })" } else { 'all mail' }
                Write-Log $(if ($op -eq 'read') { "Marked $what as read." } else { "Deleted $what from the mail catcher." }) 'ok'
                Send-Json $ctx @{ ok = $true }
            } catch { Send-Error $ctx 400 $_.Exception.Message }
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
        '^GET /api/tuning$' { Send-Json $ctx (Get-TuningView); return }
        '^GET /api/tuning/live$' { Send-Json $ctx (Get-TuningLive); return }
        # One setting: { key, value } saves it, { key, value: null } goes back to the
        # stack's own value. Saved first, then put into effect by the worker.
        '^POST /api/tuning$' {
            $b = Read-Body $req
            $k = "$($b.key)"
            if (-not $script:TuningSpec.Contains($k)) { Send-Error $ctx 400 "No setting named '$k'."; return }
            $v = $null
            if ($null -ne $b.value) {
                $v = Test-TuningValue $k $b.value
                if ($null -eq $v) { Send-Error $ctx 400 "'$($b.value)' is not one of the choices for $k."; return }
            }
            if ($shared.Busy) { Send-Error $ctx 409 "Busy with '$($shared.Busy)'. Wait for it to finish."; return }
            Set-TuningValue $script:BASE $k $v
            Send-Started $ctx 'tuning' $k
            return
        }
        # Reset all: every changed setting back to the stack's own, in one job.
        '^POST /api/tuning/reset$' {
            $keys = @((Get-Tuning $script:BASE).Keys)
            if (-not $keys.Count) { Send-Json $ctx @{ ok = $true; reset = @() }; return }
            if ($shared.Busy) { Send-Error $ctx 409 "Busy with '$($shared.Busy)'. Wait for it to finish."; return }
            foreach ($k in $keys) { Set-TuningValue $script:BASE $k $null }
            Send-Started $ctx 'tuning' ($keys -join ',')
            return
        }
        '^POST /api/tuning/opcache-reset$' {
            $o = Invoke-PhpStatus 'opcache-reset'
            if (-not $o) { Send-Error $ctx 409 "PHP didn't answer. Start the stack, or wait until PHP isn't busy."; return }
            Write-Log 'OPcache cleared - pages compile their PHP files again on the next visit.' 'ok'
            Send-Json $ctx @{ ok = $true; opcache = $o }
            return
        }
        '^POST /api/sites$' {
            $name = "$((Read-Body $req).name)".Trim()
            if ($name -notmatch '^[a-zA-Z0-9_-]+$') { Send-Error $ctx 400 'Use letters, numbers, - or _ in the site name.'; return }
            Send-Started $ctx 'new-site' $name
            return
        }
        '^GET /api/sites/([^/]+)/info$' {
            $name = [uri]::UnescapeDataString($Matches[1])
            if (-not (Test-KnownSite $name)) { Send-Error $ctx 404 "No site named '$name'."; return }
            Send-Json $ctx (Get-SiteInfo $name)
            return
        }
        '^POST /api/sites/([^/]+)/debug$' {
            $name = [uri]::UnescapeDataString($Matches[1])
            if (-not (Test-KnownSite $name)) { Send-Error $ctx 404 "No site named '$name'."; return }
            $b = Read-Body $req
            $key = "$($b.key)"
            if ($key -notin 'WP_DEBUG', 'WP_DEBUG_LOG', 'WP_DEBUG_DISPLAY' -or $b.on -isnot [bool]) { Send-Error $ctx 400 'Unknown setting.'; return }
            try { Set-WpDebug $name $key $b.on; Send-Json $ctx (Get-SiteInfo $name) }
            catch { Write-Log "$name`: $($_.Exception.Message)" 'err'; Send-Error $ctx 500 $_.Exception.Message }
            return
        }
        # Size and time of both logs; the site page polls this and re-reads the
        # summaries only when something changed.
        '^GET /api/sites/([^/]+)/logstamp$' {
            $name = [uri]::UnescapeDataString($Matches[1])
            if (-not (Test-KnownSite $name)) { Send-Error $ctx 404 "No site named '$name'."; return }
            Send-Json $ctx @{ stamp = (Get-LogStamp $name) }
            return
        }
        # Empties a log without deleting it: PHP and Nginx keep writing to the same file.
        '^POST /api/sites/([^/]+)/clear-(php|nginx)-log$' {
            $name = [uri]::UnescapeDataString($Matches[1]); $which = $Matches[2]
            if (-not (Test-KnownSite $name)) { Send-Error $ctx 404 "No site named '$name'."; return }
            $path = (Get-SiteLogPaths $name)[$which]
            $rel = $path.Substring($script:BASE.Length).TrimStart('\')
            if (Test-Path -LiteralPath $path) {
                try {
                    $fs = [System.IO.File]::Open($path, 'Open', 'Write', 'ReadWrite, Delete')
                    try { $fs.SetLength(0) } finally { $fs.Dispose() }
                    Write-Log "Cleared $rel" 'ok'
                } catch {
                    Write-Log "Couldn't clear $rel`: $($_.Exception.Message)" 'err'
                    Send-Error $ctx 500 "Couldn't clear $rel."
                    return
                }
            }
            Send-Json $ctx (Get-SiteInfo $name)
            return
        }
        '^POST /api/sites/([^/]+)/open-(sql|php-log|nginx-log)$' {
            $name = [uri]::UnescapeDataString($Matches[1]); $what = $Matches[2]
            if (-not (Test-KnownSite $name)) { Send-Error $ctx 404 "No site named '$name'."; return }
            $target = switch ($what) {
                'sql'       { Join-Path $script:SitesDir "$name\sql" }
                'php-log'   { Join-Path $script:SitesDir "$name\public\wp-content\debug.log" }
                'nginx-log' { Join-Path $script:BASE "logs\nginx\$name-error.log" }
            }
            $rel = $target.Substring($script:BASE.Length).TrimStart('\')
            if (-not (Test-Path -LiteralPath $target)) { Write-Log "Not found: $rel" 'warn' }
            elseif ($what -eq 'sql') { Start-Process explorer.exe $target; Write-Log "Opened folder $rel" }
            else {
                # Logs open in VS Code when it is here, else Notepad (a .log may have no default app).
                if ($script:VsCode) { Start-Process -FilePath $script:VsCode -ArgumentList "`"$target`"" } else { Start-Process notepad.exe "`"$target`"" }
                Write-Log "Opened $rel"
            }
            Send-Json $ctx @{ ok = $true }
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
