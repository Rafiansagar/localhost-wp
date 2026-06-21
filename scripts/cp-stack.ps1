# ============================================================================
#  cp-stack.ps1  -  stack operations for the Control Panel
#  Dot-sourced by control-panel.ps1.
#  (Start Stack / Stop Stack will be added here.)
# ============================================================================

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
#  (re-creates start.bat; delegates PHP runtime/SSL/CA to your scripts/*.ps1)
function Start-Stack {
    $mysqld     = Join-Path $script:BASE 'mysql\bin\mysqld.exe'
    $mysqladmin = Join-Path $script:BASE 'mysql\bin\mysqladmin.exe'
    $myIni      = Join-Path $script:BASE 'mysql\my.ini'
    $phpCgi     = Join-Path $script:BASE 'php\php-cgi.exe'
    $nginxDir   = Join-Path $script:BASE 'nginx'
    $nginxExe   = Join-Path $nginxDir 'nginx.exe'

    Write-Log 'Starting stack...' ; Flush-UI

    # MySQL
    if (Test-Proc 'mysqld') {
        Write-Log '  MySQL already running.'
    } else {
        Write-Log '  Starting MySQL...' ; Flush-UI
        Start-Process -FilePath $mysqld -ArgumentList "--defaults-file=`"$myIni`"", '--console' -WorkingDirectory (Split-Path $mysqld) -WindowStyle Hidden
        $ready = $false
        for ($i = 0; $i -lt 20 -and -not $ready; $i++) {
            & $mysqladmin --protocol=TCP --host=127.0.0.1 --port=3307 -u root ping --silent 2>$null | Out-Null
            if ($LASTEXITCODE -eq 0) { $ready = $true } else { Start-Sleep -Seconds 1; Flush-UI }
        }
        if ($ready) { Write-Log '  MySQL ready on 127.0.0.1:3307.' 'ok' }
        else        { Write-Log '  MySQL did not become ready on 127.0.0.1:3307.' 'err' }
    }

    # PHP FastCGI
    if (Test-Proc 'php-cgi') {
        Write-Log '  PHP already running.'
    } else {
        Write-Log '  Starting PHP FastCGI...' ; Flush-UI
        Invoke-Helper 'ensure-php-runtime.ps1' @{ Base = $script:BASE } | Out-Null
        Invoke-Helper 'start-php.ps1' @{ PhpCgi = $phpCgi } | Out-Null
        Start-Sleep -Milliseconds 800 ; Flush-UI
    }

    # SSL certificate (refresh for current machine IP) + CA mu-plugin
    Write-Log '  Refreshing SSL certificate...' ; Flush-UI
    Invoke-Helper 'generate-ssl.ps1' @{ Base = $script:BASE } | Out-Null
    Write-Log '  Installing local CA mu-plugin...' ; Flush-UI
    Invoke-Helper 'install-local-ca-mu-plugin.ps1' @{ Base = $script:BASE } | Out-Null

    # Nginx
    if (Test-Proc 'nginx') {
        Write-Log '  Nginx already running.'
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

    Update-Status
    if ((Test-Proc 'mysqld') -and (Test-Proc 'php-cgi') -and (Test-Proc 'nginx')) {
        Write-Log 'Stack started.' 'ok'
    } else {
        Write-Log 'Stack started with errors - check the status above.' 'warn'
    }
}

# ---- REAL: Stop the whole stack (backs up DBs first) -----------------------
#  (re-creates stop.bat; delegates the backup to your scripts/backup-databases.ps1)
function Stop-Stack([switch]$NoBackup) {
    $mysqladmin = Join-Path $script:BASE 'mysql\bin\mysqladmin.exe'
    Write-Log 'Stopping stack...' 'warn' ; Flush-UI

    if (Test-Proc 'nginx')   { Stop-Process -Name 'nginx'   -Force -ErrorAction SilentlyContinue; Write-Log '  Nginx stopped.' }   else { Write-Log '  Nginx not running.' }
    if (Test-Proc 'php-cgi') { Stop-Process -Name 'php-cgi' -Force -ErrorAction SilentlyContinue; Write-Log '  PHP-CGI stopped.' } else { Write-Log '  PHP-CGI not running.' }

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
            else { Stop-Process -Name 'mysqld' -Force -ErrorAction SilentlyContinue; Write-Log '  MySQL did not stop gracefully - force-stopped.' 'warn' }
        } else {
            Stop-Process -Name 'mysqld' -Force -ErrorAction SilentlyContinue
            Write-Log '  mysqladmin.exe missing - MySQL force-stopped.' 'warn'
        }
    } else {
        Write-Log '  MySQL not running.'
    }

    Update-Status
    Write-Log 'Stack stopped.' 'ok'
}
