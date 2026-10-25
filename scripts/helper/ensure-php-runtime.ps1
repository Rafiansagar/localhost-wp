param([string]$Base = "")

$ErrorActionPreference = "Stop"
$Base = if ([string]::IsNullOrWhiteSpace($Base)) { Split-Path -Parent $PSScriptRoot } else { $Base }
$phpDir = Join-Path $Base "php"

if (!(Test-Path (Join-Path $phpDir "php.exe"))) {
    throw "PHP directory not found at $phpDir"
}

# The Visual C++ runtime if it is installed, else the copy Edge ships. Edge keeps it
# in a folder named after its own version, so look the folders up instead of naming one.
$edgeRoot = Join-Path ${env:ProgramFiles(x86)} "Microsoft"
$sources = @(Join-Path $env:WINDIR "System32")
$sources += @(
    "Edge\Application\*", "EdgeCore\*", "EdgeWebView\Application\*"
) | ForEach-Object {
    Get-ChildItem -Path (Join-Path $edgeRoot $_) -Directory -ErrorAction SilentlyContinue
} | Sort-Object LastWriteTime -Descending | ForEach-Object { $_.FullName }

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
