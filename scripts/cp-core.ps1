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
# Only processes whose exe lives inside THIS stack folder count. Several stacks
# can sit side by side (F:\localhost-wp-8.5, E:\localhost-wp): a mysqld.exe from
# another stack must not show here as running, and Stop must never kill it.
function Get-StackProc([string]$name) {
    $root = $script:BASE.TrimEnd('\') + '\'
    @(Get-Process -Name $name -ErrorAction SilentlyContinue | Where-Object {
        $_.Path -and $_.Path.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)
    })
}

function Test-Proc([string]$name) {
    return (@(Get-StackProc $name)).Count -gt 0
}

function Stop-StackProc([string]$name) {
    Get-StackProc $name | Stop-Process -Force -ErrorAction SilentlyContinue
}

# Stack services running from somewhere else. They hold the same ports
# (80, 3307, 8080, 9000, 9001+), so this stack cannot start while they run.
# Returns one entry per foreign folder: @{ root = 'E:\localhost-wp'; parts = @('MySQL','Nginx') }
function Get-ForeignStacks {
    $root  = $script:BASE.TrimEnd('\') + '\'
    $names = [ordered]@{ mysqld = 'MySQL'; 'php-cgi' = 'PHP'; nginx = 'Nginx' }
    $found = [ordered]@{}
    foreach ($n in $names.Keys) {
        foreach ($p in Get-Process -Name $n -ErrorAction SilentlyContinue) {
            $exe = $p.Path
            if ($exe -and $exe.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
            # Path is empty for elevated processes we cannot inspect.
            $owner = if ($exe) { Split-Path -Parent $exe } else { '(unknown folder)' }
            if ($exe) {
                $dir = $owner
                while ($dir) {
                    if (Test-Path (Join-Path $dir 'scripts\cp-core.ps1')) { $owner = $dir; break }
                    $dir = Split-Path -Parent $dir
                }
            }
            if (-not $found.Contains($owner)) { $found[$owner] = New-Object System.Collections.ArrayList }
            if (-not $found[$owner].Contains($names[$n])) { [void]$found[$owner].Add($names[$n]) }
        }
    }
    foreach ($k in $found.Keys) { [ordered]@{ root = $k; parts = @($found[$k]) } }
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

# MySQL's Windows build needs the Visual C++ 2015-2022 runtime (x64), which its
# zip does not ship. Returns the missing DLL names; empty = runtime present.
$script:VcRedistUrl = 'https://aka.ms/vs/17/release/vc_redist.x64.exe'
function Get-MissingVcRuntime {
    # A 32-bit host sees SysWOW64 as System32; Sysnative reaches the real one.
    $sys = Join-Path $env:SystemRoot 'Sysnative'
    if (-not (Test-Path $sys)) { $sys = Join-Path $env:SystemRoot 'System32' }
    $bin = Join-Path $script:BASE 'mysql\bin'
    @('msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll') | Where-Object {
        -not (Test-Path (Join-Path $sys $_)) -and -not (Test-Path (Join-Path $bin $_))
    }
}

# Downloads Microsoft's VC++ runtime installer and runs it silently. Windows
# shows one admin prompt (system-wide install). Returns $true once the DLLs exist.
function Install-VcRuntime {
    $exe = Join-Path $env:TEMP 'vc_redist.x64.exe'
    try {
        Write-Log '  Downloading it from Microsoft...' ; Flush-UI
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $old = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'
        try { Invoke-WebRequest -Uri $script:VcRedistUrl -OutFile $exe -UseBasicParsing } finally { $ProgressPreference = $old }
        # Process.Start (not Start-Process) so a declined prompt surfaces as Win32Exception 1223.
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName        = $exe
        $psi.Arguments       = '/install /quiet /norestart'
        $psi.Verb            = 'runas'
        $psi.UseShellExecute = $true
        $p = [System.Diagnostics.Process]::Start($psi)
        while (-not $p.HasExited) { Start-Sleep -Milliseconds 300; Flush-UI }
        # 0 = installed, 1638 = newer already present, 3010 = installed, reboot pending
        if (@(Get-MissingVcRuntime).Count -eq 0) {
            Write-Log '  Microsoft Visual C++ Runtime installed.' 'ok'
            return $true
        }
        Write-Log "  Installation did not complete (exit $($p.ExitCode))." 'warn'
    } catch {
        # Declining the admin prompt = ERROR_CANCELLED (1223): no log, the caller's message covers it.
        $w = $_.Exception
        while ($w -and $w -isnot [System.ComponentModel.Win32Exception]) { $w = $w.InnerException }
        if (-not ($w -and $w.NativeErrorCode -eq 1223)) { Write-Log "  Installation did not complete - $($_.Exception.Message)" 'warn' }
    } finally {
        Remove-Item $exe -Force -ErrorAction SilentlyContinue
    }
    return $false
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
