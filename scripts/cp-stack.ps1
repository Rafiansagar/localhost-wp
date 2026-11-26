# ============================================================================
#  cp-stack.ps1  -  stack operations for the Control Panel
#  Dot-sourced by control-panel.ps1.
#  (Start Stack / Stop Stack will be added here.)
# ============================================================================

# The Stack page's PHP & MySQL settings (config\php-tuning.json).
. (Join-Path $PSScriptRoot 'helper\tuning.ps1')

# ---- REAL stack status (read-only) -----------------------------------------
function Update-Status {
    $procOf = @{ MySQL = 'mysqld'; PHP = 'php-cgi'; Nginx = 'nginx' }
    foreach ($svc in 'MySQL','PHP','Nginx') {
        $lbl = $svcLabels[$svc]
        if (Test-Proc $procOf[$svc]) {
            $lbl.Text = "$svc : RUNNING"
            $lbl.ForeColor = [System.Drawing.Color]::FromArgb(22,128,40)
        } else {
            $lbl.Text = "$svc : stopped"
            $lbl.ForeColor = [System.Drawing.Color]::FromArgb(176,32,32)
        }
    }
}

# ---- REAL: graceful Nginx reload (re-reads current config, no downtime) -----
#  (re-creates reload-nginx.bat in PowerShell - no cmd window)
function Invoke-NginxReload {
    if (-not (Test-Proc 'nginx')) {
        Write-Log 'Reload Nginx FAILED - Nginx is not running.' 'err'
        return $false
    }
    $nginxDir = Join-Path $script:BASE 'nginx'
    $exe      = Join-Path $nginxDir 'nginx.exe'
    if (-not (Test-Path $exe)) {
        Write-Log "Reload Nginx FAILED - nginx.exe not found: $exe" 'err'
        return $false
    }
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName               = $exe
        $psi.WorkingDirectory       = $nginxDir
        $psi.Arguments              = '-s reload'
        $psi.UseShellExecute        = $false
        $psi.CreateNoWindow         = $true
        $psi.RedirectStandardError  = $true
        $psi.EnvironmentVariables.Remove('NGINX') | Out-Null
        $p = [System.Diagnostics.Process]::Start($psi)
        $err = $p.StandardError.ReadToEnd()
        $p.WaitForExit()
        if ($p.ExitCode -eq 0) {
            Write-Log 'Nginx configuration reloaded.' 'ok'
            return $true
        } else {
            Write-Log ("Reload Nginx FAILED (exit {0}): {1}" -f $p.ExitCode, $err.Trim()) 'err'
            return $false
        }
    } catch {
        Write-Log "Reload Nginx FAILED - $($_.Exception.Message)" 'err'
        return $false
    }
}

# ---- REAL: Start the whole stack -------------------------------------------
#  (re-creates start.bat; delegates PHP runtime to your scripts/*.ps1)
function Start-Stack {
    $mysqld     = Join-Path $script:BASE 'mysql\bin\mysqld.exe'
    $mysqladmin = Join-Path $script:BASE 'mysql\bin\mysqladmin.exe'
    $myIni      = Join-Path $script:BASE 'mysql\my.ini'
    $phpCgi     = Join-Path $script:BASE 'php\php-cgi.exe'
    $nginxDir   = Join-Path $script:BASE 'nginx'
    $nginxExe   = Join-Path $nginxDir 'nginx.exe'

    Write-Log 'Starting stack...' ; Flush-UI

    # Another stack folder holds the same ports; starting now would half-fail.
    $foreign = @(Get-ForeignStacks)
    if ($foreign.Count) {
        foreach ($f in $foreign) {
            Write-Log ("  Another stack is running from {0} ({1})." -f $f.root, ($f.parts -join ', ')) 'err'
        }
        Write-Log 'Start cancelled - stacks share the same ports. Stop the other stack from its own Control Panel first.' 'err'
        return
    }

    # Leftovers of this stack that never started (not "running") are cleared first.
    foreach ($n in 'mysqld', 'php-cgi', 'nginx', 'mailpit') {
        if (-not (Test-Proc $n) -and @(Get-StackProc $n).Count) { Stop-StackProc $n }
    }

    # MySQL (Windows' VC++ runtime installed on demand; skipped, not fatal, if declined)
    $mysqlSkipped = $false
    $vcMissing = $false
    if (-not (Test-Proc 'mysqld') -and @(Get-MissingVcRuntime).Count) {
        Write-Log '  This PC is missing the Microsoft Visual C++ Runtime (x64), a Windows component MySQL needs.' 'warn'
        $vcMissing = -not (Install-VcRuntime)
    }
    if (Test-Proc 'mysqld') {
        Write-Log '  MySQL already running.'
    } elseif ($vcMissing) {
        $mysqlSkipped = $true
        Write-Log '  MySQL skipped - the Microsoft Visual C++ Runtime (x64) is not installed on this PC.' 'err'
        Write-Log "  Install it from Microsoft: $script:VcRedistUrl - then start the stack again." 'warn'
    } else {
        # Setup could not initialize the data dir if the runtime was missing back then.
        if (-not (Test-Path (Join-Path $script:BASE 'mysql\data\mysql'))) {
            Write-Log '  Initializing MySQL data directory (first run, ~30s)...' ; Flush-UI
            & $mysqld --defaults-file="$myIni" --initialize-insecure 2>&1 | Out-Null
        }
        Write-Log '  Starting MySQL...' ; Flush-UI
        $mysqlArgs = @("--defaults-file=`"$myIni`"", '--console')
        # MySQL cache size from the Stack page, over my.ini's (my.ini itself is left alone).
        $tuning = Get-Tuning $script:BASE
        if ($tuning.Contains('mysqlBuffer')) { $mysqlArgs += "--innodb-buffer-pool-size=$($tuning.mysqlBuffer)M" }
        Start-Process -FilePath $mysqld -ArgumentList $mysqlArgs -WorkingDirectory (Split-Path $mysqld) -WindowStyle Hidden
        $ready = $false
        for ($i = 0; $i -lt 20 -and -not $ready; $i++) {
            & $mysqladmin --protocol=TCP --host=127.0.0.1 --port=3307 -u root ping --silent 2>$null | Out-Null
            if ($LASTEXITCODE -eq 0) { $ready = $true } else { Start-Sleep -Seconds 1; Flush-UI }
        }
        if ($ready) { Write-Log '  MySQL ready on 127.0.0.1:3307.' 'ok' }
        else        { Write-Log '  MySQL did not become ready on 127.0.0.1:3307.' 'err' }
    }

    # Mail catcher: php.ini pointed at it (before PHP starts) and Mailpit fetched if missing.
    Invoke-Helper 'ensure-mail.ps1' @{ Base = $script:BASE } | Out-Null

    # PHP FastCGI
    if (Test-Proc 'php-cgi') {
        Write-Log '  PHP already running.'
    } else {
        Write-Log '  Starting PHP FastCGI...' ; Flush-UI
        Invoke-Helper 'ensure-php-runtime.ps1' @{ Base = $script:BASE } | Out-Null
        Invoke-Helper 'start-php.ps1' @{ PhpCgi = $phpCgi } | Out-Null
        Start-Sleep -Milliseconds 800 ; Flush-UI
    }

    # Nginx: upload limit from the Stack page, error logs into real files.
    $nginxConfChanged = $false
    try { $nginxConfChanged = Update-NginxTuning $script:BASE } catch { Write-Log "  Nginx config not updated: $($_.Exception.Message)" 'warn' }
    if (Test-Proc 'nginx') {
        Write-Log '  Nginx already running.'
        if ($nginxConfChanged) { Invoke-NginxReload | Out-Null }
    } else {
        Write-Log '  Starting Nginx...' ; Flush-UI
        try {
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName         = $nginxExe
            $psi.WorkingDirectory = $nginxDir
            $psi.UseShellExecute  = $false
            $psi.EnvironmentVariables.Remove('NGINX') | Out-Null
            [System.Diagnostics.Process]::Start($psi) | Out-Null
            Start-Sleep -Milliseconds 800 ; Flush-UI
        } catch { Write-Log "  Nginx start failed: $($_.Exception.Message)" 'err' }
    }

    # Mail catcher (optional: without it, mail is just not caught)
    if (Get-MailCatcherOn) { Start-MailCatcher }

    Update-Status
    if ($mysqlSkipped -and (Test-Proc 'php-cgi') -and (Test-Proc 'nginx')) {
        Write-Log 'Stack started without MySQL - Windows needs the Visual C++ Runtime (see above).' 'warn'
    } elseif ((Test-Proc 'mysqld') -and (Test-Proc 'php-cgi') -and (Test-Proc 'nginx')) {
        Write-Log 'Stack started.' 'ok'
    } else {
        Write-Log 'Stack started with errors - check the status above.' 'warn'
    }
}

# ---- Mail catcher (Mailpit) --------------------------------------------------
# On unless config\mail-catcher.txt says "off". Off means the stack leaves mail
# alone: no Mailpit, and php.ini's mail lines back to PHP's defaults.
function Get-MailCatcherOn {
    $f = Join-Path $script:BASE 'config\mail-catcher.txt'
    -not ((Test-Path $f) -and "$(Get-Content -LiteralPath $f -TotalCount 1)".Trim() -eq 'off')
}

function Start-MailCatcher {
    $mailpit = Join-Path $script:BASE 'mailpit\mailpit.exe'
    if (Test-Proc 'mailpit') { Write-Log '  Mail catcher already running.'; return }
    if (-not (Test-Path $mailpit)) { return }
    Write-Log '  Starting mail catcher...' ; Flush-UI
    $db = Join-Path $script:BASE 'mailpit\mailpit.db'
    Start-Process -FilePath $mailpit -ArgumentList '--listen', '127.0.0.1:8025', '--smtp', '127.0.0.1:1025', '--database', "`"$db`"" -WorkingDirectory (Split-Path $mailpit) -WindowStyle Hidden
    $up = $false
    for ($i = 0; $i -lt 20 -and -not $up; $i++) { if (Test-Port 1025) { $up = $true } else { Start-Sleep -Milliseconds 250 } }
    if ($up) { Write-Log '  Mail catcher ready - inbox at http://localhost:8025' 'ok' }
    else     { Write-Log '  Mail catcher did not start - WordPress mail will not be caught.' 'warn' }
}

# The dashboard's switch. PHP reads php.ini only when it starts, so a running
# PHP is restarted (about a second); MySQL and Nginx are not touched.
# Also the dashboard's "Download now" for a stack set up before the mail
# catcher existed (on already, Mailpit not downloaded yet).
function Set-MailCatcher([bool]$On) {
    $was = Get-MailCatcherOn
    $cfg = Join-Path $script:BASE 'config'
    New-Item -ItemType Directory -Force -Path $cfg | Out-Null
    Set-Content -LiteralPath (Join-Path $cfg 'mail-catcher.txt') -Value $(if ($On) { 'on' } else { 'off' })
    $msg = if (-not $On) { 'Turning the mail catcher off...' } elseif ($was) { 'Setting up the mail catcher...' } else { 'Turning the mail catcher on...' }
    Write-Log $msg ; Flush-UI

    $ini = Join-Path $script:BASE 'php\php.ini'
    $iniBefore = if (Test-Path $ini) { (Get-FileHash -LiteralPath $ini).Hash } else { '' }
    Invoke-Helper 'ensure-mail.ps1' @{ Base = $script:BASE } | Out-Null
    $iniChanged = (Test-Path $ini) -and (Get-FileHash -LiteralPath $ini).Hash -ne $iniBefore

    if ($On -and -not (Test-Path (Join-Path $script:BASE 'mailpit\mailpit.exe'))) {
        Write-Log 'Mail catcher could not be downloaded - see above. Start stack tries again.' 'err'
    }

    # PHP reads php.ini only at start: restarted only when the mail lines changed.
    if ($iniChanged -and (Test-Proc 'php-cgi')) {
        Write-Log '  Restarting PHP so it reads the new mail settings...' ; Flush-UI
        Stop-StackProc 'php-cgi'
        Invoke-Helper 'start-php.ps1' @{ PhpCgi = (Join-Path $script:BASE 'php\php-cgi.exe') } | Out-Null
        Start-Sleep -Milliseconds 800
        if (-not (Test-Proc 'php-cgi')) { Write-Log '  PHP did not come back up - use Start stack.' 'err' }
    }

    if ($On) {
        if (-not (Test-Path (Join-Path $script:BASE 'mailpit\mailpit.exe'))) { return }   # reported above
        # Started now only if the stack is up; otherwise Start stack does it.
        if ((Test-Proc 'php-cgi') -or (Test-Proc 'nginx')) { Start-MailCatcher }
        Write-Log 'Mail catcher on - mail from your sites lands in the inbox, nothing goes out.' 'ok'
    } else {
        if (@(Get-StackProc 'mailpit').Count) { Stop-StackProc 'mailpit'; Write-Log '  Mail catcher stopped.' }
        Write-Log 'Mail catcher off - sites send mail the normal way again (SMTP plugins included).' 'ok'
    }
}

# The Stack page's PHP & MySQL card saved one setting in config\php-tuning.json;
# this puts it into effect on the running stack. With the stack stopped, the
# next Start does it. PHP restarts for about a second; MySQL resizes its cache
# while it runs; Nginx reloads for the upload limit.
# $keys: one setting, or several separated by commas (Reset all), so PHP restarts once.
function Set-StackTuning([string]$keys) {
    $t = Get-Tuning $script:BASE
    $labels = @{ opcache = 'OPcache'; opcacheMemory = 'OPcache memory'; opcacheFiles = 'OPcache max files'; workers = 'PHP workers'
                 memoryLimit = 'PHP memory limit'; uploadMax = 'Max upload size'; maxExecution = 'Max execution time'; mysqlBuffer = 'MySQL cache' }
    $list = @($keys -split ',' | Where-Object { $labels.ContainsKey($_) })
    if (-not $list.Count) { Write-Log "Unknown setting '$keys'." 'err'; return }
    $stock = $null
    foreach ($key in $list) {
        if ($t.Contains($key)) { Write-Log "$($labels[$key]) set to $(Format-TuningValue $key $t[$key])." }
        else {
            if (-not $stock) { $stock = Get-TuningStock $script:BASE }
            Write-Log "$($labels[$key]) back to the stack's own value ($(Format-TuningValue $key $stock[$key]))."
        }
    }

    if ($list -contains 'uploadMax') {
        $changed = Update-NginxTuning $script:BASE -ResetBody:(-not $t.Contains('uploadMax'))
        if ($changed -and (Test-Proc 'nginx')) { Invoke-NginxReload | Out-Null }
    }

    if ($list -contains 'mysqlBuffer') {
        if (-not (Test-Proc 'mysqld')) { Write-Log '  MySQL is stopped - it uses this when the stack starts.' 'ok' }
        else {
            $mb = if ($t.Contains('mysqlBuffer')) { $t.mysqlBuffer } else { (Get-TuningStock $script:BASE).mysqlBuffer }
            $out = & $script:MysqlExe --protocol=TCP --host=127.0.0.1 --port=3307 -u root -e "SET GLOBAL innodb_buffer_pool_size = $([long]$mb * 1MB)" 2>&1
            if ($LASTEXITCODE -eq 0) { Write-Log "  MySQL is resizing its cache to $(Format-TuningValue 'mysqlBuffer' $mb) now, no restart needed." 'ok' }
            else { Write-Log "  MySQL did not take it: $("$out".Trim()) - it is used from the next stack start." 'err' }
        }
    }

    if (-not @($list | Where-Object { $script:TuningPhpKeys -contains $_ }).Count) { return }
    if (-not (Test-Proc 'php-cgi')) { Write-Log '  PHP is stopped - it uses this when the stack starts.' 'ok'; return }
    Write-Log '  Restarting PHP so it reads the new setting...' ; Flush-UI
    Stop-StackProc 'php-cgi'
    Invoke-Helper 'start-php.ps1' @{ PhpCgi = (Join-Path $script:BASE 'php\php-cgi.exe') } | Out-Null
    Start-Sleep -Milliseconds 800
    if (Test-Proc 'php-cgi') { Write-Log '  PHP restarted with the new setting.' 'ok' }
    else { Write-Log '  PHP did not come back up - use Start stack.' 'err' }
}

# Nginx's own "stop" makes the master end its workers. Killing them one by one
# instead lets the master start a new worker in between, which can be left
# behind half-created. Whatever remains after a few seconds is killed.
function Stop-Nginx {
    $nginxDir = Join-Path $script:BASE 'nginx'
    $exe      = Join-Path $nginxDir 'nginx.exe'
    if (Test-Path $exe) {
        try {
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName         = $exe
            $psi.WorkingDirectory = $nginxDir
            $psi.Arguments        = '-s stop'
            $psi.UseShellExecute  = $false
            $psi.CreateNoWindow   = $true
            $psi.EnvironmentVariables.Remove('NGINX') | Out-Null
            $p = [System.Diagnostics.Process]::Start($psi)
            [void]$p.WaitForExit(5000)
            for ($i = 0; $i -lt 30 -and @(Get-StackProc 'nginx').Count; $i++) { Start-Sleep -Milliseconds 100 }
        } catch { }
    }
    Stop-StackProc 'nginx'
}

# ---- REAL: Stop the whole stack (backs up DBs first) -----------------------
#  (re-creates stop.bat; delegates the backup to your scripts/backup-databases.ps1)
function Stop-Stack([switch]$NoBackup) {
    $mysqladmin = Join-Path $script:BASE 'mysql\bin\mysqladmin.exe'
    Write-Log 'Stopping stack...' 'warn' ; Flush-UI

    if (Test-Proc 'nginx')   { Stop-Nginx;               Write-Log '  Nginx stopped.' }   else { Write-Log '  Nginx not running.' }
    Stop-StackProc 'nginx'   # never-started leftovers too
    if (Test-Proc 'php-cgi') { Stop-StackProc 'php-cgi'; Write-Log '  PHP-CGI stopped.' } else { Write-Log '  PHP-CGI not running.' }
    if (@(Get-StackProc 'mailpit').Count) { Stop-StackProc 'mailpit'; Write-Log '  Mail catcher stopped.' }

    if (Test-Proc 'mysqld') {
        if (-not $NoBackup) {
            Write-Log '  Backing up databases before shutdown...' ; Flush-UI
            Invoke-Helper 'backup-databases.ps1' @{ Base = $script:BASE } | Out-Null
        }
        if (Test-Path $mysqladmin) {
            Write-Log '  Stopping MySQL gracefully...' ; Flush-UI
            & $mysqladmin --protocol=TCP --host=127.0.0.1 --port=3307 -u root shutdown 2>$null | Out-Null
            $stopped = $false
            for ($i = 0; $i -lt 120 -and -not $stopped; $i++) {
                if (-not (Test-Proc 'mysqld')) { $stopped = $true } else { Start-Sleep -Seconds 1; Flush-UI }
            }
            if ($stopped) { Write-Log '  MySQL stopped gracefully.' 'ok' }
            else { Stop-StackProc 'mysqld'; Write-Log '  MySQL did not stop gracefully - force-stopped.' 'warn' }
        } else {
            Stop-StackProc 'mysqld'
            Write-Log '  mysqladmin.exe missing - MySQL force-stopped.' 'warn'
        }
    } else {
        Write-Log '  MySQL not running.'
    }

    Update-Status
    Write-Log 'Stack stopped.' 'ok'
}
