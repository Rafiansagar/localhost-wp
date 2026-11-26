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
}
$script:SettingsChoices = @{ closeAction = @('tray', 'ask', 'stop'); stopBackup = @('backup', 'ask', 'none') }
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
