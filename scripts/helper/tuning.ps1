# ============================================================================
#  tuning.ps1  -  the Stack page's "PHP & MySQL" settings
#  Dot-sourced by start-php.ps1, cp-stack.ps1 and the dashboard server.
#
#  config\php-tuning.json holds only what someone changed on the Stack page.
#  Nothing in it means the stack runs exactly as setup left it: php.ini and
#  my.ini are never edited for these.
#    PHP    the changed values go into config\php-ini\localhost-wp.ini, which
#           PHP reads after php.ini (PHP_INI_SCAN_DIR, set by start-php.ps1)
#    MySQL  --innodb-buffer-pool-size on mysqld's command line, and live with
#           SET GLOBAL while it runs
#    Nginx  client_max_body_size in nginx.conf follows the upload size
# ============================================================================

# Allowed values per setting. Anything else is refused, so a typo can never
# keep PHP or MySQL from starting.
$script:TuningSpec = [ordered]@{
    opcache       = @($true, $false)
    opcacheMemory = @(64, 128, 256, 512, 1024)                 # MB
    opcacheFiles  = @(10000, 20000, 65000, 130000)
    workers       = @(2, 4, 6, 8, 12, 16)
    memoryLimit   = @('128M', '256M', '512M', '1G', '-1')
    uploadMax     = @('8M', '32M', '64M', '128M', '256M', '512M', '1G')
    maxExecution  = @(30, 60, 120, 300, 0)                     # seconds, 0 = no limit; Nginx waits 300 for WordPress
    mysqlBuffer   = @(128, 256, 512, 1024, 2048)               # MB
}
$script:TuningPhpKeys = @('opcache', 'opcacheMemory', 'opcacheFiles', 'workers', 'memoryLimit', 'uploadMax', 'maxExecution')
$script:TuningDefaultWorkers = 4          # start-php.ps1's own number
$script:TuningDefaultBody    = '64M'      # setup's client_max_body_size

function Get-TuningFile([string]$Base) { Join-Path $Base 'config\php-tuning.json' }
function Get-TuningIniDir([string]$Base) { Join-Path $Base 'config\php-ini' }

# Changed settings only: @{ workers = 8; ... }. Unknown keys and values outside
# the allowed lists are dropped.
function Get-Tuning([string]$Base) {
    $out = [ordered]@{}
    $f = Get-TuningFile $Base
    if (-not (Test-Path -LiteralPath $f)) { return $out }
    try { $j = Get-Content -LiteralPath $f -Raw | ConvertFrom-Json } catch { return $out }
    if (-not $j) { return $out }
    foreach ($p in $j.PSObject.Properties) {
        $v = Test-TuningValue $p.Name $p.Value
        if ($null -ne $v) { $out[$p.Name] = $v }
    }
    return $out
}

# The value in its proper type when allowed, else $null.
function Test-TuningValue([string]$key, $value) {
    if (-not $script:TuningSpec.Contains($key) -or $null -eq $value) { return $null }
    foreach ($ok in $script:TuningSpec[$key]) {
        if ($ok -is [bool]) { if ($value -is [bool] -and $value -eq $ok) { return $ok } }
        elseif ("$value" -eq "$ok") { return $ok }
    }
    return $null
}

# Saves one setting; $null removes it (back to the stack's own value).
function Set-TuningValue([string]$Base, [string]$key, $value) {
    $t = Get-Tuning $Base
    if ($null -eq $value) { $t.Remove($key) } else { $t[$key] = $value }
    $f = Get-TuningFile $Base
    if (-not $t.Count) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue; return }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $f) | Out-Null
    [IO.File]::WriteAllText($f, (ConvertTo-Json -InputObject $t), (New-Object Text.UTF8Encoding $false))
}

# Writes config\php-ini\localhost-wp.ini from the changed PHP settings, or
# removes it when there are none. Returns the folder for PHP_INI_SCAN_DIR, or $null.
function Write-TuningIni([string]$Base) {
    $t   = Get-Tuning $Base
    $dir = Get-TuningIniDir $Base
    $file = Join-Path $dir 'localhost-wp.ini'
    $lines = @()
    if ($t.Contains('opcache')) {
        if ($t.opcache) {
            # Loaded here only when php.ini doesn't load it already (loading it twice warns on every request).
            $ini = Join-Path $Base 'php\php.ini'
            $loaded = (Test-Path $ini) -and (Select-String -LiteralPath $ini -Pattern '^\s*zend_extension\s*=\s*"?(php_)?opcache(\.dll)?"?\s*$' -Quiet)
            if (-not $loaded) { $lines += 'zend_extension=opcache' }
            $lines += 'opcache.enable=1'
            # Every request checks whether a file changed, so code edits show at once.
            $lines += 'opcache.validate_timestamps=1', 'opcache.revalidate_freq=0'
        } else {
            $lines += 'opcache.enable=0'
        }
    }
    if ($t.Contains('opcacheMemory')) { $lines += "opcache.memory_consumption=$($t.opcacheMemory)" }
    if ($t.Contains('opcacheFiles'))  { $lines += "opcache.max_accelerated_files=$($t.opcacheFiles)" }
    if ($t.Contains('memoryLimit'))   { $lines += "memory_limit=$($t.memoryLimit)" }
    if ($t.Contains('uploadMax'))     { $lines += "upload_max_filesize=$($t.uploadMax)", "post_max_size=$($t.uploadMax)" }
    if ($t.Contains('maxExecution'))  { $lines += "max_execution_time=$($t.maxExecution)" }

    if (-not $lines.Count) {
        Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
        return $null
    }
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $text = "; Written by localhost-wp from config\php-tuning.json (the Stack page's PHP & MySQL settings).`r`n; PHP reads it after php.ini. Change these on the Stack page, not here.`r`n" + ($lines -join "`r`n") + "`r`n"
    [IO.File]::WriteAllText($file, $text, (New-Object Text.UTF8Encoding $false))
    return $dir
}

# Nginx: the upload limit follows the upload setting, and "error_log off;"
# (which Nginx reads as a file named "off") goes to real log files.
# $ResetBody puts setup's 64M back after the upload setting is reset.
# Returns $true when a file changed (a running Nginx then needs a reload).
function Update-NginxTuning([string]$Base, [switch]$ResetBody) {
    $changed = $false
    $t = Get-Tuning $Base
    $enc = New-Object Text.UTF8Encoding $false
    $main = Join-Path $Base 'nginx\conf\nginx.conf'
    if (Test-Path $main) {
        $s = [IO.File]::ReadAllText($main)
        $n = [regex]::Replace($s, '(?m)^(\s*)error_log\s+off\s*;', '${1}error_log  logs/error.log;')
        $body = if ($t.Contains('uploadMax')) { $t.uploadMax } elseif ($ResetBody) { $script:TuningDefaultBody } else { $null }
        if ($body) { $n = [regex]::Replace($n, '(?m)^(\s*)client_max_body_size\s+[^;]+;', "`${1}client_max_body_size $body;") }
        if ($n -ne $s) { [IO.File]::WriteAllText($main, $n, $enc); $changed = $true }
    }
    $pma = Join-Path $Base 'config\nginx\phpmyadmin.conf'
    if (Test-Path $pma) {
        $s = [IO.File]::ReadAllText($pma)
        $log = "$($Base.Replace('\', '/'))/logs/nginx/phpmyadmin-error.log"
        $n = [regex]::Replace($s, '(?m)^(\s*)error_log\s+off\s*;', "`${1}error_log   `"$log`";")
        if ($n -ne $s) {
            New-Item -ItemType Directory -Force -Path (Join-Path $Base 'logs\nginx') | Out-Null
            [IO.File]::WriteAllText($pma, $n, $enc); $changed = $true
        }
    }
    return $changed
}

# For the Activity log: "512 MB", "no limit", "8".
function Format-TuningValue([string]$key, $v) {
    if ($key -eq 'opcache') { if ($v) { return 'on' } else { return 'off' } }
    if ($key -in 'opcacheMemory', 'mysqlBuffer') { if ([int]$v -ge 1024) { return "$([int]$v / 1024) GB" } else { return "$v MB" } }
    if ($key -eq 'opcacheFiles') { return ('{0:N0} files' -f [int]$v) }
    if ($key -in 'memoryLimit', 'uploadMax') { if ("$v" -eq '-1') { return 'no limit' } else { return ("$v" -replace '(?i)G$', ' GB' -replace '(?i)M$', ' MB') } }
    if ($key -eq 'maxExecution') { if ([int]$v -eq 0) { return 'no limit' } else { return "$v seconds" } }
    return "$v"
}

# "512M" / "1G" / "134217728" -> MB
function ConvertTo-TuningMB([string]$v) {
    $m = [regex]::Match("$v".Trim(), '^(\d+)\s*([KMG]?)', 'IgnoreCase')
    if (-not $m.Success) { return $null }
    $n = [double]$m.Groups[1].Value
    switch ($m.Groups[2].Value.ToUpper()) { 'G' { return [int]($n * 1024) } 'M' { return [int]$n } 'K' { return [int]($n / 1024) } default { return [int]($n / 1MB) } }
}

# The stack's own values (php.ini as setup wrote it, my.ini, start-php.ps1),
# shown for every setting nobody changed.
function Get-TuningStock([string]$Base) {
    $stock = [ordered]@{ workers = $script:TuningDefaultWorkers }
    $php = Join-Path $Base 'php\php.exe'
    $ini = Join-Path $Base 'php\php.ini'
    $probe = Join-Path $Base 'scripts\php\ini-values.php'
    if ((Test-Path $php) -and (Test-Path $ini) -and (Test-Path $probe)) {
        try {
            # Without PHP_INI_SCAN_DIR, so this is php.ini alone.
            $psi = New-Object Diagnostics.ProcessStartInfo $php, "-c `"$ini`" -f `"$probe`""
            $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true; $psi.RedirectStandardOutput = $true
            [void]$psi.EnvironmentVariables.Remove('PHP_INI_SCAN_DIR')
            $p = [Diagnostics.Process]::Start($psi)
            $out = $p.StandardOutput.ReadToEnd(); [void]$p.WaitForExit(5000)
            $j = $out | ConvertFrom-Json
            $stock.opcache       = [bool]$j.opcache
            $stock.opcacheMemory = [int]$j.opcacheMemory
            $stock.opcacheFiles  = [int]$j.opcacheFiles
            $stock.memoryLimit   = "$($j.memoryLimit)"
            # The upload that actually gets through: the smallest of PHP's two limits and Nginx's.
            $limits = @("$($j.uploadMax)", "$($j.postMax)")
            $ngx = Join-Path $Base 'nginx\conf\nginx.conf'
            if (Test-Path $ngx) {
                $m = [regex]::Match([IO.File]::ReadAllText($ngx), '(?m)^\s*client_max_body_size\s+([^;\s]+)\s*;')
                if ($m.Success) { $limits += $m.Groups[1].Value }
            }
            $stock.uploadMax = ($limits | Where-Object { ConvertTo-TuningMB $_ } | Sort-Object { ConvertTo-TuningMB $_ } | Select-Object -First 1)
            # The command line forces max_execution_time to 0 whatever php.ini says, so php.ini's own line is read.
            $m = [regex]::Match([IO.File]::ReadAllText($ini), '(?m)^\s*max_execution_time\s*=\s*"?(\d+)')
            $stock.maxExecution  = if ($m.Success) { [int]$m.Groups[1].Value } else { 30 }
        } catch { }
    }
    $my = Join-Path $Base 'mysql\my.ini'
    $stock.mysqlBuffer = 128
    if (Test-Path $my) {
        $m = [regex]::Match([IO.File]::ReadAllText($my), '(?m)^\s*innodb[_-]buffer[_-]pool[_-]size\s*=\s*(\S+)')
        if ($m.Success) { $mb = ConvertTo-TuningMB $m.Groups[1].Value; if ($mb) { $stock.mysqlBuffer = $mb } }
    }
    return $stock
}
