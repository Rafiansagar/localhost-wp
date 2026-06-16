param([string]$Base = "")

$ErrorActionPreference = "Stop"
$Base = if ([string]::IsNullOrWhiteSpace($Base)) { Split-Path -Parent $PSScriptRoot } else { $Base }
$Base = $Base.TrimEnd('\').TrimEnd('/')
$sslDir = Join-Path $Base "ssl"
$localIp = (Get-NetIPConfiguration | Where-Object { $_.IPv4DefaultGateway -ne $null -and $_.NetAdapter.Status -eq 'Up' } | Select-Object -First 1).IPv4Address.IPAddress
if (-not $localIp) { $localIp = "127.0.0.1" }
$certPath = Join-Path $sslDir "cert.pem"
$keyPath = Join-Path $sslDir "key.pem"
$csrPath = Join-Path $sslDir "cert.csr"
$rootCAPath = Join-Path $sslDir "rootCA.pem"
$rootCAKeyPath = Join-Path $sslDir "rootCA.key"
$rootCAConfigPath = Join-Path $sslDir "rootCA.cnf"
$confPath = Join-Path $sslDir "openssl.cnf"

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

$shouldGenerateServerCert = $true
if ((Test-Path $certPath) -and (Test-Path $keyPath) -and (Test-Path $rootCAPath)) {
    $certSanOutput = & $openSsl x509 -in $certPath -noout -ext subjectAltName 2>$null | Out-String
    $certSanReadOk = ($LASTEXITCODE -eq 0)
    & $openSsl x509 -in $certPath -noout -checkend 0 2>$null | Out-Null
    $certStillValid = ($certSanReadOk -and ($LASTEXITCODE -eq 0))
    $hasLocalhost = $certSanOutput -match 'DNS:localhost'
    $hasLoopback = $certSanOutput -match 'IP Address:127\.0\.0\.1'
    $hasCurrentIp = $certSanOutput -match ("IP Address:{0}" -f [regex]::Escape($localIp))
    if ($certStillValid -and $hasLocalhost -and $hasLoopback -and $hasCurrentIp) {
        $shouldGenerateServerCert = $false
    }
}

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
"@ | Set-Content $rootCAConfigPath

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
IP.2 = $localIp
"@ | Set-Content $confPath

try {
    if (!(Test-Path $rootCAPath) -or !(Test-Path $rootCAKeyPath)) {
        & $openSsl req -x509 -nodes -newkey rsa:2048 -keyout $rootCAKeyPath -out $rootCAPath -days 3650 -config $rootCAConfigPath -extensions v3_ca -subj "/CN=localhost-wp Root CA"
    }
    if ($shouldGenerateServerCert) {
        & $openSsl req -nodes -newkey rsa:2048 -keyout $keyPath -out $csrPath -config $confPath -subj "/CN=localhost"
        & $openSsl x509 -req -in $csrPath -CA $rootCAPath -CAkey $rootCAKeyPath -CAcreateserial -out $certPath -days 825 -sha256 -extfile $confPath -extensions v3_req
    }
    if (!(Test-Path $certPath) -or !(Test-Path $keyPath) -or !(Test-Path $rootCAPath)) {
        throw "Certificate generation did not produce the expected CA and server certificate files."
    }
    Import-Certificate -FilePath $rootCAPath -CertStoreLocation "Cert:\CurrentUser\Root" | Out-Null
    Write-Host "[+] Local CA trusted for current user."
    if ($shouldGenerateServerCert) {
        Write-Host "[+] SSL certificate generated for localhost, 127.0.0.1, and $localIp."
    } else {
        Write-Host "[=] Existing SSL certificate already covers localhost, 127.0.0.1, and $localIp."
    }
} finally {
    if (Test-Path $rootCAConfigPath) {
        Remove-Item $rootCAConfigPath -Force
    }
    if (Test-Path $confPath) {
        Remove-Item $confPath -Force
    }
    if (Test-Path $csrPath) {
        Remove-Item $csrPath -Force
    }
}
