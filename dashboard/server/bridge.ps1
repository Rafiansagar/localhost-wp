# ============================================================================
#  bridge.ps1  -  loads the stack's own Control Panel modules without the GUI
#  Dot-sourced by server.ps1 and worker.ps1 after $Base and $shared are set.
#  cp-core / cp-stack / cp-sites run unchanged; only the WinForms hooks
#  (Write-Log, Flush-UI, Update-Status) are replaced so output reaches the
#  dashboard's shared Activity log instead of a RichTextBox.
# ============================================================================

Add-Type -AssemblyName System.Windows.Forms   # cp-sites pumps DoEvents while its jobs run

$script:BASE         = $Base
$script:ScriptsDir   = Join-Path $script:BASE 'scripts'
$script:HelperDir    = Join-Path $script:BASE 'scripts\helper'
$script:ConfDir      = Join-Path $script:BASE 'config\nginx'
$script:DisabledDir  = Join-Path $script:ConfDir 'disabled'
$script:SitesDir     = Join-Path $script:BASE 'sites'
$script:MysqlExe     = Join-Path $script:BASE 'mysql\bin\mysql.exe'
$script:MysqldumpExe = Join-Path $script:BASE 'mysql\bin\mysqldump.exe'
$script:PortsFile    = Join-Path $script:BASE 'config\ports.txt'

. (Join-Path $script:ScriptsDir 'cp-core.ps1')
. (Join-Path $script:ScriptsDir 'cp-stack.ps1')
. (Join-Path $script:ScriptsDir 'cp-sites.ps1')

# ---- GUI hooks, redirected -------------------------------------------------
function Write-Log([string]$msg, [string]$level = 'info') {
    [System.Threading.Monitor]::Enter($shared.SyncRoot)
    try {
        $shared.Seq++
        [void]$shared.Log.Add([pscustomobject]@{
            id    = $shared.Seq
            t     = (Get-Date).ToString('HH:mm:ss')
            msg   = $msg
            level = $level
        })
        if ($shared.Log.Count -gt 1000) { $shared.Log.RemoveRange(0, 200) }
    } finally { [System.Threading.Monitor]::Exit($shared.SyncRoot) }
}

function Flush-UI { }

# Lamps are read by the dashboard from /api/status, so nothing to repaint here.
function Update-Status { }

function Test-IsSetup {
    (Test-Path (Join-Path $script:BASE 'nginx\nginx.exe')) -and
    (Test-Path (Join-Path $script:BASE 'mysql\bin\mysqld.exe')) -and
    (Test-Path (Join-Path $script:BASE 'php\php-cgi.exe')) -and
    (Test-Path (Join-Path $script:BASE 'phpmyadmin\index.php')) -and
    (Test-Path (Join-Path $script:BASE 'mysql\my.ini'))
}

function Get-MissingParts {
    $missing = @()
    if (-not (Test-Path (Join-Path $script:BASE 'nginx\nginx.exe')))      { $missing += 'Nginx' }
    if (-not (Test-Path (Join-Path $script:BASE 'mysql\bin\mysqld.exe'))) { $missing += 'MySQL' }
    if (-not (Test-Path (Join-Path $script:BASE 'php\php-cgi.exe')))      { $missing += 'PHP' }
    if (-not (Test-Path (Join-Path $script:BASE 'phpmyadmin\index.php'))) { $missing += 'phpMyAdmin' }
    if (-not (Test-Path (Join-Path $script:BASE 'mysql\my.ini')))         { $missing += 'MySQL config' }
    return $missing
}
