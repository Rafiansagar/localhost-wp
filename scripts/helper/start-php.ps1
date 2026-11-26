param([string]$PhpCgi = "")

$ErrorActionPreference = "Stop"

$PhpCgi = if ([string]::IsNullOrWhiteSpace($PhpCgi)) { Join-Path (Split-Path -Parent $PSScriptRoot) "php\php-cgi.exe" } else { $PhpCgi }

if (!(Test-Path $PhpCgi)) { throw "php-cgi.exe not found: $PhpCgi" }

$phpDir = Split-Path -Parent $PhpCgi
$iniPath = Join-Path $phpDir "php.ini"
if (!(Test-Path $iniPath)) { throw "php.ini not found: $iniPath" }

# The Stack page's PHP & MySQL settings (config\php-tuning.json). None changed:
# 4 workers and php.ini alone. Changed PHP values go into an extra ini file
# that PHP reads after php.ini (PHP_INI_SCAN_DIR).
$base = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $PSScriptRoot 'tuning.ps1')
$tuning  = Get-Tuning $base
$workers = if ($tuning.Contains('workers')) { $tuning.workers } else { $script:TuningDefaultWorkers }
$scanDir = Write-TuningIni $base

$env:PHP_FCGI_MAX_REQUESTS = "0"
$env:PHP_FCGI_CHILDREN = "$workers"
# Set only for php-cgi: this script runs inside the dashboard's own process too.
$hadScan = Test-Path Env:PHP_INI_SCAN_DIR
$oldScan = $env:PHP_INI_SCAN_DIR
if ($scanDir) { $env:PHP_INI_SCAN_DIR = $scanDir } elseif ($hadScan) { Remove-Item Env:PHP_INI_SCAN_DIR }
try {
    Start-Process -FilePath $PhpCgi -ArgumentList "-c `"$iniPath`" -b 127.0.0.1:9000" -WorkingDirectory $phpDir -WindowStyle Hidden
} finally {
    if ($hadScan) { $env:PHP_INI_SCAN_DIR = $oldScan } else { Remove-Item Env:PHP_INI_SCAN_DIR -ErrorAction SilentlyContinue }
}
$extra = if ($scanDir) { ', plus your Stack page settings' } else { '' }
Write-Host "[+] PHP FastCGI started on 127.0.0.1:9000 (workers=$workers, max_requests=unlimited$extra)."
