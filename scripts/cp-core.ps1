# ============================================================================
#  cp-core.ps1  -  shared utilities + data access for the Control Panel
#  Dot-sourced by control-panel.ps1. Uses shared script-scope vars defined
#  in the GUI ($BASE, paths, $logBox).
# ============================================================================

# ---- colored Activity log --------------------------------------------------
function Write-Log([string]$msg, [string]$level = 'info') {
    $ts = (Get-Date).ToString('HH:mm:ss')
    switch ($level) {
        'ok'    { $color = [System.Drawing.Color]::FromArgb(28,135,60) }
        'err'   { $color = [System.Drawing.Color]::FromArgb(190,40,40) }
        'warn'  { $color = [System.Drawing.Color]::FromArgb(176,120,0) }
        default { $color = [System.Drawing.Color]::FromArgb(40,40,40) }
    }
    $logBox.SelectionStart  = $logBox.TextLength
    $logBox.SelectionLength = 0
    $logBox.SelectionColor  = $color
    $logBox.AppendText("[$ts] $msg`r`n")
    $logBox.SelectionColor  = $logBox.ForeColor
    $logBox.ScrollToCaret()
}

function Flush-UI { [System.Windows.Forms.Application]::DoEvents() }

# Run one of your scripts/*.ps1 helpers IN-PROCESS (no cmd window) and log output.
function Invoke-Helper([string]$scriptName, [hashtable]$params) {
    $path = Join-Path $script:HelperDir $scriptName
    if (-not (Test-Path $path)) { Write-Log "Helper not found: scripts\helper\$scriptName" 'err'; return $false }
    try {
        & $path @params *>&1 | ForEach-Object {
            $t = "$_".Trim(); if ($t) { Write-Log "  $t"; Flush-UI }
        }
        return $true
    } catch {
        Write-Log "  $scriptName failed: $($_.Exception.Message)" 'err'
        return $false
    }
}

# ---- process / network / data helpers --------------------------------------
function Test-Proc([string]$name) {
    return [bool](Get-Process -Name $name -ErrorAction SilentlyContinue)
}

function Get-LocalIp {
    $ip = (Get-NetIPConfiguration | Where-Object { $_.IPv4DefaultGateway -ne $null -and $_.NetAdapter.Status -eq 'Up' } | Select-Object -First 1).IPv4Address.IPAddress
    if (-not $ip) { $ip = '127.0.0.1' }
    return $ip
}

# Quick TCP probe (read-only): is something listening on 127.0.0.1:<port>?
function Test-Port([int]$port) {
    if (-not $port) { return $false }
    try {
        $c = New-Object System.Net.Sockets.TcpClient
        $iar = $c.BeginConnect('127.0.0.1', $port, $null, $null)
        $ok = $iar.AsyncWaitHandle.WaitOne(250)
        if ($ok -and $c.Connected) { $c.EndConnect($iar); $c.Close(); return $true }
        $c.Close(); return $false
    } catch { return $false }
}

# Returns array of database names, or $null if MySQL can't be queried.
function Get-DbList {
    if (-not (Test-Proc 'mysqld')) { return $null }
    if (-not (Test-Path $script:MysqlExe)) { return $null }
    try {
        $out = & $script:MysqlExe --protocol=TCP --host=127.0.0.1 --port=3307 -u root -N -e 'SHOW DATABASES;' 2>$null
        if ($LASTEXITCODE -ne 0) { return $null }
        return @($out | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    } catch { return $null }
}

# Reads site list from nginx vhost confs (enabled + disabled), parses ports.
function Get-Sites {
    $list = @()
    $items = @()
    if (Test-Path $script:ConfDir) {
        $items += Get-ChildItem -LiteralPath $script:ConfDir -Filter *.conf -File -ErrorAction SilentlyContinue |
                  ForEach-Object { [pscustomobject]@{ File = $_; Enabled = $true } }
    }
    if (Test-Path $script:DisabledDir) {
        $items += Get-ChildItem -LiteralPath $script:DisabledDir -Filter *.conf -File -ErrorAction SilentlyContinue |
                  ForEach-Object { [pscustomobject]@{ File = $_; Enabled = $false } }
    }
    foreach ($it in $items) {
        $nm = $it.File.BaseName
        if ($nm -eq 'phpmyadmin') { continue }
        $txt = Get-Content -Raw -LiteralPath $it.File.FullName
        $http = ''
        $mH = [regex]::Match($txt, 'listen\s+(\d+)\s*;'); if ($mH.Success) { $http = $mH.Groups[1].Value }
        $list += [pscustomobject]@{ Name = $nm; Http = $http; Enabled = $it.Enabled }
    }
    return @($list | Sort-Object Name)
}

function Open-Url([string]$url) {
    try { Start-Process $url; Write-Log "Opened $url" }
    catch { Write-Log "Failed to open $url - $($_.Exception.Message)" 'err' }
}
