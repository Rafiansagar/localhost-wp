# ============================================================================
#  download.ps1  -  shared by setup.ps1 and get-electron.ps1
#  Progress lines ("[*]", "[+]", "[%] <pct> <label>") are read by the
#  dashboard worker to drive the activity log and progress bar.
# ============================================================================

function Step($msg)  { Write-Host "[*] $msg" -ForegroundColor Cyan }
function OK($msg)    { Write-Host "[+] $msg" -ForegroundColor Green }
function Skip($msg)  { Write-Host "[=] $msg - already exists, skipping." -ForegroundColor DarkGray }
function Fail($msg)  { Write-Host "[!] $msg" -ForegroundColor Red; exit 1 }

# "[%]" lines feed the dashboard's progress bar. Run in a plain console
# ($script:InlineProgress), they redraw one line instead of scrolling.
function Progress($line, [switch]$Last) {
    if (-not $script:InlineProgress) { Write-Host $line; return }
    $text = '    ' + ($line -replace '^\[%\]\s+-?\d+\s+', '')
    [Console]::Write("`r" + $text.PadRight(70))
    if ($Last) { [Console]::WriteLine() }
}

# Streams to "<dest>.part" and renames when done, so a broken download is never
# mistaken for a finished one. Progress line format: "[%] <pct> <label> - <done> / <total> MB"
function Download($url, $dest, $label) {
    if (Test-Path $dest) { Skip $label; return }
    Step "Downloading $label..."
    $part = "$dest.part"
    $resp = $null; $in = $null; $out = $null
    try {
        $req = [System.Net.HttpWebRequest]::Create($url)
        $req.UserAgent = "localhost-wp-setup"
        $resp  = $req.GetResponse()
        $total = $resp.ContentLength
        $in    = $resp.GetResponseStream()
        $out   = [System.IO.File]::Create($part)
        $buf   = New-Object byte[] 262144
        $done  = 0L
        $sw    = [System.Diagnostics.Stopwatch]::StartNew()
        $last  = -1000
        while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) {
            $out.Write($buf, 0, $n)
            $done += $n
            if ($sw.ElapsedMilliseconds - $last -ge 500) {
                $last = $sw.ElapsedMilliseconds
                $mb = "{0:N1}" -f ($done / 1MB)
                if ($total -gt 0) {
                    $pct = [int](100 * $done / $total)
                    Progress ("[%] {0} {1} - {2} / {3:N1} MB ({0}%)" -f $pct, $label, $mb, ($total / 1MB))
                } else {
                    Progress ("[%] -1 {0} - {1} MB" -f $label, $mb)
                }
            }
        }
        $out.Close(); $out = $null
        Progress ("[%] 100 {0} - {1:N1} MB" -f $label, ($done / 1MB)) -Last
        Move-Item -LiteralPath $part -Destination $dest -Force
    }
    catch {
        if ($out) { $out.Close() }
        Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue
        Fail "Failed to download $label`: $_"
    }
    finally {
        if ($in)   { $in.Close() }
        if ($resp) { $resp.Close() }
    }
    OK "$label downloaded."
}

function Extract($zip, $dest) {
    Expand-Archive -Path $zip -DestinationPath $dest -Force
}
