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
