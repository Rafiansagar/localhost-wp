# ============================================================================
#  localhost-wp Control Panel  -  GUI ONLY
#  ----------------------------------------------------------------------------
#  Actions live in dot-sourced modules so they are easy to edit:
#     cp-core.ps1   - utilities + data (log, checks, db/site lists, helpers)
#     cp-stack.ps1  - stack ops (status, nginx reload; start/stop later)
#     cp-sites.ps1  - site ops (backup, delete, new)
#  No cmd windows; heavy steps delegate to your existing scripts/*.ps1.
# ============================================================================

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName Microsoft.VisualBasic
[System.Windows.Forms.Application]::EnableVisualStyles()

# Stack root = parent of this scripts folder (E:\localhost-wp)
$script:BASE        = Split-Path -Parent $PSScriptRoot
$script:ScriptsDir  = Join-Path $script:BASE 'scripts'
$script:HelperDir   = Join-Path $script:BASE 'scripts\helper'
$script:ConfDir     = Join-Path $script:BASE 'config\nginx'
$script:DisabledDir = Join-Path $script:ConfDir 'disabled'
$script:SitesDir    = Join-Path $script:BASE 'sites'
$script:MysqlExe    = Join-Path $script:BASE 'mysql\bin\mysql.exe'
$script:MysqldumpExe= Join-Path $script:BASE 'mysql\bin\mysqldump.exe'
$script:PortsFile   = Join-Path $script:BASE 'config\ports.txt'
$script:sites       = @()

# ---- load action modules ---------------------------------------------------
. (Join-Path $PSScriptRoot 'cp-core.ps1')
. (Join-Path $PSScriptRoot 'cp-stack.ps1')
. (Join-Path $PSScriptRoot 'cp-sites.ps1')

function Test-IsSetup {
    (Test-Path (Join-Path $script:BASE 'nginx\nginx.exe')) -and
    (Test-Path (Join-Path $script:BASE 'mysql\bin\mysqld.exe')) -and
    (Test-Path (Join-Path $script:BASE 'php\php-cgi.exe')) -and
    (Test-Path (Join-Path $script:BASE 'phpmyadmin\index.php')) -and
    (Test-Path (Join-Path $script:BASE 'mysql\my.ini'))
}

# ---- status tag rendering --------------------------------------------------
$clrGreen = [System.Drawing.Color]::FromArgb(28,135,60)
$clrRed   = [System.Drawing.Color]::FromArgb(190,40,40)
$clrAmber = [System.Drawing.Color]::FromArgb(176,120,0)
$clrGray  = [System.Drawing.Color]::Gray

function Set-SrvTag($lbl, $srv) {
    switch ($srv) {
        'Live'     { $lbl.Text = 'Server: Live';     $lbl.ForeColor = $clrGreen }
        'Offline'  { $lbl.Text = 'Server: Offline';  $lbl.ForeColor = $clrAmber }
        'Disabled' { $lbl.Text = 'Server: Disabled'; $lbl.ForeColor = $clrGray  }
        default    { $lbl.Text = 'Server: ?';        $lbl.ForeColor = $clrGray  }
    }
}
function Set-DbTag($lbl, $db) {
    switch ($db) {
        'yes'   { $lbl.Text = 'DB: yes';  $lbl.ForeColor = $clrGreen }
        'no'    { $lbl.Text = 'DB: NONE'; $lbl.ForeColor = $clrRed   }
        default { $lbl.Text = 'DB: ?';    $lbl.ForeColor = $clrGray  }
    }
}
function Set-WpcTag($lbl, $wpc) {
    switch ($wpc) {
        'yes'   { $lbl.Text = 'wp-config: yes'; $lbl.ForeColor = $clrGreen }
        'no'    { $lbl.Text = 'wp-config: NO';  $lbl.ForeColor = $clrRed   }
        default { $lbl.Text = 'wp-config: ?';   $lbl.ForeColor = $clrGray  }
    }
}

# ---- build one card row per site (renders; data from cp-core) ---------------
function Build-SiteRows {
    $flow.SuspendLayout()
    $flow.Controls.Clear()

    $script:sites = Get-Sites
    $dbList  = Get-DbList            # one query for all sites
    $mysqlUp = ($dbList -ne $null)

    foreach ($s in $script:sites) {
        if (-not $s.Enabled) {
            $srv = 'Disabled'
        } elseif ($s.Http -and (Test-Port ([int]$s.Http))) {
            $srv = 'Live'
        } else {
            $srv = 'Offline'
        }

        if (-not $mysqlUp)                 { $db = 'unknown' }
        elseif ($dbList -contains $s.Name) { $db = 'yes' }
        else                               { $db = 'no' }

        $wpcPath = Join-Path $script:SitesDir "$($s.Name)\public\wp-config.php"
        $wpc = if (Test-Path $wpcPath) { 'yes' } else { 'no' }

        $row = New-Object System.Windows.Forms.Panel
        $row.Size = New-Object System.Drawing.Size(900, 58)
        $row.BorderStyle = 'FixedSingle'
        $row.BackColor = [System.Drawing.Color]::White
        $row.Margin = New-Object System.Windows.Forms.Padding(0,0,0,6)

        $port = New-Object System.Windows.Forms.Label
        $port.SetBounds(8, 9, 90, 40)
        $port.Font = New-Object System.Drawing.Font('Consolas', 8)
        $port.ForeColor = [System.Drawing.Color]::FromArgb(70,90,160)
        $port.Text = "PORT  $($s.Http)"
        $row.Controls.Add($port)

        $name = New-Object System.Windows.Forms.Label
        $name.SetBounds(104, 7, 150, 22)
        $name.Font = New-Object System.Drawing.Font('Segoe UI', 11, [System.Drawing.FontStyle]::Bold)
        $name.Text = $s.Name
        $row.Controls.Add($name)

        $path = New-Object System.Windows.Forms.Label
        $path.SetBounds(104, 32, 150, 16)
        $path.Font = New-Object System.Drawing.Font('Segoe UI', 8)
        $path.ForeColor = [System.Drawing.Color]::Gray
        $path.AutoEllipsis = $true
        $path.Text = "sites\$($s.Name)"
        $row.Controls.Add($path)

        $tagFont = New-Object System.Drawing.Font('Segoe UI', 8, [System.Drawing.FontStyle]::Bold)

        $srvL = New-Object System.Windows.Forms.Label
        $srvL.SetBounds(262, 5, 150, 16); $srvL.Font = $tagFont
        Set-SrvTag $srvL $srv
        $row.Controls.Add($srvL)

        $dbL = New-Object System.Windows.Forms.Label
        $dbL.SetBounds(262, 22, 150, 16); $dbL.Font = $tagFont
        Set-DbTag $dbL $db
        $row.Controls.Add($dbL)

        $wpcL = New-Object System.Windows.Forms.Label
        $wpcL.SetBounds(262, 39, 150, 16); $wpcL.Font = $tagFont
        Set-WpcTag $wpcL $wpc
        $row.Controls.Add($wpcL)

        $bSite = New-Object System.Windows.Forms.Button
        $bSite.Text = 'Site'; $bSite.SetBounds(478, 14, 60, 30); $bSite.Tag = $s; $bSite.Anchor = 'Top, Right'
        $bSite.Add_Click({
            $s2 = $this.Tag
            if (-not $s2.Http) { Write-Log "No port found for $($s2.Name)." 'err'; return }
            Open-Url ("http://{0}:{1}" -f [string]$cmbHost.SelectedItem, $s2.Http)
        })
        $row.Controls.Add($bSite)

        $bAdmin = New-Object System.Windows.Forms.Button
        $bAdmin.Text = 'WP Admin'; $bAdmin.SetBounds(544, 14, 84, 30); $bAdmin.Tag = $s; $bAdmin.Anchor = 'Top, Right'
        $bAdmin.Add_Click({
            $s2 = $this.Tag
            if (-not $s2.Http) { Write-Log "No port found for $($s2.Name)." 'err'; return }
            Open-Url ("http://{0}:{1}/wp-admin" -f [string]$cmbHost.SelectedItem, $s2.Http)
        })
        $row.Controls.Add($bAdmin)

        $bBak = New-Object System.Windows.Forms.Button
        $bBak.Text = 'Backup DB'; $bBak.SetBounds(632, 14, 84, 30); $bBak.Tag = $s; $bBak.Anchor = 'Top, Right'
        $bBak.Add_Click({ Invoke-Backup $this.Tag.Name })
        $row.Controls.Add($bBak)

        $bDel = New-Object System.Windows.Forms.Button
        $bDel.Text = 'Delete'; $bDel.SetBounds(720, 14, 66, 30)
        $bDel.ForeColor = [System.Drawing.Color]::FromArgb(176,32,32); $bDel.Tag = $s; $bDel.Anchor = 'Top, Right'
        $bDel.Add_Click({
            $n = $this.Tag.Name
            $typed = [Microsoft.VisualBasic.Interaction]::InputBox(
                "PERMANENTLY delete '$n' (files + database + nginx config).`r`nThis cannot be undone.`r`n`r`nType the site name to confirm:",
                'Delete site', '')
            if ($typed -ne $n) { Write-Log "Delete '$n' cancelled (name did not match)." 'warn'; return }
            Invoke-DeleteSite $n
            Build-SiteRows
        })
        $row.Controls.Add($bDel)

        $bDir = New-Object System.Windows.Forms.Button
        $bDir.Text = 'Open Dir'; $bDir.SetBounds(792, 14, 72, 30); $bDir.Tag = $s; $bDir.Anchor = 'Top, Right'
        $bDir.Add_Click({
            $siteDir = Join-Path $script:SitesDir $this.Tag.Name
            if (Test-Path $siteDir) { Start-Process explorer.exe $siteDir }
            else { Write-Log "Directory not found: $siteDir" 'err' }
        })
        $row.Controls.Add($bDir)

        $flow.Controls.Add($row)
    }
    $flow.ResumeLayout()
    Resize-Rows
}

function Resize-Rows {
    if (-not $flow) { return }
    $w = $flow.ClientSize.Width - 6
    if ($w -lt 900) { $w = 900 }
    foreach ($r in $flow.Controls) { $r.Width = $w }
}

# ============================================================================
#  UI
# ============================================================================
$form = New-Object System.Windows.Forms.Form
$form.Text = 'localhost-wp Control Panel'
$form.Size = New-Object System.Drawing.Size(930, 790)
$form.StartPosition = 'CenterScreen'
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

# --- Stack group ---
$grpStack = New-Object System.Windows.Forms.GroupBox
$grpStack.Text = 'Stack'
$grpStack.SetBounds(12, 8, 890, 110)
$form.Controls.Add($grpStack)

$svcLabels = @{}
$y = 22
foreach ($svc in 'MySQL','PHP','Nginx') {
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.SetBounds(16, $y, 200, 20)
    $lbl.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $grpStack.Controls.Add($lbl)
    $svcLabels[$svc] = $lbl
    $y += 24
}

$btnStart = New-Object System.Windows.Forms.Button
$btnStart.Text = 'Start Stack'; $btnStart.SetBounds(320, 24, 130, 32)
$btnStart.Add_Click({
    $this.Enabled = $false; $btnStop.Enabled = $false
    try { Start-Stack; Build-SiteRows } finally { $this.Enabled = $true; $btnStop.Enabled = $true }
})
$grpStack.Controls.Add($btnStart)

$btnStop = New-Object System.Windows.Forms.Button
$btnStop.Text = 'Stop Stack'; $btnStop.SetBounds(320, 62, 130, 32)
$btnStop.Add_Click({
    $ans = [System.Windows.Forms.MessageBox]::Show(
        "Yes    — backup all databases, then stop stack`nNo     — stop stack without backup`nCancel — do nothing",
        'Stop Stack', [System.Windows.Forms.MessageBoxButtons]::YesNoCancel,
        [System.Windows.Forms.MessageBoxIcon]::Question)
    if ($ans -eq 'Cancel') { Write-Log 'Stop Stack cancelled.' 'warn'; return }
    $this.Enabled = $false; $btnStart.Enabled = $false
    try {
        if ($ans -eq 'Yes') { Stop-Stack } else { Stop-Stack -NoBackup }
        Build-SiteRows
    } finally { $this.Enabled = $true; $btnStart.Enabled = $true }
})
$grpStack.Controls.Add($btnStop)

$btnStatus = New-Object System.Windows.Forms.Button
$btnStatus.Text = 'Refresh status'; $btnStatus.SetBounds(470, 62, 130, 32)
$btnStatus.Add_Click({
    Update-Status
    $procOf = @{ MySQL = 'mysqld'; PHP = 'php-cgi'; Nginx = 'nginx' }
    $running = @(); $stopped = @()
    foreach ($svc in 'MySQL','PHP','Nginx') {
        if (Test-Proc $procOf[$svc]) { $running += $svc } else { $stopped += $svc }
    }
    $runTxt  = if ($running.Count) { $running -join ', ' } else { 'none' }
    $stopTxt = if ($stopped.Count) { $stopped -join ', ' } else { 'none' }
    $summary = "Status -> running: $runTxt  |  stopped: $stopTxt"
    if     ($stopped.Count -eq 0) { Write-Log $summary 'ok'   }
    elseif ($running.Count -eq 0) { Write-Log $summary 'err'  }
    else                          { Write-Log $summary 'warn' }
})
$grpStack.Controls.Add($btnStatus)

$btnReload = New-Object System.Windows.Forms.Button
$btnReload.Text = 'Reload Nginx'; $btnReload.SetBounds(470, 24, 130, 32)
$btnReload.Add_Click({ Invoke-NginxReload })
$grpStack.Controls.Add($btnReload)


$btnSetup = New-Object System.Windows.Forms.Button
$btnSetup.Text = 'Run Setup'
$btnSetup.SetBounds(320, 24, 200, 64)
$btnSetup.BackColor = [System.Drawing.Color]::FromArgb(0,100,180)
$btnSetup.ForeColor = [System.Drawing.Color]::White
$btnSetup.Font = New-Object System.Drawing.Font('Segoe UI', 11, [System.Drawing.FontStyle]::Bold)
$btnSetup.Add_Click({
    $this.Enabled = $false
    Write-Log 'Starting setup — downloading MySQL, PHP, Nginx, phpMyAdmin...' 'warn'
    Flush-UI
    $setupPath = Join-Path $script:HelperDir 'setup.ps1'
    $basePath  = $script:BASE
    $job = Start-Job -ScriptBlock { & $using:setupPath -Base $using:basePath *>&1 }
    while ($job.State -eq 'Running') {
        $out = Receive-Job $job
        foreach ($line in $out) { $t = "$line".Trim(); if ($t) { Write-Log "  $t"; Flush-UI } }
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 100
    }
    $out = Receive-Job $job
    foreach ($line in $out) { $t = "$line".Trim(); if ($t) { Write-Log "  $t"; Flush-UI } }
    Remove-Job $job
    if (Test-IsSetup) {
        Write-Log 'Setup complete — all binaries present.' 'ok'
        $script:lastSetupState = $true
        Update-SetupState
    } else {
        $missing = @()
        if (-not (Test-Path (Join-Path $script:BASE 'nginx\nginx.exe')))      { $missing += 'Nginx' }
        if (-not (Test-Path (Join-Path $script:BASE 'mysql\bin\mysqld.exe'))) { $missing += 'MySQL' }
        if (-not (Test-Path (Join-Path $script:BASE 'php\php-cgi.exe')))      { $missing += 'PHP' }
        if (-not (Test-Path (Join-Path $script:BASE 'phpmyadmin\index.php'))) { $missing += 'phpMyAdmin' }
        if (-not (Test-Path (Join-Path $script:BASE 'mysql\my.ini')))         { $missing += 'MySQL config' }
        Write-Log "Setup incomplete — still missing: $($missing -join ', '). Fix the issue and click Run Setup again." 'err'
        $this.Enabled = $true
    }
})
$grpStack.Controls.Add($btnSetup)

# --- Sites group ---
$grpSites = New-Object System.Windows.Forms.GroupBox
$grpSites.Text = 'Sites'
$grpSites.SetBounds(12, 126, 890, 430)
$form.Controls.Add($grpSites)

$btnNew = New-Object System.Windows.Forms.Button
$btnNew.Text = '+ New site'; $btnNew.SetBounds(16, 22, 110, 30)
$btnNew.Add_Click({
    $name = [Microsoft.VisualBasic.Interaction]::InputBox('Enter new site name (e.g. myshop):', 'New site', '')
    if ([string]::IsNullOrWhiteSpace($name)) { Write-Log 'New site cancelled.' 'warn'; return }
    Invoke-NewSite $name.Trim()
    Build-SiteRows
})
$grpSites.Controls.Add($btnNew)

$btnPma = New-Object System.Windows.Forms.Button
$btnPma.Text = 'phpMyAdmin'; $btnPma.SetBounds(132, 22, 110, 30)
$btnPma.Add_Click({ Open-Url 'http://localhost:8080' })
$grpSites.Controls.Add($btnPma)

$btnDash = New-Object System.Windows.Forms.Button
$btnDash.Text = 'Dashboard'; $btnDash.SetBounds(248, 22, 110, 30)
$btnDash.Add_Click({ Open-Url 'http://localhost' })
$grpSites.Controls.Add($btnDash)

$btnRefreshSites = New-Object System.Windows.Forms.Button
$btnRefreshSites.Text = 'Refresh list'; $btnRefreshSites.SetBounds(364, 22, 110, 30)
$btnRefreshSites.Add_Click({ Build-SiteRows; Write-Log 'Site list refreshed.' 'ok' })
$grpSites.Controls.Add($btnRefreshSites)

# --- "Open links with" selectors (settings only - they open nothing) ---
$lblOpenWith = New-Object System.Windows.Forms.Label
$lblOpenWith.Text = 'Open links on:'
$lblOpenWith.SetBounds(596, 27, 88, 20)
$grpSites.Controls.Add($lblOpenWith)

$cmbHost = New-Object System.Windows.Forms.ComboBox
$cmbHost.DropDownStyle = 'DropDownList'
$cmbHost.SetBounds(686, 23, 160, 24)
[void]$cmbHost.Items.Add('localhost')
$ipForHost = Get-LocalIp
if ($ipForHost -and $ipForHost -ne 'localhost') { [void]$cmbHost.Items.Add($ipForHost) }
$cmbHost.SelectedIndex = 1
$grpSites.Controls.Add($cmbHost)

$tip = New-Object System.Windows.Forms.ToolTip
$tip.SetToolTip($lblOpenWith, 'Just a preference: which address the Site / WP Admin links open with. Nothing is changed.')
$tip.SetToolTip($cmbHost,  'localhost = this PC.  The IP = reachable from your phone / another device on the same network.')

$flow = New-Object System.Windows.Forms.FlowLayoutPanel
$flow.SetBounds(16, 58, 858, 356)
$flow.FlowDirection = 'TopDown'
$flow.WrapContents = $false
$flow.AutoScroll = $true
$flow.BackColor = [System.Drawing.Color]::FromArgb(245,246,248)
$flow.BorderStyle = 'FixedSingle'
$grpSites.Controls.Add($flow)
$flow.Add_SizeChanged({ Resize-Rows })

# --- Log ---
$grpLog = New-Object System.Windows.Forms.GroupBox
$grpLog.Text = 'Activity'
$grpLog.SetBounds(12, 564, 890, 150)
$form.Controls.Add($grpLog)

$logBox = New-Object System.Windows.Forms.RichTextBox
$logBox.SetBounds(16, 22, 858, 116)
$logBox.ReadOnly = $true
$logBox.ScrollBars = 'Vertical'
$logBox.BackColor = [System.Drawing.Color]::White
$logBox.Font = New-Object System.Drawing.Font('Consolas', 9)
$grpLog.Controls.Add($logBox)

# --- resize anchors ---
$form.MinimumSize = New-Object System.Drawing.Size(930, 600)
$grpStack.Anchor = 'Top, Left, Right'
$grpSites.Anchor = 'Top, Bottom, Left, Right'
$flow.Anchor     = 'Top, Bottom, Left, Right'
$grpLog.Anchor   = 'Bottom, Left, Right'
$logBox.Anchor   = 'Top, Bottom, Left, Right'

# --- auto-refresh live stack status every 5s (read-only) ---
$script:lastSetupState = $null
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 5000
$timer.Add_Tick({
    $now = Test-IsSetup
    if ($now -ne $script:lastSetupState) {
        $script:lastSetupState = $now
        Update-SetupState
    } elseif ($now) {
        Update-Status
    }
})
$timer.Start()

function Update-SetupState {
    $ready = Test-IsSetup
    $btnSetup.Visible  = -not $ready
    $btnStart.Visible  = $ready
    $btnStop.Visible   = $ready
    $btnReload.Visible = $ready
    $btnStatus.Visible = $ready
    if ($ready) {
        Update-Status
        Build-SiteRows
    } else {
        $flow.Controls.Clear()
    }
}

$form.Add_Shown({
    Write-Log "Base: $script:BASE"
    Update-SetupState
    # signal the launcher (control-panel.bat) that the GUI is up so it can close its cmd window
    try { Set-Content -LiteralPath (Join-Path $env:TEMP 'localhost-wp-cp.ready') -Value 'ready' -ErrorAction SilentlyContinue } catch {}
})
[void]$form.ShowDialog()
