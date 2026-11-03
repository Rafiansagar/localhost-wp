param([string]$SiteName, [string]$Port, [string]$Base = "")

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($SiteName)) { throw "SiteName parameter is required." }
if ([string]::IsNullOrWhiteSpace($Port))     { throw "Port parameter is required." }

$Base = if ([string]::IsNullOrWhiteSpace($Base)) { Split-Path -Parent $PSScriptRoot } else { $Base }
$Base = $Base.Replace('\', '/')
$localIp = (Get-NetIPConfiguration | Where-Object { $_.IPv4DefaultGateway -ne $null -and $_.NetAdapter.Status -eq 'Up' } | Select-Object -First 1).IPv4Address.IPAddress
if (-not $localIp) { $localIp = "127.0.0.1" }
$out = "server {`n"
$out += "    listen $Port;`n"
$out += "    server_name localhost $localIp;`n`n"
$out += "    root `"$Base/sites/$SiteName/public`";`n"
$out += "    access_log  off;`n"
$out += "    error_log   `"$Base/logs/nginx/$SiteName-error.log`" warn;`n`n"
$out += "    include `"$Base/config/nginx/snippets/wordpress-common.conf`";`n"
$out += "}`n"
$confDir = "$Base\config\nginx"
if (!(Test-Path $confDir)) { throw "Nginx config directory not found: $confDir" }

Set-Content "$confDir\$SiteName.conf" $out
Write-Host "[+] Nginx config created (HTTP $Port)."
