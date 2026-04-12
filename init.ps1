param([string]$Base = "")

$Base = if ([string]::IsNullOrWhiteSpace($Base)) { $PSScriptRoot } else { $Base }
$Base = $Base.TrimEnd('\').TrimEnd('/')
$ErrorActionPreference = "Stop"

function Step($msg)  { Write-Host "[*] $msg" -ForegroundColor Cyan }
function OK($msg)    { Write-Host "[+] $msg" -ForegroundColor Green }
function Skip($msg)  { Write-Host "[=] $msg - already exists, skipping." -ForegroundColor DarkGray }
function Fail($msg)  { Write-Host "[!] $msg" -ForegroundColor Red; exit 1 }

function Download($url, $dest, $label) {
    if (Test-Path $dest) { Skip $label; return }
    Step "Downloading $label..."
    try { Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing }
    catch { Fail "Failed to download $label`: $_" }
    OK "$label downloaded."
}

function Extract($zip, $dest) {
    Expand-Archive -Path $zip -DestinationPath $dest -Force
}

Write-Host ""
Write-Host "============================================" -ForegroundColor Blue
Write-Host "  Local WordPress Stack - Init" -ForegroundColor Blue
Write-Host "  Base: $Base" -ForegroundColor Blue
Write-Host "============================================" -ForegroundColor Blue
Write-Host ""

# ============================================================
# DIRECTORIES
# ============================================================
Step "Creating directory structure..."
@(
    "$Base\nginx", "$Base\mysql\data", "$Base\mysql\logs",
    "$Base\php", "$Base\phpmyadmin", "$Base\sites",
    "$Base\config\nginx\snippets", "$Base\logs\nginx",
    "$Base\logs\php", "$Base\scripts", "$Base\ssl"
) | ForEach-Object { New-Item -ItemType Directory -Path $_ -Force | Out-Null }
OK "Directories ready."

# ============================================================
# NGINX
# ============================================================
if (!(Test-Path "$Base\nginx\nginx.exe")) {
    Download "https://nginx.org/download/nginx-1.26.3.zip" "$Base\_nginx.zip" "Nginx 1.26.3"
    Step "Extracting Nginx..."
    Extract "$Base\_nginx.zip" "$Base\_nginx_tmp"
    Copy-Item "$Base\_nginx_tmp\nginx-1.26.3\*" "$Base\nginx\" -Recurse -Force
    Remove-Item "$Base\_nginx_tmp","$Base\_nginx.zip" -Recurse -Force
    OK "Nginx installed."
} else { Skip "Nginx" }

# ============================================================
# MYSQL
# ============================================================
if (!(Test-Path "$Base\mysql\bin\mysqld.exe")) {
    Download "https://cdn.mysql.com/archives/mysql-8.0/mysql-8.0.36-winx64.zip" "$Base\_mysql.zip" "MySQL 8.0.36"
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
    Download "https://windows.php.net/downloads/releases/php-8.5.5-nts-Win32-vs17-x64.zip" "$Base\_php.zip" "PHP 8.5.5 NTS"
    Step "Extracting PHP..."
    Extract "$Base\_php.zip" "$Base\php"
    Remove-Item "$Base\_php.zip" -Force
    OK "PHP installed."
} else { Skip "PHP" }

# ============================================================
# PHPMYADMIN
# ============================================================
if (!(Test-Path "$Base\phpmyadmin\index.php")) {
    Download "https://files.phpmyadmin.net/phpMyAdmin/5.2.2/phpMyAdmin-5.2.2-all-languages.zip" "$Base\_pma.zip" "phpMyAdmin 5.2.2"
    Step "Extracting phpMyAdmin..."
    Extract "$Base\_pma.zip" "$Base\_pma_tmp"
    Copy-Item "$Base\_pma_tmp\phpMyAdmin-5.2.2-all-languages\*" "$Base\phpmyadmin\" -Recurse -Force
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
foreach ($ext in @("curl","exif","fileinfo","gd","intl","mbstring","mysqli","openssl","pdo_mysql","zip")) {
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
# SSL CERTIFICATE
# ============================================================
if (!(Test-Path "$Base\ssl\cert.pem")) {
    Step "Generating self-signed SSL certificate..."
    $openSsl = $null
    $cmd = Get-Command openssl -ErrorAction SilentlyContinue
    if ($cmd) { $openSsl = $cmd.Source }
    if (-not $openSsl) {
        foreach ($candidate in @(
            "C:\Program Files\Git\mingw64\bin\openssl.exe",
            "C:\Program Files\Git\usr\bin\openssl.exe"
        )) {
            if (Test-Path $candidate) {
                $openSsl = $candidate
                break
            }
        }
    }
    if (-not $openSsl) { Fail "OpenSSL executable not found." }
    @"
[req]
distinguished_name = req_distinguished_name
x509_extensions = v3_req
prompt = no

[req_distinguished_name]
CN = localhost

[v3_req]
subjectAltName = @alt_names
keyUsage = digitalSignature, keyEncipherment, dataEncipherment
extendedKeyUsage = serverAuth

[alt_names]
DNS.1 = localhost
IP.1 = 127.0.0.1
"@ | Set-Content "$Base\ssl\openssl.cnf"
    try {
        & $openSsl req -x509 -nodes -newkey rsa:2048 -keyout "$Base\ssl\key.pem" -out "$Base\ssl\cert.pem" -days 3650 -config "$Base\ssl\openssl.cnf" -extensions v3_req -subj "/CN=localhost" | Out-Null
    } finally {
        Remove-Item "$Base\ssl\openssl.cnf" -Force -ErrorAction SilentlyContinue
    }
    OK "SSL certificate ready."
} else { Skip "SSL certificate" }

# ============================================================
# NGINX CONFIGS
# ============================================================
Step "Writing Nginx configs..."

@"
worker_processes  1;

error_log  "$BaseSlash/logs/nginx/error.log" warn;
pid        "$BaseSlash/nginx/logs/nginx.pid";

events {
    worker_connections  1024;
}

http {
    include       mime.types;
    default_type  application/octet-stream;

    log_format  main  '`$remote_addr - `$remote_user [`$time_local] "`$request" '
                      '`$status `$body_bytes_sent "`$http_referer" "`$http_user_agent"';

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

    server {
        listen 443 ssl default_server;
        server_name _;
        ssl_certificate     "$BaseSlash/ssl/cert.pem";
        ssl_certificate_key "$BaseSlash/ssl/key.pem";
        ssl_protocols       TLSv1.2 TLSv1.3;
        ssl_ciphers         HIGH:!aNULL:!MD5;
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
    fastcgi_param HTTPS `$https if_not_empty;
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
    access_log "$BaseSlash/logs/nginx/pma-access.log" main;
    error_log  "$BaseSlash/logs/nginx/pma-error.log" warn;
    location / { try_files `$uri `$uri/ =404; }
    location ~ \.php$ {
        try_files `$uri =404;
        fastcgi_pass php;
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME `$document_root`$fastcgi_script_name;
        include fastcgi_params;
    }
    location ~ /\. { deny all; }
}

server {
    listen 8443 ssl;
    server_name localhost;
    ssl_certificate     "$BaseSlash/ssl/cert.pem";
    ssl_certificate_key "$BaseSlash/ssl/key.pem";
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;
    root "$BaseSlash/phpmyadmin";
    index index.php;
    access_log "$BaseSlash/logs/nginx/pma-access.log" main;
    error_log  "$BaseSlash/logs/nginx/pma-error.log" warn;
    location / { try_files `$uri `$uri/ =404; }
    location ~ \.php$ {
        try_files `$uri =404;
        fastcgi_pass php;
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME `$document_root`$fastcgi_script_name;
        include fastcgi_params;
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
    Set-Content "$Base\config\ports.txt" "8000"
}

# ============================================================
# SCRIPTS
# ============================================================
Step "Writing management scripts..."

function WriteScript($path, $content) {
    Set-Content $path $content
}

# --- ensure-php-runtime.ps1 ---
WriteScript "$Base\scripts\ensure-php-runtime.ps1" @'
param([string]$Base = "")

$ErrorActionPreference = "Stop"
$Base = if ([string]::IsNullOrWhiteSpace($Base)) { Split-Path -Parent $PSScriptRoot } else { $Base }
$phpDir = Join-Path $Base "php"

if (!(Test-Path (Join-Path $phpDir "php.exe"))) {
    throw "PHP directory not found at $phpDir"
}

$sources = @(
    "C:\Program Files (x86)\Microsoft\Edge\Application\146.0.3856.84",
    "C:\Program Files (x86)\Microsoft\EdgeCore\146.0.3856.84",
    "C:\Program Files (x86)\Microsoft\EdgeWebView\Application\146.0.3856.84",
    "C:\Program Files (x86)\Microsoft\EdgeCore\Optimized"
)

$required = @("vcruntime140.dll", "vcruntime140_1.dll", "msvcp140.dll")
$copied = @()

foreach ($name in $required) {
    $dest = Join-Path $phpDir $name
    if (Test-Path $dest) { continue }

    $source = $null
    foreach ($dir in $sources) {
        $candidate = Join-Path $dir $name
        if (Test-Path $candidate) {
            $source = $candidate
            break
        }
    }

    if (-not $source) {
        throw "Required runtime DLL not found: $name"
    }

    Copy-Item $source $dest -Force
    $copied += $name
}

if ($copied.Count -gt 0) {
    Write-Host "[+] PHP runtime DLLs copied: $($copied -join ', ')"
} else {
    Write-Host "[=] PHP runtime DLLs already present."
}
'@

# --- start-php.ps1 ---
WriteScript "$Base\scripts\start-php.ps1" @'
param([string]$PhpCgi = "")

$ErrorActionPreference = "Stop"

$PhpCgi = if ([string]::IsNullOrWhiteSpace($PhpCgi)) { Join-Path (Split-Path -Parent $PSScriptRoot) "php\php-cgi.exe" } else { $PhpCgi }

if (!(Test-Path $PhpCgi)) { throw "php-cgi.exe not found: $PhpCgi" }

$phpDir = Split-Path -Parent $PhpCgi
$iniPath = Join-Path $phpDir "php.ini"
if (!(Test-Path $iniPath)) { throw "php.ini not found: $iniPath" }

Start-Process -FilePath $PhpCgi -ArgumentList "-c `"$iniPath`" -b 127.0.0.1:9000" -WorkingDirectory $phpDir -WindowStyle Hidden
Write-Host "[+] PHP FastCGI started on 127.0.0.1:9000."
'@

# --- generate-ssl.ps1 ---
WriteScript "$Base\scripts\generate-ssl.ps1" @'
param([string]$Base = "")

$ErrorActionPreference = "Stop"
$Base = if ([string]::IsNullOrWhiteSpace($Base)) { Split-Path -Parent $PSScriptRoot } else { $Base }
$Base = $Base.TrimEnd('\').TrimEnd('/')
$sslDir = Join-Path $Base "ssl"
$certPath = Join-Path $sslDir "cert.pem"
$keyPath = Join-Path $sslDir "key.pem"
$confPath = Join-Path $sslDir "openssl.cnf"

if ((Test-Path $certPath) -and (Test-Path $keyPath)) {
    Write-Host "[=] SSL certificate already exists."
    exit 0
}

$openSsl = $null
$cmd = Get-Command openssl -ErrorAction SilentlyContinue
if ($cmd) {
    $openSsl = $cmd.Source
}

if (-not $openSsl) {
    foreach ($candidate in @(
        "C:\Program Files\Git\mingw64\bin\openssl.exe",
        "C:\Program Files\Git\usr\bin\openssl.exe"
    )) {
        if (Test-Path $candidate) {
            $openSsl = $candidate
            break
        }
    }
}

if (-not $openSsl) {
    throw "OpenSSL executable not found."
}

New-Item -ItemType Directory -Force -Path $sslDir | Out-Null

@"
[req]
distinguished_name = req_distinguished_name
x509_extensions = v3_req
prompt = no

[req_distinguished_name]
CN = localhost

[v3_req]
subjectAltName = @alt_names
keyUsage = digitalSignature, keyEncipherment, dataEncipherment
extendedKeyUsage = serverAuth

[alt_names]
DNS.1 = localhost
IP.1 = 127.0.0.1
"@ | Set-Content $confPath

try {
    & $openSsl req -x509 -nodes -newkey rsa:2048 -keyout $keyPath -out $certPath -days 3650 -config $confPath -extensions v3_req -subj "/CN=localhost"
    if (!(Test-Path $certPath) -or !(Test-Path $keyPath)) {
        throw "Certificate generation did not produce cert.pem and key.pem."
    }
    Write-Host "[+] SSL certificate generated."
} finally {
    if (Test-Path $confPath) {
        Remove-Item $confPath -Force
    }
}
'@

# --- create-nginx-conf.ps1 ---
WriteScript "$Base\scripts\create-nginx-conf.ps1" @'
param([string]$SiteName, [string]$Port, [string]$Base = "")

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($SiteName)) { throw "SiteName parameter is required." }
if ([string]::IsNullOrWhiteSpace($Port))     { throw "Port parameter is required." }

$Base = if ([string]::IsNullOrWhiteSpace($Base)) { Split-Path -Parent $PSScriptRoot } else { $Base }
$Base = $Base.Replace('\', '/')
$httpsPort = [int]$Port + 1000
$out = "server {`n"
$out += "    listen $Port;`n"
$out += "    server_name localhost 192.168.1.222;`n`n"
$out += "    access_log `"$Base/logs/nginx/$SiteName-access.log`" main;`n"
$out += "    error_log  `"$Base/logs/nginx/$SiteName-error.log`" warn;`n"
$out += "    return 301 https://`$host:$httpsPort`$request_uri;`n"
$out += "}`n`n"
$out += "server {`n"
$out += "    listen $httpsPort ssl;`n"
$out += "    server_name localhost 192.168.1.222;`n`n"
$out += "    ssl_certificate     `"$Base/ssl/cert.pem`";`n"
$out += "    ssl_certificate_key `"$Base/ssl/key.pem`";`n"
$out += "    ssl_protocols       TLSv1.2 TLSv1.3;`n"
$out += "    ssl_ciphers         HIGH:!aNULL:!MD5;`n`n"
$out += "    root `"$Base/sites/$SiteName/public`";`n"
$out += "    access_log `"$Base/logs/nginx/$SiteName-access.log`" main;`n"
$out += "    error_log  `"$Base/logs/nginx/$SiteName-error.log`" warn;`n`n"
$out += "    include `"$Base/config/nginx/snippets/wordpress-common.conf`";`n"
$out += "}`n"
$confDir = "$Base\config\nginx"
if (!(Test-Path $confDir)) { throw "Nginx config directory not found: $confDir" }

Set-Content "$confDir\$SiteName.conf" $out
Write-Host "[+] Nginx config created (HTTP $Port / HTTPS $httpsPort)."
'@

# --- start.bat ---
WriteScript "$Base\scripts\start.bat" @'
@echo off
setlocal EnableDelayedExpansion
set "BASE=%~dp0.."
for %%I in ("%BASE%") do set "BASE=%%~fI"
set NGINX_DIR=%BASE%\nginx
set PHP_CGI=%BASE%\php\php-cgi.exe
set MYSQLD=%BASE%\mysql\bin\mysqld.exe
set MYSQLADMIN=%BASE%\mysql\bin\mysqladmin.exe
set MYSQL_BASE=%BASE%\mysql
set STACK_STATUS=OK

echo [*] Starting local WordPress stack...

tasklist /FI "IMAGENAME eq mysqld.exe" 2>NUL | find /I "mysqld.exe" >NUL
if %ERRORLEVEL% NEQ 0 (
    echo [*] Starting MySQL...
    start "" /min /d "%MYSQL_BASE%\bin" "%MYSQLD%" "--defaults-file=%MYSQL_BASE%\my.ini" --console
    set MYSQL_READY=
    for /L %%I in (1,1,20) do (
        if not defined MYSQL_READY (
            "%MYSQLADMIN%" --protocol=TCP --host=127.0.0.1 --port=3307 -u root ping --silent >NUL 2>&1
            if !ERRORLEVEL! EQU 0 set MYSQL_READY=1
            if not defined MYSQL_READY timeout /t 1 /nobreak >NUL
        )
    )
    if defined MYSQL_READY (
        echo [+] MySQL started on 127.0.0.1:3307.
    ) else (
        echo [ERROR] MySQL did not become ready on 127.0.0.1:3307.
        set STACK_STATUS=ERROR
    )
) else (
    echo [=] MySQL already running.
)

tasklist /FI "IMAGENAME eq php-cgi.exe" 2>NUL | find /I "php-cgi.exe" >NUL
if %ERRORLEVEL% NEQ 0 (
    echo [*] Starting PHP FastCGI on 127.0.0.1:9000...
    powershell -ExecutionPolicy Bypass -File "%BASE%\scripts\ensure-php-runtime.ps1" -Base "%BASE%"
    powershell -ExecutionPolicy Bypass -File "%BASE%\scripts\start-php.ps1" -PhpCgi "%PHP_CGI%"
    timeout /t 2 /nobreak >NUL
) else (
    echo [=] PHP FastCGI already running.
)

if not exist "%BASE%\ssl\cert.pem" (
    echo [*] Generating SSL certificate...
    powershell -ExecutionPolicy Bypass -File "%BASE%\scripts\generate-ssl.ps1" -Base "%BASE%"
)

if not exist "%BASE%\ssl\cert.pem" (
    echo [ERROR] SSL certificate is missing. Nginx cannot start.
    set STACK_STATUS=ERROR
)

if not exist "%BASE%\ssl\key.pem" (
    echo [ERROR] SSL private key is missing. Nginx cannot start.
    set STACK_STATUS=ERROR
)

tasklist /FI "IMAGENAME eq nginx.exe" 2>NUL | find /I "nginx.exe" >NUL
if %ERRORLEVEL% NEQ 0 (
    echo [*] Starting Nginx...
    powershell -Command "$psi=New-Object System.Diagnostics.ProcessStartInfo; $psi.FileName='%NGINX_DIR%\nginx.exe'; $psi.WorkingDirectory='%NGINX_DIR%'; $psi.UseShellExecute=$false; $psi.EnvironmentVariables.Remove('NGINX'); [System.Diagnostics.Process]::Start($psi)|Out-Null"
    timeout /t 2 /nobreak >NUL
    tasklist /FI "IMAGENAME eq nginx.exe" 2>NUL | find /I "nginx.exe" >NUL
    if !ERRORLEVEL! EQU 0 (
        echo [+] Nginx started.
    ) else (
        echo [ERROR] Nginx failed to start. Check logs\nginx\error.log
        set STACK_STATUS=ERROR
    )
) else (
    echo [=] Nginx already running.
)

echo.
if "!STACK_STATUS!"=="OK" (
    echo [OK] Stack is running.
) else (
    echo [WARN] Stack started with errors.
)
echo      Dashboard : https://localhost
echo      phpMyAdmin: http://localhost:8080
echo      Sites dir : %BASE%\sites
echo.
pause
'@

# --- stop.bat ---
WriteScript "$Base\scripts\stop.bat" @'
@echo off
echo [*] Stopping local WordPress stack...
taskkill /F /IM nginx.exe >NUL 2>&1    && echo [+] Nginx stopped.   || echo [=] Nginx not running.
taskkill /F /IM php-cgi.exe >NUL 2>&1  && echo [+] PHP-CGI stopped. || echo [=] PHP-CGI not running.
taskkill /F /IM mysqld.exe >NUL 2>&1   && echo [+] MySQL stopped.   || echo [=] MySQL not running.
echo.
echo [OK] Stack stopped.
pause
'@

# --- reload-nginx.bat ---
WriteScript "$Base\scripts\reload-nginx.bat" @'
@echo off
set "BASE=%~dp0.."
for %%I in ("%BASE%") do set "BASE=%%~fI"
set NGINX_DIR=%BASE%\nginx
echo [*] Reloading Nginx config...
powershell -Command "$psi=New-Object System.Diagnostics.ProcessStartInfo; $psi.FileName='%NGINX_DIR%\nginx.exe'; $psi.WorkingDirectory='%NGINX_DIR%'; $psi.Arguments='-s reload'; $psi.UseShellExecute=$false; $psi.EnvironmentVariables.Remove('NGINX'); [System.Diagnostics.Process]::Start($psi)|Out-Null"
echo [+] Done.
'@

# --- new-site.bat ---
WriteScript "$Base\scripts\new-site.bat" @'
@echo off
setlocal EnableDelayedExpansion
set "BASE=%~dp0.."
for %%I in ("%BASE%") do set "BASE=%%~fI"
set MYSQL_BIN=%BASE%\mysql\bin
set MYSQL_EXE=%MYSQL_BIN%\mysql.exe
set MYSQLADMIN_EXE=%MYSQL_BIN%\mysqladmin.exe
set PORTS_FILE=%BASE%\config\ports.txt

if "%~1"=="" (
    set /P SITE_NAME="Enter site name (e.g. myshop): "
) else (
    set SITE_NAME=%~1
)
if "%SITE_NAME%"=="" ( echo [!] No site name provided. & goto :error )

set SITE_DIR=%BASE%\sites\%SITE_NAME%
set PUBLIC_DIR=%SITE_DIR%\public
set DB_NAME=%SITE_NAME%
set DB_USER=root

if exist "%PUBLIC_DIR%" ( echo [!] Directory already exists. & goto :error )

echo [*] Checking MySQL on 127.0.0.1:3307...
"%MYSQLADMIN_EXE%" --protocol=TCP --host=127.0.0.1 --port=3307 -u root ping --silent >NUL 2>&1
if %ERRORLEVEL% NEQ 0 (
    echo [!] MySQL is not ready on 127.0.0.1:3307. Run scripts\start.bat first.
    goto :error
)

echo [*] Creating database: %DB_NAME%...
"%MYSQL_EXE%" --protocol=TCP --host=127.0.0.1 --port=3307 -u root -e "CREATE DATABASE IF NOT EXISTS `%DB_NAME%` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
if %ERRORLEVEL% NEQ 0 (
    echo [!] Failed to create database.
    goto :error
)
echo [+] Database created.

set PORT=8000
if exist "%PORTS_FILE%" (
    for /F "tokens=*" %%A in (%PORTS_FILE%) do set PORT=%%A
    set /A PORT=PORT+1
)

echo.
echo [*] Creating site: %SITE_NAME%
echo     Directory : %PUBLIC_DIR%
echo     Database  : %DB_NAME%
set /A HTTPS_PORT=!PORT!+1000
echo     URL       : http://localhost:!PORT!  /  https://localhost:!HTTPS_PORT!
echo.

mkdir "%PUBLIC_DIR%"
echo [+] Created directory.

echo [*] Downloading WordPress...
powershell -Command "Invoke-WebRequest -Uri 'https://wordpress.org/latest.zip' -OutFile '%SITE_DIR%\wp.zip' -UseBasicParsing"
if %ERRORLEVEL% NEQ 0 ( echo [!] Failed to download WordPress. & goto :error )
powershell -Command "Expand-Archive -Path '%SITE_DIR%\wp.zip' -DestinationPath '%SITE_DIR%\wp_tmp' -Force"
if %ERRORLEVEL% NEQ 0 ( echo [!] Failed to extract WordPress archive. & goto :error )
xcopy /E /Q "%SITE_DIR%\wp_tmp\wordpress\*" "%PUBLIC_DIR%\" >NUL
if %ERRORLEVEL% GEQ 4 ( echo [!] Failed to copy WordPress files. & goto :error )
rmdir /S /Q "%SITE_DIR%\wp_tmp"
del "%SITE_DIR%\wp.zip"
echo [+] WordPress downloaded and extracted.

echo [*] Creating wp-config.php...
copy "%PUBLIC_DIR%\wp-config-sample.php" "%PUBLIC_DIR%\wp-config.php" >NUL
powershell -Command "(Get-Content '%PUBLIC_DIR%\wp-config.php') -replace 'database_name_here','%DB_NAME%' -replace 'username_here','root' -replace 'password_here','' -replace \"define\( 'DB_HOST', 'localhost' \)\",\"define( 'DB_HOST', '127.0.0.1:3307' )\" | Set-Content '%PUBLIC_DIR%\wp-config.php'"
echo [+] wp-config.php created.

echo [*] Creating Nginx config on port !PORT!...
powershell -ExecutionPolicy Bypass -File "%BASE%\scripts\create-nginx-conf.ps1" -SiteName "%SITE_NAME%" -Port "!PORT!" -Base "%BASE%"
if %ERRORLEVEL% NEQ 0 ( echo [!] Failed to create Nginx config. & goto :error )

echo !PORT! > "%PORTS_FILE%"

call "%BASE%\scripts\reload-nginx.bat"

echo.
echo ============================================
echo  Site ready^^!
set /A HTTPS_PORT=!PORT!+1000
echo  HTTP  : http://localhost:!PORT!
echo  HTTPS : https://localhost:!HTTPS_PORT!
echo  DB    : %DB_NAME% (root / no password)
echo  PMA   : http://localhost:8080
echo ============================================
echo.
goto :done

:error
echo.
echo [!] Setup failed. See error above.

:done
pause
'@

# --- delete-site.bat ---
WriteScript "$Base\scripts\delete-site.bat" @'
@echo off
setlocal EnableDelayedExpansion
set "BASE=%~dp0.."
for %%I in ("%BASE%") do set "BASE=%%~fI"
set MYSQL_BIN=%BASE%\mysql\bin
set MYSQL_EXE=%MYSQL_BIN%\mysql.exe

if "%~1"=="" (
    echo.
    echo Available sites:
    for /D %%D in ("%BASE%\sites\*") do echo   - %%~nxD
    echo.
    set /P SITE_NAME="Enter site name to delete: "
) else (
    set SITE_NAME=%~1
)
if "%SITE_NAME%"=="" ( echo [!] No site name provided. & exit /b 1 )

set SITE_DIR=%BASE%\sites\%SITE_NAME%
set NGINX_CONF=%BASE%\config\nginx\%SITE_NAME%.conf

echo.
echo [!] About to permanently delete:
echo     Files  : %SITE_DIR%
echo     DB     : %SITE_NAME%
echo     Config : %NGINX_CONF%
echo.
set /P CONFIRM="Type the site name to confirm: "
if /I "!CONFIRM!" NEQ "%SITE_NAME%" ( echo [!] Name did not match. Aborting. & exit /b 1 )
echo.

if exist "%SITE_DIR%" (
    echo [*] Deleting files...
    rmdir /S /Q "%SITE_DIR%"
    echo [+] Files deleted.
) else ( echo [=] No files found. )

echo [*] Dropping database...
"%MYSQL_EXE%" --protocol=TCP --host=127.0.0.1 --port=3307 -u root -e "DROP DATABASE IF EXISTS `%SITE_NAME%`;"
if %ERRORLEVEL% EQU 0 ( echo [+] Database dropped. ) else ( echo [!] Could not drop DB. Is MySQL running? )

if exist "%NGINX_CONF%" (
    del "%NGINX_CONF%"
    echo [+] Nginx config removed.
) else ( echo [=] No Nginx config found. )

call "%BASE%\scripts\reload-nginx.bat"

echo.
echo [OK] Site "%SITE_NAME%" deleted.
echo.
pause
'@

OK "Scripts written."

# ============================================================
# STATUS.PHP
# ============================================================
Step "Writing dashboard files..."

@"
<?php
header('Content-Type: application/json');
`$configDir = __DIR__ . '/config/nginx';
`$sites = [];
foreach (glob(`$configDir . '/*.conf') as `$file) {
    `$name = basename(`$file, '.conf');
    if (`$name === 'phpmyadmin') continue;
    `$content = file_get_contents(`$file);
    preg_match('/listen\s+(\d+)/', `$content, `$portMatch);
    preg_match('/root\s+([^\n;]+)/', `$content, `$rootMatch);
    `$port = `$portMatch[1] ?? null;
    `$root = trim(`$rootMatch[1] ?? '', " \t\n\r\0\x0B\"'");
    if (!`$port) continue;
    `$sites[] = [
        'name'      => `$name,
        'port'      => (int)`$port,
        'url'       => 'http://localhost:' . `$port,
        'url_https' => 'https://localhost:' . ((int)`$port + 1000),
        'root'      => `$root,
        'installed' => file_exists(`$root . '/wp-config.php'),
    ];
}
usort(`$sites, fn(`$a, `$b) => `$a['port'] - `$b['port']);
echo json_encode(`$sites);
"@ | Set-Content "$Base\status.php"

OK "Dashboard files written."

# ============================================================
# START THE STACK
# ============================================================
Step "Starting MySQL..."
& cmd /c "$Base\scripts\start.bat"

# ============================================================
# DONE
# ============================================================
Write-Host ""
Write-Host "============================================" -ForegroundColor Green
Write-Host "  Stack is ready!" -ForegroundColor Green
Write-Host ""
Write-Host "  Dashboard  : https://localhost  (also http://localhost)" -ForegroundColor White
Write-Host "  phpMyAdmin : https://localhost:8443  (also http://localhost:8080)" -ForegroundColor White
Write-Host ""
Write-Host "  Create a site : scripts\new-site.bat" -ForegroundColor White
Write-Host "  Stop stack    : scripts\stop.bat" -ForegroundColor White
Write-Host "  Start stack   : scripts\start.bat" -ForegroundColor White
Write-Host "============================================" -ForegroundColor Green
Write-Host ""

Start-Process "http://localhost"
