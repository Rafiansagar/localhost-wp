# ============================================================================
#  get-electron.ps1  -  portable Electron for the Control Panel window
#  Unzips the official Windows build into <stack>\electron\ and turns it into
#  this stack's own app. Nothing is installed:
#    electron\localhost-wp.exe     Electron, renamed; opens the Control Panel
#                                  with no arguments (pin it to the taskbar)
#    electron\resources\app\       tiny loader for dashboard\electron\main.js
#    electron\localhost-wp.ico     app icon (shortcut and taskbar pin)
#    localhost-wp.lnk              shortcut in the stack folder, with that icon
#
#  Called at the end of setup.ps1, and by control-panel.bat (-Console) when
#  electron\ is missing. Run it alone to add Electron to a stack that is
#  already set up, or to recreate the shortcut after moving the stack:
#    powershell -ExecutionPolicy Bypass -File scripts\helper\get-electron.ps1
#  Changing electron.version in versions.json and running it again upgrades.
# ============================================================================
param([string]$Base = "", [switch]$Console)

$Base = if ([string]::IsNullOrWhiteSpace($Base)) { Split-Path -Parent (Split-Path -Parent $PSScriptRoot) } else { $Base }
$Base = $Base.TrimEnd('\').TrimEnd('/')
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

. (Join-Path $PSScriptRoot 'download.ps1')
. (Join-Path $PSScriptRoot 'versions.ps1')
$script:InlineProgress = [bool]$Console

$V = Get-StackVersions $Base
if (-not $V.electron) { Write-Host "[=] versions.json has no electron entry - skipping Electron."; return }

$ver     = $V.electron.version
$dir     = "$Base\electron"
$exe     = "$dir\localhost-wp.exe"
$stock   = "$dir\electron.exe"          # name inside the official zip
$ico     = "$dir\localhost-wp.ico"
$lnk     = "$Base\localhost-wp.lnk"
$zipName = Expand-VersionUrl $V.electron.file $ver
$zip     = "$Base\_electron.zip"
$tmp     = "$Base\_electron_tmp"

# Electron's files are locked while its window is open (setup may run inside it).
function Test-ElectronRunning {
    $root = "$dir\"
    [bool](Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase) })
}

function Write-Utf8([string]$path, [string]$text) {
    [System.IO.File]::WriteAllText($path, $text, (New-Object System.Text.UTF8Encoding($false)))
}

# .ico with PNG-compressed frames (Windows Vista+), resized from icon-512.png.
function Write-Ico([string]$src, [string]$dest) {
    Add-Type -AssemblyName System.Drawing
    $img = [System.Drawing.Image]::FromFile($src)
    $frames = @()
    try {
        foreach ($s in 16, 32, 48, 256) {
            $bmp = New-Object System.Drawing.Bitmap($s, $s)
            $g = [System.Drawing.Graphics]::FromImage($bmp)
            $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $g.DrawImage($img, 0, 0, $s, $s)
            $g.Dispose()
            $ms = New-Object System.IO.MemoryStream
            $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
            $bmp.Dispose()
            $frames += , @{ size = $s; bytes = $ms.ToArray() }
        }
    } finally { $img.Dispose() }

    $out = New-Object System.IO.MemoryStream
    $w = New-Object System.IO.BinaryWriter($out)
    $w.Write([uint16]0); $w.Write([uint16]1); $w.Write([uint16]$frames.Count)
    $offset = 6 + 16 * $frames.Count
    foreach ($f in $frames) {
        $px = if ($f.size -ge 256) { 0 } else { $f.size }   # 0 means 256
        $w.Write([byte]$px); $w.Write([byte]$px); $w.Write([byte]0); $w.Write([byte]0)
        $w.Write([uint16]1); $w.Write([uint16]32)
        $w.Write([uint32]$f.bytes.Length); $w.Write([uint32]$offset)
        $offset += $f.bytes.Length
    }
    foreach ($f in $frames) { $w.Write($f.bytes) }
    $w.Flush()
    [System.IO.File]::WriteAllBytes($dest, $out.ToArray())
    $w.Dispose()
}

# Renamed exe, app loader, icon and shortcut. Safe to repeat.
function Install-Shell {
    if (Test-Path $stock) {
        if (Test-Path $exe) { Remove-Item -LiteralPath $stock -Force -ErrorAction SilentlyContinue }
        elseif (Test-ElectronRunning) {
            Write-Host "[!] Close the Control Panel window (tray icon > Quit), then run control-panel.bat again to finish."
            return
        }
        else { Rename-Item -LiteralPath $stock -NewName 'localhost-wp.exe' }
    }
    if (-not (Test-Path $exe)) { Fail "localhost-wp.exe missing from electron\ - delete the electron folder and run control-panel.bat." }

    # Electron runs resources\app on its own; the real code stays in dashboard\electron.
    $app = "$dir\resources\app"
    New-Item -ItemType Directory -Force -Path $app | Out-Null
    Write-Utf8 "$app\package.json" "{`n  `"name`": `"localhost-wp`",`n  `"productName`": `"localhost-wp`",`n  `"private`": true,`n  `"main`": `"index.js`"`n}`n"
    Write-Utf8 "$app\index.js" ("// Generated by scripts\helper\get-electron.ps1. The app is dashboard\electron\main.js.`n" +
        "require(require('path').join(__dirname, '..', '..', '..', 'dashboard', 'electron', 'main.js'));`n")

    $png = "$Base\dashboard\icons\icon-512.png"
    if (Test-Path $png) {
        try { Write-Ico $png $ico } catch { Write-Host "[!] Could not build the app icon: $($_.Exception.Message)" }
    }

    # Absolute paths: run this script again after moving the stack folder.
    try {
        $sc = (New-Object -ComObject WScript.Shell).CreateShortcut($lnk)
        $sc.TargetPath       = $exe
        $sc.WorkingDirectory = $dir
        $sc.Description      = "localhost-wp Control Panel - $Base"
        if (Test-Path $ico) { $sc.IconLocation = "$ico,0" }
        $sc.Save()
    } catch { Write-Host "[!] Could not create localhost-wp.lnk: $($_.Exception.Message)" }
    OK "localhost-wp.exe ready - open it, the localhost-wp shortcut, or a taskbar pin."
}

# The zip ships a "version" file holding e.g. "45.2.3".
$have = if (Test-Path "$dir\version") { "$(Get-Content -LiteralPath "$dir\version" -TotalCount 1)".Trim() } else { '' }
if (((Test-Path $exe) -or (Test-Path $stock)) -and $have -eq $ver) {
    Skip "Electron $ver"
    Install-Shell
    return
}

if (Test-ElectronRunning) {
    Write-Host "[!] Electron $have is in use by the Control Panel window, so it cannot be replaced by $ver now."
    Write-Host "    Quit the window from its tray icon, then run scripts\helper\get-electron.ps1."
    return
}

Download (Expand-VersionUrl $V.electron.url $ver) $zip "Electron $ver"

# Check the zip against the SHA-256 list published with the release.
Step "Verifying Electron $ver..."
try {
    $sums = (Invoke-WebRequest -Uri (Expand-VersionUrl $V.electron.sums $ver) -UseBasicParsing -TimeoutSec 30).Content
    if ($sums -is [byte[]]) { $sums = [System.Text.Encoding]::UTF8.GetString($sums) }
} catch {
    Remove-Item $zip -Force -ErrorAction SilentlyContinue
    Fail "Could not fetch the Electron checksums: $_"
}
$m = [regex]::Match($sums, "(?im)^([0-9a-f]{64})\s+\*?$([regex]::Escape($zipName))\s*$")
if (-not $m.Success) { Remove-Item $zip -Force; Fail "No checksum listed for $zipName." }
$actual = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash
if ($actual -ne $m.Groups[1].Value) { Remove-Item $zip -Force; Fail "Electron download is corrupt (checksum mismatch) - run setup again." }
OK "Checksum matches."

Step "Extracting Electron..."
Extract $zip $tmp
# Keep the window's own profile (userdata) across upgrades.
if (Test-Path $dir) { Get-ChildItem -LiteralPath $dir -Force | Where-Object { $_.Name -ne 'userdata' } | Remove-Item -Recurse -Force }
New-Item -ItemType Directory -Force -Path $dir | Out-Null
Copy-Item "$tmp\*" "$dir\" -Recurse -Force
Remove-Item $tmp, $zip -Recurse -Force
OK "Electron $ver extracted."
Install-Shell
