# ============================================================================
#  versions.ps1  -  binary versions and download addresses
#  Dot-sourced by setup.ps1 and the dashboard server. The versions themselves
#  live in versions.json at the stack root; nothing here is version-specific.
# ============================================================================

# versions.json as an object. {v} = full version, {mm} = major.minor.
function Get-StackVersions([string]$Base) {
    Get-Content -Raw -LiteralPath (Join-Path $Base 'versions.json') | ConvertFrom-Json
}

function Expand-VersionUrl([string]$template, [string]$version) {
    $mm = ($version -split '\.')[0..1] -join '.'
    $template.Replace('{v}', $version).Replace('{mm}', $mm)
}

# Windows PHP builds are tied to a compiler: 7.x vc15, 8.0-8.3 vs16, 8.4+ vs17.
function Get-PhpBuild([string]$version) {
    $v = [version]$version
    if ($v.Major -lt 8) { return 'vc15' }
    if ($v -lt [version]'8.4') { return 'vs16' }
    return 'vs17'
}

# The newest patch of each branch sits in releases/, everything else in archives/.
function Get-PhpZipUrls([string]$version) {
    $file = "php-$version-nts-Win32-$(Get-PhpBuild $version)-x64.zip"
    @(
        "https://windows.php.net/downloads/releases/$file",
        "https://windows.php.net/downloads/releases/archives/$file"
    )
}

# First of the candidate URLs that exists, or $null.
function Resolve-PhpZipUrl([string]$version) {
    foreach ($url in Get-PhpZipUrls $version) {
        try {
            $req = [System.Net.WebRequest]::Create($url)
            $req.Method = 'HEAD'
            $req.Timeout = 10000
            $res = $req.GetResponse()
            $res.Close()
            return $url
        } catch { }
    }
    return $null
}

# Every x64 NTS PHP build for Windows at or above $min, newest first.
function Get-PhpVersionList([string]$min) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $found = @{}
    foreach ($page in 'https://windows.php.net/downloads/releases/', 'https://windows.php.net/downloads/releases/archives/') {
        try {
            $html = (Invoke-WebRequest -Uri $page -UseBasicParsing -TimeoutSec 15).Content
            foreach ($m in [regex]::Matches($html, 'php-(\d+\.\d+\.\d+)-nts-Win32-v[cs]\d+-x64\.zip')) { $found[$m.Groups[1].Value] = $true }
        } catch { }
    }
    @($found.Keys | Where-Object { [version]$_ -ge [version]$min } | Sort-Object { [version]$_ } -Descending)
}
