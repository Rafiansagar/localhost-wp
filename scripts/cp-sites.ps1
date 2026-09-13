# ============================================================================
#  cp-sites.ps1  -  per-site operations for the Control Panel
#  Dot-sourced by control-panel.ps1.
#  Reuses scripts/create-nginx-conf.ps1.
# ============================================================================

# ---- REAL: per-site DB backup (mysqldump; does not modify data) ------------
function Invoke-Backup([string]$name) {
    if (-not (Test-Proc 'mysqld')) { Write-Log "Backup '$name' FAILED - MySQL is not running." 'err'; return }
    if (-not (Test-Path $script:MysqldumpExe)) { Write-Log "Backup '$name' FAILED - mysqldump.exe not found." 'err'; return }
    $dbs = Get-DbList
    if ($dbs -eq $null -or ($dbs -notcontains $name)) { Write-Log "Backup '$name' FAILED - no database found." 'err'; return }

    $sqlDir = Join-Path $script:SitesDir "$name\sql"
    New-Item -ItemType Directory -Force -Path $sqlDir | Out-Null
    $ts   = (Get-Date).ToString('yyyy-MM-dd-HH-mm')
    $file = Join-Path $sqlDir "backup-$ts.sql"
    Write-Log "Backing up '$name'..." ; Flush-UI
    try {
        & $script:MysqldumpExe --protocol=TCP --host=127.0.0.1 --port=3307 -u root --single-transaction --routines --triggers --result-file="$file" --databases $name 2>$null
        if ($LASTEXITCODE -eq 0 -and (Test-Path $file) -and (Get-Item $file).Length -gt 512) {
            $kb = [math]::Round((Get-Item $file).Length / 1KB, 1)
            Write-Log "Backup OK - sites\$name\sql\backup-$ts.sql ($kb KB)" 'ok'
            Get-ChildItem $sqlDir -Filter 'backup-*.sql' | Sort-Object LastWriteTime -Descending |
                Select-Object -Skip 2 | Remove-Item -Force -ErrorAction SilentlyContinue
        } else {
            Write-Log "Backup '$name' FAILED (mysqldump exit $LASTEXITCODE)." 'err'
            if (Test-Path $file) { Remove-Item $file -Force -ErrorAction SilentlyContinue }
        }
    } catch { Write-Log "Backup '$name' FAILED - $($_.Exception.Message)" 'err' }
}

# ---- REAL: delete a site (files + database + vhost) -------------------------
#  (re-creates delete-site.bat in PowerShell - no cmd window)
function Invoke-DeleteSite([string]$name) {
    Write-Log "Deleting '$name'..." 'warn' ; Flush-UI

    # 1) drop database (backticks needed for names with hyphens)
    if (Test-Proc 'mysqld') {
        $sql = 'DROP DATABASE IF EXISTS `' + $name + '`;'
        & $script:MysqlExe --protocol=TCP --host=127.0.0.1 --port=3307 -u root -e $sql 2>$null
        if ($LASTEXITCODE -eq 0) { Write-Log "  Database '$name' dropped." } else { Write-Log "  Could not drop database '$name'." 'warn' }
    } else {
        Write-Log '  MySQL not running - database NOT dropped.' 'warn'
    }

    # 2) delete files
    $siteDir = Join-Path $script:SitesDir $name
    if (Test-Path $siteDir) {
        try { Remove-Item -LiteralPath $siteDir -Recurse -Force; Write-Log '  Files deleted.' }
        catch { Write-Log "  Failed to delete files - $($_.Exception.Message)" 'err' }
    } else { Write-Log '  No files found.' }

    # 3) remove vhost conf (enabled or disabled)
    $confA = Join-Path $script:ConfDir "$name.conf"
    $confB = Join-Path $script:DisabledDir "$name.conf"
    foreach ($c in @($confA, $confB)) {
        if (Test-Path $c) { Remove-Item -LiteralPath $c -Force -ErrorAction SilentlyContinue; Write-Log "  Removed $c" }
    }

    # 4) reload nginx so the vhost stops being served
    if (Test-Proc 'nginx') { Invoke-NginxReload | Out-Null }

    Write-Log "Site '$name' deleted." 'ok'
}

# ---- REAL: create a new WordPress site -------------------------------------
#  (re-creates new-site.bat orchestration; delegates vhost to
#   scripts/create-nginx-conf.ps1)
#  Sites run on 9001+ (9000 is PHP FastCGI). Every port already in a vhost is
#  skipped, as is anything currently listening.
function Get-NextPort {
    $used = @(80, 3307, 8080, 9000)
    foreach ($dir in @($script:ConfDir, $script:DisabledDir)) {
        if (-not (Test-Path $dir)) { continue }
        Get-ChildItem -LiteralPath $dir -Filter *.conf -File -ErrorAction SilentlyContinue | ForEach-Object {
            $txt = Get-Content -Raw -LiteralPath $_.FullName
            foreach ($m in [regex]::Matches($txt, 'listen\s+(\d+)')) { $used += [int]$m.Groups[1].Value }
        }
    }

    $port = 9000
    if (Test-Path $script:PortsFile) {
        $last = (Get-Content $script:PortsFile | Select-Object -Last 1).Trim()
        if ($last -match '^\d+$' -and [int]$last -gt $port) { $port = [int]$last }
    }
    $maxUsed = ($used | Measure-Object -Maximum).Maximum
    if ($maxUsed -gt $port) { $port = $maxUsed }

    $port++
    while (($used -contains $port) -or (Test-Port $port)) { $port++ }
    return $port
}

function Invoke-NewSite([string]$name) {
    if ($name -notmatch '^[a-zA-Z0-9_-]+$') { Write-Log "New site FAILED - invalid name (use letters, numbers, - or _)." 'err'; return }
    $siteDir   = Join-Path $script:SitesDir $name
    $publicDir = Join-Path $siteDir 'public'
    if (Test-Path $publicDir) { Write-Log "New site FAILED - '$name' already exists." 'err'; return }
    if (-not (Test-Proc 'mysqld')) { Write-Log 'New site FAILED - MySQL is not running (start the stack first).' 'err'; return }

    Write-Log "Creating site '$name'..." ; Flush-UI

    # 1) database
    $sql = 'CREATE DATABASE IF NOT EXISTS `' + $name + '` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;'
    & $script:MysqlExe --protocol=TCP --host=127.0.0.1 --port=3307 -u root -e $sql 2>$null
    if ($LASTEXITCODE -ne 0) { Write-Log 'New site FAILED - could not create database.' 'err'; return }
    Write-Log '  Database created.' ; Flush-UI

    $port = Get-NextPort

    # 2) download + extract WordPress (background jobs keep the GUI responsive)
    try {
        New-Item -ItemType Directory -Force -Path $publicDir | Out-Null
        Write-Log '  Downloading WordPress (this can take a minute)...' ; Flush-UI
        $zip = Join-Path $siteDir 'wp.zip'
        $job = Start-Job -ScriptBlock { param($u,$o) Invoke-WebRequest -Uri $u -OutFile $o -UseBasicParsing } -ArgumentList 'https://wordpress.org/latest.zip', $zip
        while ($job.State -eq 'Running') { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 100 }
        if ($job.State -eq 'Failed') { Remove-Job $job; throw 'WordPress download failed.' }
        Remove-Job $job

        Write-Log '  Extracting...' ; Flush-UI
        $tmp = Join-Path $siteDir 'wp_tmp'
        $job = Start-Job -ScriptBlock { param($z,$d) Expand-Archive -Path $z -DestinationPath $d -Force } -ArgumentList $zip, $tmp
        while ($job.State -eq 'Running') { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 100 }
        if ($job.State -eq 'Failed') { Remove-Job $job; throw 'WordPress extract failed.' }
        Remove-Job $job

        Copy-Item -Path (Join-Path $tmp 'wordpress\*') -Destination $publicDir -Recurse -Force
        Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item $zip -Force -ErrorAction SilentlyContinue
        Write-Log '  WordPress installed.' ; Flush-UI
    } catch {
        Write-Log "New site FAILED during WordPress download/extract - $($_.Exception.Message)" 'err'
        return
    }

    # 3) wp-config.php
    try {
        $sample = Join-Path $publicDir 'wp-config-sample.php'
        $cfg    = Join-Path $publicDir 'wp-config.php'
        (Get-Content $sample) `
            -replace 'database_name_here', $name `
            -replace 'username_here', 'root' `
            -replace 'password_here', '' `
            -replace "define\( 'DB_HOST', 'localhost' \)", "define( 'DB_HOST', '127.0.0.1:3307' )" |
            Set-Content $cfg
        Write-Log '  wp-config.php created.' ; Flush-UI
    } catch { Write-Log "New site - wp-config step failed: $($_.Exception.Message)" 'warn' }

    # 4) nginx vhost (REUSE scripts/*.ps1) + ports + reload
    Write-Log '  Creating nginx config...' ; Flush-UI
    Invoke-Helper 'create-nginx-conf.ps1' @{ SiteName = $name; Port = "$port"; Base = $script:BASE } | Out-Null
    Set-Content -LiteralPath $script:PortsFile -Value $port
    if (Test-Proc 'nginx') { Invoke-NginxReload | Out-Null }

    Write-Log "Site '$name' created -> http://localhost:$port" 'ok'
}
