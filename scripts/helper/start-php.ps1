param([string]$PhpCgi = "")

$ErrorActionPreference = "Stop"

$PhpCgi = if ([string]::IsNullOrWhiteSpace($PhpCgi)) { Join-Path (Split-Path -Parent $PSScriptRoot) "php\php-cgi.exe" } else { $PhpCgi }

if (!(Test-Path $PhpCgi)) { throw "php-cgi.exe not found: $PhpCgi" }

$phpDir = Split-Path -Parent $PhpCgi
$iniPath = Join-Path $phpDir "php.ini"
if (!(Test-Path $iniPath)) { throw "php.ini not found: $iniPath" }

$env:PHP_FCGI_MAX_REQUESTS = "0"
$env:PHP_FCGI_CHILDREN = "4"

Start-Process -FilePath $PhpCgi -ArgumentList "-c `"$iniPath`" -b 127.0.0.1:9000" -WorkingDirectory $phpDir -WindowStyle Hidden
Write-Host "[+] PHP FastCGI started on 127.0.0.1:9000 (children=4, max_requests=unlimited)."
