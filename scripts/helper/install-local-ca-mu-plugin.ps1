param([string]$Base = "", [string]$SiteName = "")

$ErrorActionPreference = "Stop"

$Base = if ([string]::IsNullOrWhiteSpace($Base)) { Split-Path -Parent $PSScriptRoot } else { $Base }
$Base = $Base.TrimEnd('\').TrimEnd('/')

$siteRoots = @()
if ([string]::IsNullOrWhiteSpace($SiteName)) {
    $sitesDir = Join-Path $Base "sites"
    if (Test-Path $sitesDir) {
        $siteRoots = Get-ChildItem $sitesDir -Directory | ForEach-Object { Join-Path $_.FullName "public\wp-content" }
    }
} else {
    $siteRoots = @(Join-Path $Base "sites\$SiteName\public\wp-content")
}

$plugin = @"
<?php
/**
 * Plugin Name: Localhost SSL Trust
 * Description: Trust the local root CA for WordPress outbound HTTPS requests in the local stack.
 */

if (!defined('ABSPATH') || !defined('WP_CONTENT_DIR')) {
    return;
}

function localhost_wp_root_ca_path() {
    `$base = realpath(WP_CONTENT_DIR . '/../../../..');
    if (!`$base) {
        return false;
    }
    return `$base . DIRECTORY_SEPARATOR . 'ssl' . DIRECTORY_SEPARATOR . 'rootCA.pem';
}

function localhost_wp_is_local_https_url(`$url) {
    `$parts = wp_parse_url(`$url);
    if (empty(`$parts['scheme']) || strtolower(`$parts['scheme']) !== 'https' || empty(`$parts['host'])) {
        return false;
    }

    `$host = strtolower(`$parts['host']);
    if (`$host === 'localhost' || `$host === '127.0.0.1') {
        return true;
    }

    if (filter_var(`$host, FILTER_VALIDATE_IP, FILTER_FLAG_IPV4) === false) {
        return false;
    }

    `$localIp = gethostbyname(gethostname());
    return `$host === `$localIp;
}

add_filter('http_request_args', function (`$args, `$url) {
    if (!localhost_wp_is_local_https_url(`$url)) {
        return `$args;
    }

    `$rootCa = localhost_wp_root_ca_path();
    if (!`$rootCa || !is_readable(`$rootCa)) {
        return `$args;
    }

    `$args['sslcertificates'] = `$rootCa;
    return `$args;
}, 10, 2);

add_action('http_api_curl', function (`$handle, `$parsed_args, `$url) {
    if (!localhost_wp_is_local_https_url(`$url)) {
        return;
    }

    `$rootCa = localhost_wp_root_ca_path();
    if (`$rootCa && is_readable(`$rootCa)) {
        curl_setopt(`$handle, CURLOPT_CAINFO, `$rootCa);
    }
}, 10, 3);
?>
"@

foreach ($wpContentDir in $siteRoots) {
    if (!(Test-Path $wpContentDir)) {
        continue
    }
    $muPluginsDir = Join-Path $wpContentDir "mu-plugins"
    $pluginPath = Join-Path $muPluginsDir "localhost-ssl-trust.php"
    New-Item -ItemType Directory -Force -Path $muPluginsDir | Out-Null
    $existingPlugin = if (Test-Path $pluginPath) { Get-Content -Path $pluginPath -Raw } else { $null }
    if ($existingPlugin -ne $plugin) {
        Set-Content -Path $pluginPath -Value $plugin -Encoding UTF8
        Write-Host "[+] Local CA MU plugin installed: $muPluginsDir"
    } else {
        Write-Host "[=] Local CA MU plugin already up to date: $muPluginsDir"
    }
}
