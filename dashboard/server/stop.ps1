# ============================================================================
#  stop.ps1  -  stop this stack gracefully, without a backup
#  Run by the Electron shell (dashboard\electron\main.js) when Windows shuts
#  down, restarts or signs out, so MySQL closes its files cleanly instead of
#  being killed mid-write. Windows waits while this runs (a few seconds).
#  What happened is appended to logs\shutdown.log.
# ============================================================================
param([string]$Base)

$shared = [hashtable]::Synchronized(@{
    Log      = New-Object System.Collections.ArrayList
    Seq      = 0
    Busy     = $null
    Progress = $null
})
. (Join-Path $PSScriptRoot 'bridge.ps1')

Stop-Stack -NoBackup

try {
    $dir = Join-Path $script:BASE 'logs'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $day = (Get-Date).ToString('yyyy-MM-dd')
    $lines = @("--- Windows is shutting down or signing out") + @($shared.Log | ForEach-Object { "$day $($_.t)  $($_.msg)" })
    Add-Content -LiteralPath (Join-Path $dir 'shutdown.log') -Value $lines
} catch { }
