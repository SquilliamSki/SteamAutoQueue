#requires -Version 5.1
<#
    Steam Auto Queue
    ----------------
    Moves Steam updates out of "Scheduled" and into "Up Next" so they download
    right away, instead of waiting for an off-peak time when your PC is off.

    Not made by, affiliated with, or endorsed by Valve or Steam.
    https://github.com/SquilliamSki/SteamAutoQueue

    You normally never run this file directly. Use Install.cmd / Uninstall.cmd
    and the tray icon near the clock.

      -Mode Install    Set everything up (starts automatically at login)
      -Mode Tray       The tray icon and background helper
      -Mode Uninstall  Remove everything this tool changed
#>
param(
    [ValidateSet('Tray', 'Watch', 'Install', 'Uninstall', 'Lib')]
    [string]$Mode = 'Tray'
)

$ErrorActionPreference = 'Stop'

# ---- For whoever publishes this tool -------------------------------------
# Bump AppVersion for each release. Put your GitHub "owner/repo" in UpdateRepo
# and tag releases like v1.2.0; the tray will tell people when a newer version
# is out. Leave UpdateRepo empty to hide the update check.
$AppVersion = '1.1.2'
$UpdateRepo = 'SquilliamSki/SteamAutoQueue'
# ---------------------------------------------------------------------------

$AppName    = 'Steam Auto Queue'
$TaskName   = 'Steam Auto Queue'
$DebugFlag  = '-cef-enable-debugging'
$FlagFile   = '.cef-enable-remote-debugging'
$ScriptPath = $PSCommandPath
$ScriptDir  = $PSScriptRoot

if ($env:LOCALAPPDATA) { $InstallDir = Join-Path $env:LOCALAPPDATA 'SteamAutoQueue' } else { $InstallDir = $ScriptDir }

$SettingsPath = Join-Path $ScriptDir 'settings.ini'
$LogPath      = Join-Path $ScriptDir 'log.txt'
$StatePath    = Join-Path $ScriptDir 'state.json'
$IconPath     = Join-Path $ScriptDir 'SteamAutoQueue.ico'

$script:Interactive = $false
$script:S = $null

# ===========================================================================
#  Logging, settings, state
# ===========================================================================

function Write-Log([string]$Message) {
    $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    try {
        if ((Test-Path -LiteralPath $LogPath) -and ((Get-Item -LiteralPath $LogPath).Length -gt 512KB)) {
            Move-Item -LiteralPath $LogPath -Destination (Join-Path $ScriptDir 'log.old.txt') -Force
        }
        Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
    } catch { }
}

function Say([string]$Message, [string]$Color = 'Gray') {
    if ($script:Interactive) { Write-Host $Message -ForegroundColor $Color }
}

function Get-Settings {
    $s = @{
        RunWhenSteamStarts    = $true
        StartupDelaySeconds   = 60
        DailyTime             = ''
        StartSteamForDailyRun = $false
        RecheckEveryMinutes   = 30
        QueueUnscheduledToo   = $false
        ExcludeAppIds         = @()
        AutoFixSteam          = $true
        ShowNotifications     = $true
        CheckForUpdates       = $true
        TestMode              = $false
        DebugPort             = 8080
    }
    if (-not (Test-Path -LiteralPath $SettingsPath)) { return $s }

    foreach ($raw in Get-Content -LiteralPath $SettingsPath) {
        $line = $raw.Trim()
        if ($line -eq '' -or $line.StartsWith(';') -or $line.StartsWith('#')) { continue }
        $eq = $line.IndexOf('=')
        if ($eq -lt 1) { continue }
        $key = $line.Substring(0, $eq).Trim()
        $val = $line.Substring($eq + 1).Trim()
        if (-not $s.ContainsKey($key)) { continue }
        try {
            switch ($key) {
                'DailyTime' {
                    if ($val -eq '') { $s[$key] = '' }
                    else {
                        $t = [datetime]::ParseExact($val, 'H:mm', [Globalization.CultureInfo]::InvariantCulture)
                        $s[$key] = $t.ToString('HH:mm')
                    }
                }
                'ExcludeAppIds' {
                    $s[$key] = @($val -split '[,;\s]+' | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ })
                }
                default {
                    if ($s[$key] -is [bool]) { $s[$key] = @('true', 'yes', 'on', '1') -contains $val.ToLower() }
                    elseif ($s[$key] -is [int]) { $s[$key] = [Math]::Max(0, [int]$val) }
                }
            }
        } catch {
            Write-Log "Ignoring setting I couldn't understand: '$line'"
        }
    }
    return $s
}

function Get-State {
    $st = $null
    try { if (Test-Path -LiteralPath $StatePath) { $st = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json } } catch { }
    if (-not $st) { $st = [pscustomobject]@{} }
    foreach ($p in @(@('LastDaily', ''), @('Paused', $false), @('LastUpdateCheck', ''))) {
        if (-not ($st.PSObject.Properties.Name -contains $p[0])) { $st | Add-Member -NotePropertyName $p[0] -NotePropertyValue $p[1] }
    }
    return $st
}

function Save-State($State) {
    try { $State | ConvertTo-Json | Set-Content -LiteralPath $StatePath -Encoding UTF8 } catch { }
}

# ===========================================================================
#  Steam helpers
# ===========================================================================

function Get-SteamInfo {
    $p = Get-ItemProperty -Path 'HKCU:\Software\Valve\Steam' -ErrorAction SilentlyContinue
    if (-not $p) { return $null }
    $dir = $null; $exe = $null
    if ($p.SteamPath) { $dir = $p.SteamPath -replace '/', '\' }
    if ($p.SteamExe)  { $exe = $p.SteamExe -replace '/', '\' } elseif ($dir) { $exe = Join-Path $dir 'steam.exe' }
    $running = 0
    if ($p.RunningAppID) { $running = [int]$p.RunningAppID }
    return [pscustomobject]@{ Dir = $dir; Exe = $exe; RunningAppId = $running }
}

function Get-SteamProcess {
    return Get-Process -Name 'steam' -ErrorAction SilentlyContinue | Select-Object -First 1
}

function Get-DebugTargets([int]$Port) {
    try {
        # Assign first, then pipe: Windows PowerShell 5.1 returns a JSON array as one
        # object, and piping a variable unrolls it into individual targets.
        $list = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/json" -TimeoutSec 3 -UseBasicParsing
        return ,@($list | ForEach-Object { $_ })
    }
    catch { return $null }
}

function Invoke-SteamJs([string]$WsUrl, [string]$Expression, [int]$TimeoutSec = 40) {
    $ws  = New-Object System.Net.WebSockets.ClientWebSocket
    $cts = New-Object System.Threading.CancellationTokenSource ([TimeSpan]::FromSeconds($TimeoutSec))
    try {
        $ws.ConnectAsync([Uri]$WsUrl, $cts.Token).GetAwaiter().GetResult()

        $request = @{
            id     = 1
            method = 'Runtime.evaluate'
            params = @{ expression = $Expression; awaitPromise = $true; returnByValue = $true }
        } | ConvertTo-Json -Depth 5 -Compress
        $bytes = [Text.Encoding]::UTF8.GetBytes($request)
        $ws.SendAsync([ArraySegment[byte]]::new($bytes), [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $cts.Token).GetAwaiter().GetResult()

        $buffer = New-Object byte[] 65536
        while ($true) {
            $ms = New-Object System.IO.MemoryStream
            do {
                $r = $ws.ReceiveAsync([ArraySegment[byte]]::new($buffer), $cts.Token).GetAwaiter().GetResult()
                if ($r.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) { throw 'Steam closed the connection.' }
                $ms.Write($buffer, 0, $r.Count)
            } while (-not $r.EndOfMessage)

            $msg = [Text.Encoding]::UTF8.GetString($ms.ToArray()) | ConvertFrom-Json
            if ($msg.id -ne 1) { continue }
            if ($msg.error) { throw "Steam refused the request: $($msg.error.message)" }
            if ($msg.result.exceptionDetails) {
                $detail = $msg.result.exceptionDetails.text
                if ($msg.result.exceptionDetails.exception) { $detail = $msg.result.exceptionDetails.exception.description }
                throw "Steam script error: $detail"
            }
            return $msg.result.result.value
        }
    } finally {
        try { $ws.Dispose() } catch { }
        $cts.Dispose()
    }
}

# The JavaScript that runs inside Steam's own UI. It reads the download list,
# picks everything waiting in "Scheduled", and asks Steam to queue each one,
# exactly like clicking each game's "download now" button.
$QueueJs = @'
(async () => {
  if (typeof SteamClient === 'undefined' || !SteamClient.Downloads) return { ok: false, error: 'steam-not-ready' };
  const D = SteamClient.Downloads;
  if (typeof D.RegisterForDownloadItems !== 'function' || typeof D.ResumeAppUpdate !== 'function') return { ok: false, error: 'api-missing' };
  const LOCAL = '0';   // Steam's id for "this PC" (other ids are remote-download PCs)

  // Steam hands the list over either flat (older Steam) or grouped per PC:
  // [{ remote_client_id: '0', item_data: [ ...games... ] }, ...]
  const readItems = () => new Promise((resolve) => {
    let done = false, reg = null;
    const finish = (v) => {
      if (done) return;
      done = true;
      setTimeout(() => { try { if (reg) reg.unregister(); } catch (e) {} }, 0);
      resolve(v);
    };
    try {
      reg = D.RegisterForDownloadItems((busy, list) => {
        if (!Array.isArray(list)) return finish(null);
        if (list.length && list[0] && Array.isArray(list[0].item_data)) {
          const mine = list.find((g) => String(g.remote_client_id) === LOCAL);
          return finish(mine ? mine.item_data : []);
        }
        if (list.length && list[0] && typeof list[0].appid !== 'number') return finish(null);
        finish(list);
      });
    } catch (e) { finish(null); }
    setTimeout(() => finish(null), 8000);
  });

  // Same tests Steam's Downloads page uses for its sections.
  const isScheduled = (i) => i.queue_index === -1 && !!i.deferred_time && !i.completed;
  const isUnscheduled = (i) => !i.active && !i.completed && i.queue_index === -1 && !i.deferred_time;

  const items = await readItems();
  if (items === null) return { ok: false, error: 'unknown-list-format' };

  const exclude = new Set(__EXCLUDE__);
  const includeUnscheduled = __UNSCHEDULED__;
  const testMode = __TEST__;
  const nameOf = (id) => {
    try {
      const o = window.appStore && window.appStore.GetAppOverviewByAppID(id);
      if (o && o.display_name) return o.display_name;
    } catch (e) {}
    return 'App ' + id;
  };

  const scheduled = items.filter(isScheduled);
  const unscheduled = items.filter(isUnscheduled);
  const picked = items.filter((i) => !exclude.has(i.appid) && (isScheduled(i) || (includeUnscheduled && isUnscheduled(i))));
  const base = { ok: true, scheduled: scheduled.length, unscheduled: unscheduled.length,
                 excluded: scheduled.concat(unscheduled).filter((i) => exclude.has(i.appid)).length };

  if (testMode || picked.length === 0) {
    return Object.assign(base, { queued: picked.map((i) => ({ appid: i.appid, name: nameOf(i.appid) })), failed: [] });
  }

  // What Steam's own "move to top" button on a Scheduled game does.
  for (const i of picked) {
    try { D.ResumeAppUpdate(i.appid, LOCAL); } catch (e) {}
    await new Promise((r) => setTimeout(r, 250));
  }

  // Check Steam actually moved them, instead of trusting the call.
  await new Promise((r) => setTimeout(r, 1500));
  const after = await readItems();
  const stillWaiting = new Set((after || []).filter((i) => isScheduled(i) || isUnscheduled(i)).map((i) => i.appid));
  const queued = [], failed = [];
  for (const i of picked) {
    const entry = { appid: i.appid, name: nameOf(i.appid) };
    if (after === null || stillWaiting.has(i.appid)) failed.push(entry); else queued.push(entry);
  }
  if (queued.length === 0) return { ok: false, error: 'not-accepted', failed: failed.length };
  return Object.assign(base, { queued: queued, failed: failed });
})()
'@

function Invoke-QueueUpdates($S) {
    $targets = Get-DebugTargets $S.DebugPort
    if ($null -eq $targets) { return [pscustomobject]@{ Ok = $false; Reason = 'NoPort' } }

    $target = $targets | Where-Object { $_.title -eq 'SharedJSContext' -and $_.webSocketDebuggerUrl } | Select-Object -First 1
    if (-not $target) {
        $target = $targets | Where-Object { $_.url -like '*steamloopback.host*' -and $_.type -eq 'page' -and $_.webSocketDebuggerUrl } | Select-Object -First 1
    }
    if (-not $target) { return [pscustomobject]@{ Ok = $false; Reason = 'NotReady'; Detail = 'no-ui-page' } }

    $js = $QueueJs.Replace('__EXCLUDE__', '[' + (($S.ExcludeAppIds | ForEach-Object { [string]$_ }) -join ',') + ']')
    $js = $js.Replace('__UNSCHEDULED__', $S.QueueUnscheduledToo.ToString().ToLower())
    $js = $js.Replace('__TEST__', $S.TestMode.ToString().ToLower())

    try { $v = Invoke-SteamJs -WsUrl $target.webSocketDebuggerUrl -Expression $js }
    catch { return [pscustomobject]@{ Ok = $false; Reason = 'Error'; Detail = $_.Exception.Message } }

    if ($v -and $v.error -eq 'api-missing') { return [pscustomobject]@{ Ok = $false; Reason = 'Error'; Detail = 'Steam no longer has the download functions this tool uses.' } }
    if ($v -and $v.error -eq 'unknown-list-format') { return [pscustomobject]@{ Ok = $false; Reason = 'Error'; Detail = 'Steam changed the format of its download list.' } }
    if ($v -and $v.error -eq 'not-accepted') { return [pscustomobject]@{ Ok = $false; Reason = 'Error'; Detail = "Steam did not move any of the $($v.failed) scheduled update(s) when asked." } }
    if (-not $v -or -not $v.ok) {
        $detail = ''
        if ($v) { $detail = $v.error }
        return [pscustomobject]@{ Ok = $false; Reason = 'NotReady'; Detail = $detail }
    }

    return [pscustomobject]@{
        Ok          = $true
        Queued      = @($v.queued | Where-Object { $_ -and $_.appid })
        Failed      = @($v.failed | Where-Object { $_ -and $_.appid })
        Scheduled   = [int]$v.scheduled
        Unscheduled = [int]$v.unscheduled
        Excluded    = [int]$v.excluded
        TestMode    = $S.TestMode
        Unsched     = $S.QueueUnscheduledToo
    }
}

function Format-Result($r) {
    $names = @($r.Queued | ForEach-Object { $_.name })
    $verb = 'Queued'
    if ($r.TestMode) { $verb = 'TEST MODE - would have queued' }
    if ($names.Count -eq 0) { $text = 'Nothing waiting in Scheduled.' }
    else { $text = '{0} {1} update(s): {2}' -f $verb, $names.Count, ($names -join ', ') }
    if ($r.Failed.Count -gt 0) {
        $text += " Steam didn't move: " + ((@($r.Failed | ForEach-Object { $_.name })) -join ', ') + '.'
    }
    if ($r.Unscheduled -gt 0 -and -not $r.Unsched) {
        $text += " ($($r.Unscheduled) in Unscheduled left alone.)"
    }
    return $text
}

function Get-SteamArgs([int]$ProcessId) {
    try {
        $cmd = (Get-CimInstance Win32_Process -Filter "ProcessId=$ProcessId").CommandLine
        if (-not $cmd) { return '' }
        if ($cmd.StartsWith('"')) { $rest = $cmd.Substring($cmd.IndexOf('"', 1) + 1) }
        else { $sp = $cmd.IndexOf(' '); if ($sp -lt 0) { $rest = '' } else { $rest = $cmd.Substring($sp) } }
        return $rest.Trim()
    } catch { return '' }
}

function Restart-SteamWithSwitch {
    $info = Get-SteamInfo
    $proc = Get-SteamProcess
    if (-not $info -or -not $info.Exe -or -not (Test-Path -LiteralPath $info.Exe)) { Write-Log 'Could not find steam.exe to restart.'; return $false }

    $steamArgs = ''
    if ($proc) { $steamArgs = Get-SteamArgs $proc.Id }
    if ($steamArgs -notmatch [regex]::Escape($DebugFlag)) { $steamArgs = ($steamArgs + ' ' + $DebugFlag).Trim() }

    # Don't log $steamArgs: Steam's command line can contain a login (-login user pass).
    Write-Log 'Restarting Steam with the helper switch.'
    if ($proc) {
        Start-Process -FilePath $info.Exe -ArgumentList '-shutdown'
        $deadline = (Get-Date).AddSeconds(90)
        while ((Get-SteamProcess) -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 2 }
        if (Get-SteamProcess) { Write-Log 'Steam did not close in time; leaving it alone.'; return $false }
        Start-Sleep -Seconds 2
    }
    Start-Process -FilePath $info.Exe -ArgumentList $steamArgs
    return $true
}

function Start-SteamQuietly {
    $info = Get-SteamInfo
    if (-not $info -or -not $info.Exe -or -not (Test-Path -LiteralPath $info.Exe)) { Write-Log 'Could not find steam.exe to start.'; return }
    Write-Log 'Starting Steam in the background for the daily run.'
    Start-Process -FilePath $info.Exe -ArgumentList "-silent $DebugFlag"
}

function Get-LatestRelease {
    # Returns @{ Version; Url } or $null. Never throws.
    if (-not $UpdateRepo) { return $null }
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/$UpdateRepo/releases/latest" -TimeoutSec 8 -UseBasicParsing `
                   -Headers @{ 'User-Agent' = "SteamAutoQueue/$AppVersion"; 'Accept' = 'application/vnd.github+json' }
        $tag = ($rel.tag_name -replace '^[vV]', '')
        return [pscustomobject]@{ Version = [version]$tag; Url = $rel.html_url }
    } catch { return $null }
}

# ===========================================================================
#  Icon (original artwork, drawn in code: a download arrow into a tray)
# ===========================================================================

function New-AppBitmap([int]$Size, [string]$State = 'ok') {
    Add-Type -AssemblyName System.Drawing
    switch ($State) {
        'paused' { $bg = [System.Drawing.Color]::FromArgb(125, 130, 138) }
        'alert'  { $bg = [System.Drawing.Color]::FromArgb(222, 150, 30) }
        default  { $bg = [System.Drawing.Color]::FromArgb(20, 150, 120) }
    }
    $bmp = New-Object System.Drawing.Bitmap $Size, $Size
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.Clear([System.Drawing.Color]::Transparent)
    $n = [single]$Size

    # rounded square
    $x = 0.04 * $n; $w = 0.92 * $n; $d = 0.44 * $n
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $path.AddArc($x, $x, $d, $d, 180, 90)
    $path.AddArc($x + $w - $d, $x, $d, $d, 270, 90)
    $path.AddArc($x + $w - $d, $x + $w - $d, $d, $d, 0, 90)
    $path.AddArc($x, $x + $w - $d, $d, $d, 90, 90)
    $path.CloseFigure()
    $bgBrush = New-Object System.Drawing.SolidBrush $bg
    $g.FillPath($bgBrush, $path)

    $white = [System.Drawing.Brushes]::White
    $rect = { param($x1, $y1, $x2, $y2) $g.FillRectangle($white, [single]($x1 * $n), [single]($y1 * $n), [single](($x2 - $x1) * $n), [single](($y2 - $y1) * $n)) }
    & $rect 0.42 0.14 0.58 0.48      # arrow shaft
    $pts = [System.Drawing.PointF[]]@(
        [System.Drawing.PointF]::new([single](0.25 * $n), [single](0.44 * $n)),
        [System.Drawing.PointF]::new([single](0.75 * $n), [single](0.44 * $n)),
        [System.Drawing.PointF]::new([single](0.50 * $n), [single](0.70 * $n)))
    $g.FillPolygon($white, $pts)     # arrow head
    & $rect 0.20 0.78 0.80 0.87      # tray base
    & $rect 0.20 0.62 0.29 0.87      # tray left
    & $rect 0.71 0.62 0.80 0.87      # tray right

    $bgBrush.Dispose(); $path.Dispose(); $g.Dispose()
    return $bmp
}

function Save-AppIco([string]$Path) {
    # Multi-size .ico with PNG-compressed entries (Windows Vista and later).
    $sizes = @(16, 24, 32, 48, 256)
    $pngs = New-Object System.Collections.Generic.List[byte[]]
    foreach ($sz in $sizes) {
        $b = New-AppBitmap $sz 'ok'
        $ms = New-Object System.IO.MemoryStream
        $b.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
        $b.Dispose()
        $pngs.Add($ms.ToArray())
    }
    $fs = [System.IO.File]::Create($Path)
    $bw = New-Object System.IO.BinaryWriter $fs
    try {
        $bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]$sizes.Count)
        $offset = 6 + 16 * $sizes.Count
        for ($i = 0; $i -lt $sizes.Count; $i++) {
            $dim = $sizes[$i]; if ($dim -ge 256) { $dim = 0 }
            $bw.Write([byte]$dim); $bw.Write([byte]$dim); $bw.Write([byte]0); $bw.Write([byte]0)
            $bw.Write([uint16]1); $bw.Write([uint16]32)
            $bw.Write([uint32]$pngs[$i].Length); $bw.Write([uint32]$offset)
            $offset += $pngs[$i].Length
        }
        foreach ($p in $pngs) { $bw.Write($p) }
    } finally { $bw.Close() }
}

# ===========================================================================
#  Tray app
# ===========================================================================

function Start-Work([string]$Kind, [string]$Reason) {
    # Runs the slow part (talking to Steam, restarting it) on a background
    # thread so the tray menu never freezes.
    $rs = $null
    try {
        $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
        $iss.ExecutionPolicy = [Microsoft.PowerShell.ExecutionPolicy]::Bypass
        $rs = [runspacefactory]::CreateRunspace($iss)
        $rs.Open()
    } catch {
        # Fall back to a plain runspace (it inherits this process's -ExecutionPolicy Bypass)
        $rs = [runspacefactory]::CreateRunspace()
        $rs.Open()
    }
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    $null = $ps.AddScript({
        param($File, $Kind)
        . $File -Mode Lib
        $script:S = Get-Settings
        if ($Kind -eq 'Restart') { [pscustomobject]@{ Ok = [bool](Restart-SteamWithSwitch); Reason = 'Restart' } }
        else { Invoke-QueueUpdates $script:S }
    }).AddArgument($ScriptPath).AddArgument($Kind)
    $script:St.Work = @{ PS = $ps; RS = $rs; Handle = $ps.BeginInvoke(); Kind = $Kind; Reason = $Reason; Started = Get-Date }
}

function Stop-Work {
    $w = $script:St.Work
    if (-not $w) { return }
    try { $w.PS.Stop() } catch { }
    try { $w.PS.Dispose(); $w.RS.Dispose() } catch { }
    $script:St.Work = $null
}

function Show-Balloon([string]$Text, [string]$Kind = 'Info', [scriptblock]$OnClick = $null, [switch]$Force) {
    if (-not $Force -and -not $script:S.ShowNotifications) { return }
    if ($Text.Length -gt 250) { $Text = $Text.Substring(0, 247) + '...' }
    $script:St.BalloonAction = $OnClick
    try { $script:St.Notify.ShowBalloonTip(6000, $AppName, $Text, [System.Windows.Forms.ToolTipIcon]::$Kind) } catch { }
}

function Update-TrayLook {
    $St = $script:St
    if ($St.Problem) { $look = 'alert'; $status = 'Needs attention - see Help' }
    elseif ($St.State.Paused) { $look = 'paused'; $status = 'Paused' }
    elseif ($St.Work) { $look = 'ok'; $status = 'Working...' }
    elseif ($St.LastText) { $look = 'ok'; $status = $St.LastText }
    elseif (-not (Get-SteamProcess)) { $look = 'ok'; $status = 'Waiting for Steam to open' }
    else { $look = 'ok'; $status = 'Watching for scheduled updates' }

    $St.Notify.Icon = $St.Icons[$look]
    $tip = "$AppName - $status"
    if ($tip.Length -gt 63) { $tip = $tip.Substring(0, 60) + '...' }
    $St.Notify.Text = $tip

    $St.MenuStatus.Text = $status
    if ($St.State.Paused) { $St.MenuPause.Text = 'Resume automatic queueing' } else { $St.MenuPause.Text = 'Pause automatic queueing' }
}

function Set-Problem([string]$Message, [switch]$SteamFix) {
    $St = $script:St
    if ($St.Problem -eq $Message) { return }
    $St.Problem = $Message
    Write-Log "Needs attention: $Message"
    $help = $Message
    if ($SteamFix) { $action = { Request-ManualRun } }
    elseif ($UpdateRepo) { $help += ' Click to check for a new version.'; $action = { Invoke-UpdateCheck -Manual } }
    else { $help += ' Click to open the log.'; $action = { Start-Process notepad.exe -ArgumentList "`"$LogPath`"" } }
    Show-Balloon $help 'Warning' $action -Force
    Update-TrayLook
}

function Clear-Problem {
    if ($script:St.Problem) { $script:St.Problem = $null; Write-Log 'Back to normal.'; Update-TrayLook }
}

function Invoke-UpdateCheck([switch]$Manual) {
    $St = $script:St
    $St.State.LastUpdateCheck = (Get-Date).ToString('yyyy-MM-dd')
    Save-State $St.State
    $rel = Get-LatestRelease
    if (-not $rel) {
        if ($Manual) { Show-Balloon 'Could not check for updates right now. Try again later.' 'Info' -Force }
        return
    }
    if ($rel.Version -gt [version]$AppVersion) {
        $url = $rel.Url
        $open = { Start-Process $url }.GetNewClosure()
        Show-Balloon "Version $($rel.Version) is available (you have $AppVersion). Click to download." 'Info' $open -Force
        Write-Log "Update available: $($rel.Version)"
    } elseif ($Manual) {
        Show-Balloon "You're up to date (version $AppVersion)." 'Info' -Force
    }
}

function Request-ManualRun {
    $St = $script:St
    if ($St.Work) { Show-Balloon 'Already working on it...' 'Info' -Force; return }
    if (-not (Get-SteamProcess)) { Show-Balloon 'Steam is not open. Open Steam, then try again.' 'Info' -Force; return }
    Start-Work 'Queue' 'manual'
    Update-TrayLook
}

function Complete-Work($w, $r) {
    $St = $script:St
    $now = Get-Date
    $manual = ($w.Reason -eq 'manual')

    if (-not $r) { $r = [pscustomobject]@{ Ok = $false; Reason = 'Error'; Detail = 'No answer from the background task.' } }

    if ($w.Kind -eq 'Restart') {
        if ($r.Ok) {
            $St.SteamPid = 0                   # new Steam process -> fresh run
            if ($manual) { $St.ManualPending = $true }
            $St.NextAttempt = $now.AddSeconds(20)
        } else {
            Set-Problem 'Could not restart Steam. Close Steam fully (Steam menu > Exit) and open it again.'
        }
        return
    }

    if ($r.Ok) {
        $St.RunAt = $null; $St.LastRun = $now; $St.FailSince = $null
        Clear-Problem
        if ($St.DailyDue) { $St.State.LastDaily = $now.ToString('yyyy-MM-dd'); Save-State $St.State }
        $text = Format-Result $r
        $count = @($r.Queued).Count
        if ($count -gt 0) { $St.LastText = "Last run $($now.ToString('h:mm tt')) - queued $count" }
        elseif (-not $St.LastText) { $St.LastText = "Last checked $($now.ToString('h:mm tt')) - nothing waiting" }
        if ($count -gt 0 -or $w.Reason -ne 'recheck') { Write-Log "[$($w.Reason)] $text" }
        if ($manual -or $w.Reason -eq 'after restart') { Show-Balloon $text 'Info' -Force }
        elseif ($count -gt 0) { Show-Balloon $text }
        return
    }

    switch ($r.Reason) {
        'NoPort' {
            if ($manual) {
                $answer = [System.Windows.Forms.MessageBox]::Show(
                    "Steam was opened without the helper switch, so $AppName can't reach it.`n`nRestart Steam now with the switch turned on?",
                    $AppName, [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
                if ($answer -eq [System.Windows.Forms.DialogResult]::Yes) { Start-Work 'Restart' 'manual' }
                return
            }
            $info = Get-SteamInfo
            $recent = ($now - $St.SteamStart).TotalMinutes -lt 10
            $noGame = (-not $info) -or $info.RunningAppId -eq 0
            if ($St.Settings.AutoFixSteam -and -not $St.FixTried -and $recent -and $noGame) {
                $St.FixTried = $true
                Write-Log 'Steam was opened without the helper switch. Restarting it once to turn the switch on.'
                Start-Work 'Restart' 'autofix'
            } else {
                Set-Problem 'Steam was opened without the helper switch. Click here or double-click the tray icon to fix it.' -SteamFix
                $St.NextAttempt = $now.AddMinutes(10)
            }
        }
        'NotReady' {
            if ($manual) { Show-Balloon 'Steam is still starting up. Try again in a minute.' 'Info' -Force; return }
            if (-not $St.FailSince) { $St.FailSince = $now }
            $St.NextAttempt = $now.AddSeconds(30)
            $steamUp = ($now - $St.SteamStart).TotalMinutes
            if ($steamUp -gt 5 -and ($now - $St.FailSince).TotalMinutes -gt 5) {
                Set-Problem 'Steam is not responding the way this tool expects. A Steam update may have changed something.'
                $St.NextAttempt = $now.AddMinutes(10)
            }
        }
        default {
            Write-Log "Problem talking to Steam: $($r.Detail)"
            if ($manual) { Show-Balloon "Something went wrong: $($r.Detail)" 'Warning' -Force }
            if (-not $St.FailSince) { $St.FailSince = $now }
            $St.ErrorCount++
            if ($St.ErrorCount -ge 2) { Set-Problem 'Steam may have changed something this tool relies on, so updates are not being queued.' }
            $St.NextAttempt = $now.AddMinutes(5)
        }
    }
}

function Invoke-TrayTick {
    $St = $script:St
    if ($St.InTick) { return }
    $St.InTick = $true
    try {
        $now = Get-Date

        # 1. Finish background work if it's done
        if ($St.Work) {
            $w = $St.Work
            if (-not $w.Handle.IsCompleted) {
                if (($now - $w.Started).TotalMinutes -gt 4) { Stop-Work; Write-Log 'Gave up waiting for Steam to respond.' }
                return
            }
            $r = $null
            try { $r = $w.PS.EndInvoke($w.Handle) | Select-Object -Last 1 }
            catch { $r = [pscustomobject]@{ Ok = $false; Reason = 'Error'; Detail = $_.Exception.Message } }
            try { $w.PS.Dispose(); $w.RS.Dispose() } catch { }
            $St.Work = $null
            if ($r -and $r.Ok) { $St.ErrorCount = 0 }
            Complete-Work $w $r
            return
        }

        # 2. Decide whether a run is due
        $S = Get-Settings
        $script:S = $S
        $St.Settings = $S
        $today = $now.ToString('yyyy-MM-dd')

        $St.DailyDue = $false
        if ($S.DailyTime -ne '' -and $St.State.LastDaily -ne $today) {
            $dailyAt = [datetime]::ParseExact("$today $($S.DailyTime)", 'yyyy-MM-dd HH:mm', $null)
            $St.DailyDue = ($now -ge $dailyAt)
        }

        $proc = Get-SteamProcess
        if (-not $proc) {
            if ($St.SteamPid -ne 0) { $St.SteamPid = 0; $St.LastText = $null; Clear-Problem }
            $St.RunAt = $null; $St.LastRun = $null
            if (-not $St.State.Paused -and $St.DailyDue -and $S.StartSteamForDailyRun -and $St.StartedForDaily -ne $today) {
                $St.StartedForDaily = $today
                Start-SteamQuietly
            }
            return
        }

        if ($proc.Id -ne $St.SteamPid) {
            $St.SteamPid = $proc.Id
            $St.FixTried = $false; $St.LastRun = $null; $St.FailSince = $null; $St.ErrorCount = 0
            try { $St.SteamStart = $proc.StartTime } catch { $St.SteamStart = $now }
            $St.RunAt = $null
            if ($S.RunWhenSteamStarts -or $St.ManualPending) {
                $St.RunAt = $St.SteamStart.AddSeconds($S.StartupDelaySeconds)
                if ($St.ManualPending) { $St.RunAt = $now.AddSeconds(25) }
                if ($St.RunAt -lt $now) { $St.RunAt = $now }
            }
            $St.NextAttempt = $now
        }

        if ($now -lt $St.NextAttempt) { return }

        $reason = $null
        if ($St.ManualPending -and $St.RunAt -and $now -ge $St.RunAt) { $reason = 'after restart'; $St.ManualPending = $false }
        elseif (-not $St.State.Paused) {
            if ($St.RunAt -and $now -ge $St.RunAt) { $reason = 'Steam started' }
            elseif ($St.DailyDue) { $reason = 'daily run' }
            elseif ($St.LastRun -and $S.RecheckEveryMinutes -gt 0 -and $now -ge $St.LastRun.AddMinutes($S.RecheckEveryMinutes)) { $reason = 'recheck' }
        }
        if ($reason) { Start-Work 'Queue' $reason; return }

        # 3. Weekly update check
        if ($UpdateRepo -and $S.CheckForUpdates) {
            $last = [datetime]::MinValue
            if ($St.State.LastUpdateCheck) { try { $last = [datetime]::ParseExact($St.State.LastUpdateCheck, 'yyyy-MM-dd', $null) } catch { } }
            if (($now - $last).TotalDays -ge 7) { Invoke-UpdateCheck }
        }
    }
    catch { Write-Log "Unexpected error: $($_.Exception.Message)" }
    finally {
        $St.InTick = $false
        try { Update-TrayLook } catch { }
    }
}

function Exit-Tray {
    $St = $script:St
    try { $St.Timer.Stop(); $St.QuitTimer.Stop() } catch { }
    Stop-Work
    try { $St.Notify.Visible = $false; $St.Notify.Dispose() } catch { }
    Write-Log 'Tray helper closed.'
    [System.Windows.Forms.Application]::Exit()
}

function Start-Tray {
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing

    $created = $false
    $mutex = New-Object System.Threading.Mutex($true, 'Local\SteamAutoQueueTray', [ref]$created)
    if (-not $created) {
        [System.Windows.Forms.MessageBox]::Show("$AppName is already running.`n`nLook for its icon near the clock (it may be under the ^ arrow).",
            $AppName, 'OK', 'Information') | Out-Null
        return
    }
    $quitEvent = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::ManualReset, 'Local\SteamAutoQueueQuit')
    $quitEvent.Reset() | Out-Null

    [System.Windows.Forms.Application]::EnableVisualStyles()

    $iconSize = [System.Windows.Forms.SystemInformation]::SmallIconSize.Width
    if ($iconSize -lt 16) { $iconSize = 16 }
    $icons = @{}
    foreach ($k in 'ok', 'paused', 'alert') { $icons[$k] = [System.Drawing.Icon]::FromHandle((New-AppBitmap $iconSize $k).GetHicon()) }

    $script:S = Get-Settings
    $script:St = @{
        State = Get-State; Settings = $script:S; Icons = $icons; QuitEvent = $quitEvent
        Work = $null; InTick = $false; Problem = $null; LastText = $null; BalloonAction = $null
        SteamPid = 0; SteamStart = (Get-Date); RunAt = $null; NextAttempt = (Get-Date); LastRun = $null
        FixTried = $false; FailSince = $null; ErrorCount = 0; DailyDue = $false
        StartedForDaily = ''; ManualPending = $false
    }
    $St = $script:St

    # --- menu ---
    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    $St.MenuStatus = New-Object System.Windows.Forms.ToolStripMenuItem 'Starting...'
    $St.MenuStatus.Enabled = $false
    $null = $menu.Items.Add($St.MenuStatus)
    $null = $menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

    $miNow = New-Object System.Windows.Forms.ToolStripMenuItem 'Queue updates now'
    $miNow.Font = New-Object System.Drawing.Font($miNow.Font, [System.Drawing.FontStyle]::Bold)
    $miNow.add_Click({ Request-ManualRun })
    $null = $menu.Items.Add($miNow)

    $St.MenuPause = New-Object System.Windows.Forms.ToolStripMenuItem 'Pause automatic queueing'
    $St.MenuPause.add_Click({
        $script:St.State.Paused = -not $script:St.State.Paused
        Save-State $script:St.State
        if ($script:St.State.Paused) { Write-Log 'Paused by user.' } else { Write-Log 'Resumed by user.'; $script:St.NextAttempt = Get-Date }
        Update-TrayLook
    })
    $null = $menu.Items.Add($St.MenuPause)
    $null = $menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

    $miDl = New-Object System.Windows.Forms.ToolStripMenuItem 'Open Steam downloads'
    $miDl.add_Click({ try { Start-Process 'steam://open/downloads' } catch { } })
    $null = $menu.Items.Add($miDl)

    $miSet = New-Object System.Windows.Forms.ToolStripMenuItem 'Settings'
    $miSet.add_Click({ Start-Process notepad.exe -ArgumentList "`"$SettingsPath`"" })
    $null = $menu.Items.Add($miSet)

    $miLog = New-Object System.Windows.Forms.ToolStripMenuItem 'View log'
    $miLog.add_Click({ if (-not (Test-Path -LiteralPath $LogPath)) { Set-Content -LiteralPath $LogPath -Value '' }; Start-Process notepad.exe -ArgumentList "`"$LogPath`"" })
    $null = $menu.Items.Add($miLog)

    if ($UpdateRepo) {
        $miUpd = New-Object System.Windows.Forms.ToolStripMenuItem 'Check for updates'
        $miUpd.add_Click({ Invoke-UpdateCheck -Manual })
        $null = $menu.Items.Add($miUpd)
    }

    $miAbout = New-Object System.Windows.Forms.ToolStripMenuItem 'About'
    $miAbout.add_Click({
        $msg = "$AppName  version $AppVersion`n`n" +
               "Moves Steam updates from Scheduled to Up Next so they download right away.`n`n" +
               "Icon colors:  green = working,  gray = paused,  orange = needs attention.`n`n" +
               "This is an independent tool. It is not made by, affiliated with, or endorsed by Valve or Steam."
        if ($script:St.Problem) { $msg += "`n`nCurrent issue: $($script:St.Problem)" }
        [System.Windows.Forms.MessageBox]::Show($msg, $AppName, 'OK', 'Information') | Out-Null
    })
    $null = $menu.Items.Add($miAbout)
    $null = $menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

    $miExit = New-Object System.Windows.Forms.ToolStripMenuItem 'Exit (starts again at next login)'
    $miExit.add_Click({ Exit-Tray })
    $null = $menu.Items.Add($miExit)

    $menu.add_Opening({ try { Update-TrayLook } catch { } })

    # --- tray icon ---
    $St.Notify = New-Object System.Windows.Forms.NotifyIcon
    $St.Notify.ContextMenuStrip = $menu
    $St.Notify.add_MouseDoubleClick({ param($s, $e) if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Request-ManualRun } })
    $St.Notify.add_BalloonTipClicked({ $a = $script:St.BalloonAction; if ($a) { try { & $a } catch { } } })
    Update-TrayLook
    $St.Notify.Visible = $true

    # --- timers ---
    $St.Timer = New-Object System.Windows.Forms.Timer
    $St.Timer.Interval = 15000
    $St.Timer.add_Tick({ Invoke-TrayTick })
    $St.QuitTimer = New-Object System.Windows.Forms.Timer
    $St.QuitTimer.Interval = 1000
    $St.QuitTimer.add_Tick({
        if ($script:St.QuitEvent.WaitOne(0)) { Exit-Tray; return }
        if ($script:St.Work -and $script:St.Work.Handle.IsCompleted) { Invoke-TrayTick }   # pick up results quickly
    })

    Write-Log "Tray helper started (version $AppVersion)."
    $St.Timer.Start(); $St.QuitTimer.Start()
    Invoke-TrayTick
    [System.Windows.Forms.Application]::Run()
    $mutex.ReleaseMutex()
}

# ===========================================================================
#  Install / Uninstall
# ===========================================================================

function Stop-Tray {
    try { [System.Threading.EventWaitHandle]::OpenExisting('Local\SteamAutoQueueQuit').Set() | Out-Null } catch { }
    $deadline = (Get-Date).AddSeconds(6)
    do {
        $left = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
                  Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -match 'SteamAutoQueue\.ps1.*-Mode (Tray|Watch)' })
        if ($left.Count -eq 0) { break }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)
    foreach ($p in $left) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
    try { Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue } catch { }
}

function Get-TrayLaunch([string]$Script) {
    $psExe   = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $psArgs  = "-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Script`" -Mode Tray"
    $conhost = Join-Path $env:SystemRoot 'System32\conhost.exe'
    if ([Environment]::OSVersion.Version.Build -ge 17763 -and (Test-Path -LiteralPath $conhost)) {
        return @{ Exe = $conhost; Args = "--headless `"$psExe`" $psArgs" }
    }
    return @{ Exe = $psExe; Args = $psArgs }
}

function New-Shortcut([string]$Path, [string]$Target, [string]$Arguments, [string]$Icon, [string]$Description) {
    $shell = New-Object -ComObject WScript.Shell
    $lnk = $shell.CreateShortcut($Path)
    $lnk.TargetPath = $Target
    $lnk.Arguments = $Arguments
    $lnk.WorkingDirectory = $InstallDir
    if ($Icon) { $lnk.IconLocation = $Icon }
    $lnk.Description = $Description
    $lnk.Save()
}

function Install-Tool {
    $script:Interactive = $true
    Say ''
    Say "  Installing $AppName $AppVersion" 'Cyan'
    Say '  (an independent tool - not made by or affiliated with Valve/Steam)' 'DarkGray'
    Say ''

    $info = Get-SteamInfo
    if (-not $info -or -not $info.Exe -or -not (Test-Path -LiteralPath $info.Exe)) {
        Say '  Could not find Steam on this PC. Install Steam and sign in once, then run Install again.' 'Red'
        return
    }

    Stop-Tray

    # 1. Copy the tool to a permanent home (keeps your settings if reinstalling)
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    if ($ScriptDir -ne $InstallDir) {
        Copy-Item -LiteralPath $ScriptPath -Destination (Join-Path $InstallDir 'SteamAutoQueue.ps1') -Force
        foreach ($f in @('README.txt')) {
            $src = Join-Path $ScriptDir $f
            if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src -Destination $InstallDir -Force }
        }
        $destSettings = Join-Path $InstallDir 'settings.ini'
        if (-not (Test-Path -LiteralPath $destSettings) -and (Test-Path -LiteralPath $SettingsPath)) {
            Copy-Item -LiteralPath $SettingsPath -Destination $destSettings
        }
    }
    Get-ChildItem -LiteralPath $InstallDir -File | Unblock-File -ErrorAction SilentlyContinue
    $installed = Join-Path $InstallDir 'SteamAutoQueue.ps1'
    $ico = Join-Path $InstallDir 'SteamAutoQueue.ico'
    try { Save-AppIco $ico } catch { $ico = '' }
    Say "  [ok] Files copied to $InstallDir" 'Green'

    # 2. Let this tool talk to Steam (Steam's own developer switch, local to this PC only)
    try {
        New-Item -ItemType File -Path (Join-Path $info.Dir $FlagFile) -Force | Out-Null
        Say '  [ok] Turned on Steam''s helper switch' 'Green'
    } catch {
        Say '  [!!] Could not write to the Steam folder; will rely on the startup entry instead.' 'Yellow'
    }
    $runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    $runVal = (Get-ItemProperty -Path $runKey -Name 'Steam' -ErrorAction SilentlyContinue).Steam
    if ($runVal -and $runVal -notmatch [regex]::Escape($DebugFlag)) {
        Set-ItemProperty -Path $runKey -Name 'Steam' -Value "$runVal $DebugFlag"
        Say '  [ok] Added the switch to Steam''s "start with Windows" entry' 'Green'
    }

    # 3. Start the tray helper at every login
    $launch = Get-TrayLaunch $installed
    $user = "$env:USERDOMAIN\$env:USERNAME"
    $action   = New-ScheduledTaskAction -Execute $launch.Exe -Argument $launch.Args
    $trigger  = New-ScheduledTaskTrigger -AtLogOn -User $user
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
                    -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
    $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal `
        -Description 'Steam Auto Queue tray helper: moves Steam updates from Scheduled to Up Next.' -Force | Out-Null
    Say '  [ok] Set to start at login' 'Green'

    # 4. Start Menu shortcuts (remove ones from version 1.0)
    $menu = Join-Path ([Environment]::GetFolderPath('Programs')) $AppName
    if (Test-Path -LiteralPath $menu) { Remove-Item -LiteralPath $menu -Recurse -Force -ErrorAction SilentlyContinue }
    New-Item -ItemType Directory -Path $menu -Force | Out-Null
    New-Shortcut (Join-Path $menu 'Steam Auto Queue.lnk') $launch.Exe $launch.Args $ico 'Start the Steam Auto Queue tray icon'
    New-Shortcut (Join-Path $menu 'Steam Auto Queue Settings.lnk') 'notepad.exe' "`"$(Join-Path $InstallDir 'settings.ini')`"" '' 'Change when and how updates get queued'
    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $unArgs = "-NoProfile -ExecutionPolicy Bypass -Command `"Copy-Item '$installed' `$env:TEMP\SAQ-uninstall.ps1 -Force; & `$env:TEMP\SAQ-uninstall.ps1 -Mode Uninstall; Write-Host; Read-Host '  Press Enter to close'`""
    New-Shortcut (Join-Path $menu 'Uninstall Steam Auto Queue.lnk') $psExe $unArgs '' 'Remove Steam Auto Queue'
    Say '  [ok] Start Menu shortcuts added (search "Steam Auto Queue")' 'Green'

    Say ''
    if (Get-SteamProcess) {
        $script:S = Get-Settings
        if ($null -eq (Get-DebugTargets $script:S.DebugPort)) {
            Say '  Steam is open right now, but it needs one restart to pick up the switch.' 'Yellow'
            $answer = Read-Host '  Restart Steam now? (Y/N)'
            if ($answer -match '^[Yy]') { Restart-SteamWithSwitch | Out-Null; Say '  Steam is restarting. Scheduled updates will move to Up Next shortly.' 'Green' }
            else { Say '  No problem - it will take effect the next time Steam starts.' }
            Say ''
        }
    }

    # 5. Start it now
    Start-ScheduledTask -TaskName $TaskName
    Say '  [ok] Tray icon is running' 'Green'
    Say ''

    Say '  All done!' 'Cyan'
    Say '  Look for the green download-arrow icon near the clock. Right-click it for options.'
    Say '  Don''t see it? Click the ^ arrow by the clock, then drag the icon onto the taskbar'
    Say '  to keep it visible.'
    Say ''
    Say '  You can delete the folder you downloaded; the tool now lives in:'
    Say "  $InstallDir"
}

function Uninstall-Tool {
    $script:Interactive = $true
    Say ''
    Say "  Removing $AppName" 'Cyan'
    Say ''

    Stop-Tray
    try { Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop; Say '  [ok] Startup entry removed' 'Green' } catch { }

    $info = Get-SteamInfo
    if ($info -and $info.Dir) {
        $f = Join-Path $info.Dir $FlagFile
        if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue; Say '  [ok] Turned off Steam''s helper switch' 'Green' }
    }
    $runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    $runVal = (Get-ItemProperty -Path $runKey -Name 'Steam' -ErrorAction SilentlyContinue).Steam
    if ($runVal -and $runVal -match [regex]::Escape($DebugFlag)) {
        Set-ItemProperty -Path $runKey -Name 'Steam' -Value (($runVal -replace (' ?' + [regex]::Escape($DebugFlag)), '').Trim())
        Say '  [ok] Restored Steam''s "start with Windows" entry' 'Green'
    }

    $menu = Join-Path ([Environment]::GetFolderPath('Programs')) $AppName
    if (Test-Path -LiteralPath $menu) { Remove-Item -LiteralPath $menu -Recurse -Force -ErrorAction SilentlyContinue; Say '  [ok] Start Menu shortcuts removed' 'Green' }

    if (Test-Path -LiteralPath $InstallDir) { Remove-Item -LiteralPath $InstallDir -Recurse -Force -ErrorAction SilentlyContinue; Say '  [ok] Program files removed' 'Green' }

    Say ''
    Say '  Done. Steam goes fully back to normal the next time you restart it.' 'Cyan'
}

# ===========================================================================

switch ($Mode) {
    'Tray'      { Start-Tray }
    'Watch'     { Start-Tray }     # version 1.0 name
    'Install'   { Install-Tool }
    'Uninstall' { Uninstall-Tool }
    'Lib'       { }
}
