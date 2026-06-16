param([string]$Base = "")

$Base = if ([string]::IsNullOrWhiteSpace($Base)) { Split-Path -Parent $PSScriptRoot } else { $Base }
$Base = $Base.TrimEnd('\').TrimEnd('/')

$mysqldump  = "$Base\mysql\bin\mysqldump.exe"
$mysqladmin = "$Base\mysql\bin\mysqladmin.exe"
$sitesDir   = "$Base\sites"
$logFile    = "$Base\logs\backup.log"
$timestamp  = Get-Date -Format "yyyy-MM-dd-HH-mm"

function Log($msg) {
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $msg"
    Write-Host $line
    Add-Content $logFile $line -ErrorAction SilentlyContinue
}

if (!(Test-Path $mysqldump)) {
    Log "[!] mysqldump.exe not found. Skipping backup."
    exit 1
}

& $mysqladmin --protocol=TCP --host=127.0.0.1 --port=3307 -u root ping --silent 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) {
    Log "[!] MySQL not responding. Skipping backup."
    exit 1
}

if (!(Test-Path $sitesDir)) {
    Log "[=] No sites directory. Nothing to back up."
    exit 0
}

$sites = Get-ChildItem $sitesDir -Directory -ErrorAction SilentlyContinue
if (!$sites -or $sites.Count -eq 0) {
    Log "[=] No sites found. Nothing to back up."
    exit 0
}

$allOk = $true

foreach ($site in $sites) {
    $siteName      = $site.Name

    if (!(Test-Path "$sitesDir\$siteName\public\wp-config.php")) {
        Log "[=] Skipping '$siteName' (no WordPress database)."
        continue
    }

    $siteBackupDir = "$sitesDir\$siteName\sql"
    $backupFile    = "$siteBackupDir\backup-$timestamp.sql"

    New-Item -ItemType Directory -Force -Path $siteBackupDir | Out-Null

    Log "[>] Backing up: $siteName..."

    & $mysqldump --protocol=TCP --host=127.0.0.1 --port=3307 -u root --single-transaction --routines --triggers --result-file="$backupFile" --databases $siteName 2>$null

    if ($LASTEXITCODE -ne 0) {
        Log "[!] mysqldump failed for '$siteName' (exit $LASTEXITCODE)."
        Remove-Item $backupFile -Force -ErrorAction SilentlyContinue
        $allOk = $false
        continue
    }

    if (!(Test-Path $backupFile)) {
        Log "[!] Backup file not created for '$siteName'."
        $allOk = $false
        continue
    }

    $fileSize = (Get-Item $backupFile).Length
    if ($fileSize -lt 512) {
        Log "[!] Backup for '$siteName' is too small ($fileSize bytes) - likely corrupt. Removing."
        Remove-Item $backupFile -Force
        $allOk = $false
        continue
    }

    $header = Get-Content $backupFile -TotalCount 5 -ErrorAction SilentlyContinue | Out-String
    if ($header -notmatch 'MySQL dump') {
        Log "[!] Backup for '$siteName' is not a valid MySQL dump. Removing."
        Remove-Item $backupFile -Force
        $allOk = $false
        continue
    }

    $kb = [math]::Round($fileSize / 1KB, 1)
    Log "[+] $siteName backed up - backup-$timestamp.sql ($kb KB)"

    $existing = Get-ChildItem $siteBackupDir -Filter "backup-*.sql" |
                Sort-Object LastWriteTime -Descending
    if ($existing.Count -gt 2) {
        foreach ($old in ($existing | Select-Object -Skip 2)) {
            Remove-Item $old.FullName -Force -ErrorAction SilentlyContinue
            Log "[~] Removed old backup: $($old.Name)"
        }
    }
}

if ($allOk) {
    Log "[OK] All backups completed."
    exit 0
} else {
    Log "[WARN] One or more backups failed. Check $logFile"
    exit 1
}
