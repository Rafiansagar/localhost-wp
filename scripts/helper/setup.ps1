param([string]$Base = "")

$Base = if ([string]::IsNullOrWhiteSpace($Base)) { Split-Path -Parent (Split-Path -Parent $PSScriptRoot) } else { $Base }
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
    "$Base\logs\php", "$Base\ssl"
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
    Download "https://downloads.php.net/~windows/releases/php-8.3.30-nts-Win32-vs16-x86.zip" "$Base\_php.zip" "PHP 8.3.30 NTS"
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
$caFile = "$BaseSlash/ssl/rootCA.pem"
$ini = Get-Content "$Base\php\php.ini"
$ini = $ini -replace ';extension_dir = "ext"',"extension_dir = `"$BaseSlash/php/ext`""
foreach ($ext in @("curl","exif","fileinfo","gd","intl","mbstring","mysqli","openssl","pdo_mysql","zip")) {
    $ini = $ini -replace ";extension=$ext","extension=$ext"
}
$ini = $ini -replace "upload_max_filesize = 2M","upload_max_filesize = 64M"
$ini = $ini -replace "post_max_size = 8M","post_max_size = 64M"
$ini = $ini -replace "max_execution_time = 30","max_execution_time = 120"
$ini = $ini -replace "memory_limit = 128M","memory_limit = 256M"
$ini = $ini -replace ';curl.cainfo =',"curl.cainfo = `"$caFile`""
$ini = $ini -replace ';openssl.cafile=',"openssl.cafile = `"$caFile`""
$ini = $ini -replace ';openssl.capath=',"openssl.capath ="
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
if (!(Test-Path "$Base\ssl\cert.pem") -or !(Test-Path "$Base\ssl\rootCA.pem") -or !(Test-Path "$Base\ssl\rootCA.key")) {
    Step "Generating local CA and SSL certificate..."
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
x509_extensions = v3_ca
prompt = no

[req_distinguished_name]
CN = localhost-wp Root CA

[v3_ca]
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always,issuer
basicConstraints = critical, CA:true
keyUsage = critical, keyCertSign, cRLSign
"@ | Set-Content "$Base\ssl\rootCA.cnf"
    @"
[req]
distinguished_name = req_distinguished_name
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
IP.2 = $LocalIP
"@ | Set-Content "$Base\ssl\openssl.cnf"
    try {
        if (!(Test-Path "$Base\ssl\rootCA.pem") -or !(Test-Path "$Base\ssl\rootCA.key")) {
            & $openSsl req -x509 -nodes -newkey rsa:2048 -keyout "$Base\ssl\rootCA.key" -out "$Base\ssl\rootCA.pem" -days 3650 -config "$Base\ssl\rootCA.cnf" -extensions v3_ca -subj "/CN=localhost-wp Root CA" | Out-Null
        }
        & $openSsl req -nodes -newkey rsa:2048 -keyout "$Base\ssl\key.pem" -out "$Base\ssl\cert.csr" -config "$Base\ssl\openssl.cnf" -subj "/CN=localhost" | Out-Null
        & $openSsl x509 -req -in "$Base\ssl\cert.csr" -CA "$Base\ssl\rootCA.pem" -CAkey "$Base\ssl\rootCA.key" -CAcreateserial -out "$Base\ssl\cert.pem" -days 825 -sha256 -extfile "$Base\ssl\openssl.cnf" -extensions v3_req | Out-Null
        Import-Certificate -FilePath "$Base\ssl\rootCA.pem" -CertStoreLocation "Cert:\CurrentUser\Root" | Out-Null
    } finally {
        Remove-Item "$Base\ssl\openssl.cnf" -Force -ErrorAction SilentlyContinue
        Remove-Item "$Base\ssl\rootCA.cnf" -Force -ErrorAction SilentlyContinue
        Remove-Item "$Base\ssl\cert.csr" -Force -ErrorAction SilentlyContinue
    }
    OK "SSL certificate ready and local CA trusted for current user."
} else { Skip "SSL certificate" }

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

server {
    listen 8443 ssl;
    server_name localhost;
    ssl_certificate     "$BaseSlash/ssl/cert.pem";
    ssl_certificate_key "$BaseSlash/ssl/key.pem";
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;
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
    Set-Content "$Base\config\ports.txt" "8000"
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
