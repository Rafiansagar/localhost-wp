# ============================================================================
#  worker.ps1  -  runs one long stack/site operation in a background runspace
#  Started by server.ps1 so the web server keeps answering status and log
#  requests while MySQL boots, WordPress downloads, or setup runs.
#  $shared (the dashboard's log + busy state) is injected by the server.
# ============================================================================
param([string]$Base, [string]$Action, [string]$Arg)

. (Join-Path $PSScriptRoot 'bridge.ps1')

switch ($Action) {
    'start'         { Start-Stack }
    'stop'          { Stop-Stack }
    'stop-nobackup' { Stop-Stack -NoBackup }
    'reload'        { Invoke-NginxReload | Out-Null }
    'new-site'      { Invoke-NewSite $Arg }
    'backup'        { Invoke-Backup $Arg }
    'delete'        { Invoke-DeleteSite $Arg }
    'setup' {
        Write-Log 'Starting setup - downloading MySQL, PHP, Nginx, phpMyAdmin...' 'warn'
        $ProgressPreference = 'SilentlyContinue'
        # "[%] <pct> <text>" lines drive the progress bar; everything else goes to the log
        # $Arg is the PHP version picked in the setup dialog; empty = versions.json default
        & (Join-Path $script:HelperDir 'setup.ps1') -Base $script:BASE -PhpVersion $Arg *>&1 | ForEach-Object {
            $t = "$_".Trim()
            if (-not $t) { return }
            $m = [regex]::Match($t, '^\[%\]\s+(-?\d+)\s+(.*)$')
            if ($m.Success) {
                $shared.Progress = @{ pct = [int]$m.Groups[1].Value; text = $m.Groups[2].Value }
            } else {
                Write-Log "  $t"
                if ($t.StartsWith('[*]')) { $shared.Progress = @{ pct = -1; text = $t.Substring(3).Trim() } }
            }
        }
        $shared.Progress = $null
        if (Test-IsSetup) {
            Write-Log 'Setup complete - all binaries present.' 'ok'
        } else {
            Write-Log "Setup incomplete - still missing: $((Get-MissingParts) -join ', '). Fix the issue and run setup again." 'err'
        }
    }
}
