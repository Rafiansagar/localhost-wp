param([string]$Base = "")

# ============================================================================
#  ensure-mail.ps1  -  mail catcher (Mailpit)
#  Points PHP's mail() at 127.0.0.1:1025 and puts Mailpit in mailpit\.
#  Run by setup, before every Start Stack and by the dashboard's on/off switch;
#  prints nothing when all is in place.
#  Never fatal: without Mailpit, mail is simply not caught.
# ============================================================================

$Base = if ([string]::IsNullOrWhiteSpace($Base)) { Split-Path -Parent (Split-Path -Parent $PSScriptRoot) } else { $Base }
$Base = $Base.TrimEnd('\').TrimEnd('/')
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

. (Join-Path $PSScriptRoot 'download.ps1')
. (Join-Path $PSScriptRoot 'versions.ps1')

# On unless config\mail-catcher.txt says "off" (the dashboard's switch writes it).
$stateFile = Join-Path $Base 'config\mail-catcher.txt'
$on = -not ((Test-Path $stateFile) -and "$(Get-Content -LiteralPath $stateFile -TotalCount 1)".Trim() -eq 'off')

# ---- php.ini -----------------------------------------------------------------
# On:  SMTP to the catcher.
# Off: PHP's own defaults back (SMTP = localhost, smtp_port = 25), so sites and
#      their SMTP plugins send mail exactly as they normally would.
# Either way scripts\php\localhost-wp.php is loaded before every request: it
# loads the error catcher and, while mail is on, mail-catcher.php (each reads
# its own config\<name>.txt switch on every request).
# A php.ini edit counts from the next PHP start (Start Stack runs this first).
$ini = Join-Path $Base 'php\php.ini'
if (Test-Path $ini) {
    $prepend = "$($Base.Replace('\', '/'))/scripts/php/localhost-wp.php"
    $old = @(Get-Content -LiteralPath $ini)
    $new = foreach ($line in $old) {
        if ($line -match '^\s*SMTP\s*=') { if ($on) { 'SMTP = 127.0.0.1' } else { 'SMTP = localhost' } }
        elseif ($line -match '^\s*smtp_port\s*=') { if ($on) { 'smtp_port = 1025' } else { 'smtp_port = 25' } }
        elseif ($line -match '^\s*auto_prepend_file\s*=\s*(.*)$') {
            # Only an empty value, or ours (moved stack folder, or an earlier
            # name: mail-catcher.php, mail-from.php); never someone else's file.
            $cur = $Matches[1].Trim().Trim('"')
            $ours = $cur -like '*/scripts/php/localhost-wp.php' -or $cur -like '*/scripts/php/mail-catcher.php' -or $cur -like '*/scripts/php/mail-from.php'
            if (-not $cur -or $ours) { "auto_prepend_file = `"$prepend`"" } else { $line }
        }
        else { $line }
    }
    if (($new -join "`n") -ne ($old -join "`n")) {
        Set-Content -LiteralPath $ini -Value $new
        if ($on) { Write-Host "[+] php.ini updated: catchers load before every request, mail goes to 127.0.0.1:1025." }
        else     { Write-Host "[+] php.ini updated: catchers load before every request, mail settings are PHP's defaults (mail catcher off)." }
    }
}

# Off: Mailpit is not needed, so nothing is downloaded.
if (-not $on) { return }

# ---- Mailpit itself ----------------------------------------------------------
$V = Get-StackVersions $Base
if (-not $V.mailpit) { return }
$ver  = $V.mailpit.version
$dir  = Join-Path $Base 'mailpit'
$exe  = Join-Path $dir 'mailpit.exe'
$mark = Join-Path $dir 'version.txt'
$have = if (Test-Path $mark) { "$(Get-Content -LiteralPath $mark -TotalCount 1)".Trim() } else { '' }
if ((Test-Path $exe) -and $have -eq $ver) { return }

# A running Mailpit holds its exe; the new version is put in place at a later start.
$running = Get-Process -Name mailpit -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path -like "$dir\*" }
if ($running) { return }

$zip = Join-Path $Base '_mailpit.zip'
$tmp = Join-Path $Base '_mailpit_tmp'
Download (Expand-VersionUrl $V.mailpit.url $ver) $zip "Mailpit $ver (mail catcher)"
Extract $zip $tmp
New-Item -ItemType Directory -Path $dir -Force | Out-Null
Copy-Item (Join-Path $tmp 'mailpit.exe') $exe -Force
Set-Content -LiteralPath $mark -Value $ver
Remove-Item $zip, $tmp -Recurse -Force -ErrorAction SilentlyContinue
OK "Mailpit $ver installed."
