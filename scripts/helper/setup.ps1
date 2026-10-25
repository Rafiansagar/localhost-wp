param([string]$Base = "", [string]$PhpVersion = "")

$Base = if ([string]::IsNullOrWhiteSpace($Base)) { Split-Path -Parent (Split-Path -Parent $PSScriptRoot) } else { $Base }
$Base = $Base.TrimEnd('\').TrimEnd('/')
$ErrorActionPreference = "Stop"
# Built-in progress bars (Invoke-WebRequest, Expand-Archive) flood the job/host and
# freeze the control panel; Download prints its own "[%]" lines instead.
$ProgressPreference = "SilentlyContinue"
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

function Step($msg)  { Write-Host "[*] $msg" -ForegroundColor Cyan }
function OK($msg)    { Write-Host "[+] $msg" -ForegroundColor Green }
function Skip($msg)  { Write-Host "[=] $msg - already exists, skipping." -ForegroundColor DarkGray }
function Fail($msg)  { Write-Host "[!] $msg" -ForegroundColor Red; exit 1 }

# Streams to "<dest>.part" and renames when done, so a broken download is never
# mistaken for a finished one. Progress line format: "[%] <pct> <label> - <done> / <total> MB"
function Download($url, $dest, $label) {
    if (Test-Path $dest) { Skip $label; return }
    Step "Downloading $label..."
    $part = "$dest.part"
    $resp = $null; $in = $null; $out = $null
    try {
        $req = [System.Net.HttpWebRequest]::Create($url)
        $req.UserAgent = "localhost-wp-setup"
        $resp  = $req.GetResponse()
        $total = $resp.ContentLength
        $in    = $resp.GetResponseStream()
        $out   = [System.IO.File]::Create($part)
        $buf   = New-Object byte[] 262144
        $done  = 0L
        $sw    = [System.Diagnostics.Stopwatch]::StartNew()
        $last  = -1000
        while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) {
            $out.Write($buf, 0, $n)
            $done += $n
            if ($sw.ElapsedMilliseconds - $last -ge 500) {
                $last = $sw.ElapsedMilliseconds
                $mb = "{0:N1}" -f ($done / 1MB)
                if ($total -gt 0) {
                    $pct = [int](100 * $done / $total)
                    Write-Host ("[%] {0} {1} - {2} / {3:N1} MB" -f $pct, $label, $mb, ($total / 1MB))
                } else {
                    Write-Host ("[%] -1 {0} - {1} MB" -f $label, $mb)
                }
            }
        }
        $out.Close(); $out = $null
        Write-Host ("[%] 100 {0} - {1:N1} MB" -f $label, ($done / 1MB))
        Move-Item -LiteralPath $part -Destination $dest -Force
    }
    catch {
        if ($out) { $out.Close() }
        Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue
        Fail "Failed to download $label`: $_"
    }
    finally {
        if ($in)   { $in.Close() }
        if ($resp) { $resp.Close() }
    }
    OK "$label downloaded."
}

function Extract($zip, $dest) {
    Expand-Archive -Path $zip -DestinationPath $dest -Force
}

# Versions and download addresses come from versions.json; PHP can be chosen per setup.
. (Join-Path $PSScriptRoot 'versions.ps1')
$V = Get-StackVersions $Base
if ([string]::IsNullOrWhiteSpace($PhpVersion)) { $PhpVersion = $V.php.default }
if ($PhpVersion -notmatch '^\d+\.\d+\.\d+$') { Fail "Invalid PHP version '$PhpVersion' (expected e.g. 8.3.31)." }
if ([version]$PhpVersion -lt [version]$V.php.min) { Fail "PHP $PhpVersion is older than the supported minimum $($V.php.min)." }
$NginxVer = $V.nginx.version
$MysqlVer = $V.mysql.version
$PmaVer   = $V.phpmyadmin.version

Write-Host ""
Write-Host "============================================" -ForegroundColor Blue
Write-Host "  Local WordPress Stack - Setup" -ForegroundColor Blue
Write-Host "  Base: $Base" -ForegroundColor Blue
Write-Host "============================================" -ForegroundColor Blue
Write-Host ""

# ============================================================
# LocalIP
# ============================================================
$LocalIP = (Get-NetIPConfiguration | Where-Object { $_.IPv4DefaultGateway -ne $null -and $_.NetAdapter.Status -eq 'Up' } | Select-Object -First 1).IPv4Address.IPAddress
if (-not $LocalIP) { $LocalIP = "127.0.0.1" }
Write-Host "[*] Local IP: $LocalIP" -ForegroundColor Cyan

# ============================================================
# DIRECTORIES
# ============================================================
Step "Creating directory structure..."
@(
    "$Base\nginx", "$Base\mysql\data", "$Base\mysql\logs",
    "$Base\php", "$Base\phpmyadmin", "$Base\sites",
    "$Base\config\nginx\snippets", "$Base\logs\nginx",
    "$Base\logs\php"
)| ForEach-Object { New-Item -ItemType Directory -Path $_ -Force | Out-Null }
OK "Directories ready."

# ============================================================
# NGINX
# ============================================================
if (!(Test-Path "$Base\nginx\nginx.exe")) {
    Download (Expand-VersionUrl $V.nginx.url $NginxVer) "$Base\_nginx.zip" "Nginx $NginxVer"
    Step "Extracting Nginx..."
    Extract "$Base\_nginx.zip" "$Base\_nginx_tmp"
    Copy-Item "$Base\_nginx_tmp\$(Expand-VersionUrl $V.nginx.folder $NginxVer)\*" "$Base\nginx\" -Recurse -Force
    Remove-Item "$Base\_nginx_tmp","$Base\_nginx.zip" -Recurse -Force
    OK "Nginx installed."
} else { Skip "Nginx" }

# ============================================================
# MYSQL
# ============================================================
if (!(Test-Path "$Base\mysql\bin\mysqld.exe")) {
    Download (Expand-VersionUrl $V.mysql.url $MysqlVer) "$Base\_mysql.zip" "MySQL $MysqlVer"
    Step "Extracting MySQL..."
    Extract "$Base\_mysql.zip" "$Base\_mysql_tmp"
    $mysqlDir = (Get-ChildItem "$Base\_mysql_tmp" -Directory | Select-Object -First 1).FullName
    foreach ($f in @("bin","lib","share","include")) {
        Copy-Item (Join-Path $mysqlDir $f) "$Base\mysql\" -Recurse -Force
    }
    Remove-Item "$Base\_mysql_tmp","$Base\_mysql.zip" -Recurse -Force
    OK "MySQL installed."
} else { Skip "MySQL" }

# ============================================================
# PHP
# ============================================================
if (!(Test-Path "$Base\php\php-cgi.exe")) {
    Step "Looking up PHP $PhpVersion..."
    $phpUrl = Resolve-PhpZipUrl $PhpVersion
    if (-not $phpUrl) { Fail "No Windows x64 NTS build found for PHP $PhpVersion on windows.php.net." }
    Download $phpUrl "$Base\_php.zip" "PHP $PhpVersion NTS"
    Step "Extracting PHP..."
    Extract "$Base\_php.zip" "$Base\php"
    Remove-Item "$Base\_php.zip" -Force
    OK "PHP installed."
} else { Skip "PHP (keeping the installed version; delete php\ to install $PhpVersion)" }

# ============================================================
# PHPMYADMIN
# ============================================================
if (!(Test-Path "$Base\phpmyadmin\index.php")) {
    Download (Expand-VersionUrl $V.phpmyadmin.url $PmaVer) "$Base\_pma.zip" "phpMyAdmin $PmaVer"
    Step "Extracting phpMyAdmin..."
    Extract "$Base\_pma.zip" "$Base\_pma_tmp"
    Copy-Item "$Base\_pma_tmp\$(Expand-VersionUrl $V.phpmyadmin.folder $PmaVer)\*" "$Base\phpmyadmin\" -Recurse -Force
    Remove-Item "$Base\_pma_tmp","$Base\_pma.zip" -Recurse -Force
    OK "phpMyAdmin installed."
} else { Skip "phpMyAdmin" }

# ============================================================
# PHP.INI
# ============================================================
Step "Configuring PHP..."
Copy-Item "$Base\php\php.ini-production" "$Base\php\php.ini" -Force
$BaseSlash = $Base.Replace('\','/')
$ini = Get-Content "$Base\php\php.ini"
$ini = $ini -replace ';extension_dir = "ext"',"extension_dir = `"$BaseSlash/php/ext`""
# "gd2" is the PHP 7.x name of gd; only lines present in this version's php.ini change.
foreach ($ext in @("curl","exif","fileinfo","gd","gd2","intl","mbstring","mysqli","openssl","pdo_mysql","zip")) {
    $ini = $ini -replace ";extension=$ext","extension=$ext"
}
$ini = $ini -replace "upload_max_filesize = 2M","upload_max_filesize = 64M"
$ini = $ini -replace "post_max_size = 8M","post_max_size = 64M"
$ini = $ini -replace "max_execution_time = 30","max_execution_time = 120"
$ini = $ini -replace "memory_limit = 128M","memory_limit = 256M"
Set-Content "$Base\php\php.ini" $ini
OK "php.ini configured."

# ============================================================
# MYSQL CONFIG + INIT
# ============================================================
Step "Configuring MySQL..."
@"
[mysqld]
basedir=$BaseSlash/mysql
datadir=$BaseSlash/mysql/data
port=3307
log-error=$BaseSlash/mysql/logs/mysql-error.log
max_allowed_packet=64M
innodb_buffer_pool_size=128M
character-set-server=utf8mb4
collation-server=utf8mb4_unicode_ci

[client]
port=3307
default-character-set=utf8mb4
"@ | Set-Content "$Base\mysql\my.ini"
OK "MySQL config written."

if (!(Test-Path "$Base\mysql\data\mysql")) {
    Step "Initializing MySQL data directory (this takes ~30s)..."
    & "$Base\mysql\bin\mysqld.exe" --defaults-file="$Base\mysql\my.ini" --initialize-insecure 2>&1 | Out-Null
    OK "MySQL initialized."
} else { Skip "MySQL data directory" }

# ============================================================
# NGINX CONFIGS
# ============================================================
Step "Writing Nginx configs..."

@"
worker_processes  1;

error_log  off;
pid        "$BaseSlash/nginx/logs/nginx.pid";

events {
    worker_connections  1024;
}

http {
    include       mime.types;
    default_type  application/octet-stream;

    access_log  off;

    sendfile        on;
    keepalive_timeout  65;
    client_max_body_size 64M;

    upstream php {
        server 127.0.0.1:9000;
        keepalive 8;
    }

    server {
        listen 80 default_server;
        server_name _;
        root "$BaseSlash";
        index index.html;
        location / { try_files `$uri `$uri/ =404; }
        location ~ \.php$ {
            try_files `$uri =404;
            fastcgi_pass php;
            fastcgi_index index.php;
            fastcgi_param SCRIPT_FILENAME `$document_root`$fastcgi_script_name;
            include fastcgi_params;
        }
    }

    include "$BaseSlash/config/nginx/*.conf";
}
"@ | Set-Content "$Base\nginx\conf\nginx.conf"

@"
index index.php index.html;

location ~ /\. { deny all; }
location = /xmlrpc.php { deny all; }

location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot)$ {
    expires max;
    log_not_found off;
}

location / {
    try_files `$uri `$uri/ /index.php?`$args;
}

location ~ \.php$ {
    try_files `$uri =404;
    fastcgi_split_path_info ^(.+\.php)(/.+)$;
    fastcgi_pass php;
    fastcgi_index index.php;
    fastcgi_param SCRIPT_FILENAME `$document_root`$fastcgi_script_name;
    fastcgi_param REQUEST_SCHEME `$scheme;
    fastcgi_param HTTP_X_FORWARDED_PROTO `$scheme;
    fastcgi_param HTTP_X_FORWARDED_PORT `$server_port;
    fastcgi_param SERVER_PORT `$server_port;
    include fastcgi_params;
    fastcgi_read_timeout 300;
    fastcgi_buffers 16 16k;
    fastcgi_buffer_size 32k;
}
"@ | Set-Content "$Base\config\nginx\snippets\wordpress-common.conf"

@"
server {
    listen 8080;
    server_name localhost;
    root "$BaseSlash/phpmyadmin";
    index index.php;
    access_log  off;
    error_log   off;
    location / { try_files `$uri `$uri/ =404; }
    location ~ \.php$ {
        try_files `$uri =404;
        fastcgi_pass php;
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME `$document_root`$fastcgi_script_name;
        include fastcgi_params;
        fastcgi_read_timeout 600;
    }
    location ~ /\. { deny all; }
}
"@ | Set-Content "$Base\config\nginx\phpmyadmin.conf"

OK "Nginx configs written."

# ============================================================
# PHPMYADMIN CONFIG
# ============================================================
Step "Configuring phpMyAdmin..."
@"
<?php
declare(strict_types=1);

`$cfg['blowfish_secret'] = 'W9xK2mP4nQ7rT1vY3uZ6aB8cD0eF5gH';

`$i = 0;
`$i++;
`$cfg['Servers'][`$i]['auth_type']       = 'cookie';
`$cfg['Servers'][`$i]['host']            = '127.0.0.1';
`$cfg['Servers'][`$i]['port']            = '3307';
`$cfg['Servers'][`$i]['compress']        = false;
`$cfg['Servers'][`$i]['AllowNoPassword'] = true;

`$cfg['UploadDir'] = '';
`$cfg['SaveDir']   = '';
"@ | Set-Content "$Base\phpmyadmin\config.inc.php"
OK "phpMyAdmin configured."

# ============================================================
# PORTS TRACKER
# ============================================================
if (!(Test-Path "$Base\config\ports.txt")) {
    Set-Content "$Base\config\ports.txt" "9000"
}

# ============================================================
# DONE
# ============================================================
Write-Host ""
Write-Host "============================================" -ForegroundColor Green
Write-Host "  Setup complete!" -ForegroundColor Green
Write-Host "  Use the control panel to start the stack." -ForegroundColor White
Write-Host "============================================" -ForegroundColor Green
Write-Host ""
