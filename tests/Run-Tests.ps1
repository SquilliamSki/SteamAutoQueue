<#
    Tests Steam Auto Queue without needing Steam, using a fake Steam server.

    Needs: Node.js 18+ on PATH.
    Run from the repo root:
        powershell -ExecutionPolicy Bypass -File tests\Run-Tests.ps1

    Works in Windows PowerShell 5.1 (what users have) and PowerShell 7.
    The icon tests only run on Windows.
#>
$ErrorActionPreference = 'Stop'
$repo   = Split-Path -Parent $PSScriptRoot
$server = Join-Path $PSScriptRoot 'fake-steam\server.js'
$onWindows = ($PSVersionTable.PSEdition -eq 'Desktop') -or $IsWindows

$script:Failures = 0
function Check([bool]$Condition, [string]$Name) {
    if ($Condition) { Write-Host "  PASS  $Name" -ForegroundColor Green }
    else { Write-Host "  FAIL  $Name" -ForegroundColor Red; $script:Failures++ }
}

# ---------------------------------------------------------------- parse
Write-Host 'Syntax'
Get-ChildItem -Path $repo -Recurse -Filter *.ps1 | Where-Object { $_.FullName -notmatch '[\\/](dist|\.git)[\\/]' } | ForEach-Object {
    $errs = $null
    [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$null, [ref]$errs) | Out-Null
    Check (-not $errs) "parses: $($_.Name)"
}

# ---------------------------------------------------------------- setup
$work = Join-Path ([IO.Path]::GetTempPath()) ('saq-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $work | Out-Null
Copy-Item (Join-Path $repo 'src\SteamAutoQueue.ps1') $work
$settingsFile = Join-Path $work 'settings.ini'
function Set-TestSettings([int]$Port, [string]$Extra = '') {
    Set-Content -LiteralPath $settingsFile -Value @"
RunWhenSteamStarts = true
StartupDelaySeconds = 0
DailyTime = 0:00
RecheckEveryMinutes = 30
ExcludeAppIds = 20
DebugPort = $Port
$Extra
"@
}
Set-TestSettings 18080

$okOut = Join-Path $work 'fake-ok.txt'
$servers = @(
    Start-Process -FilePath 'node' -ArgumentList "`"$server`"", '18080', 'ok' -RedirectStandardOutput $okOut -RedirectStandardError (Join-Path $work 'fake-ok-err.txt') -NoNewWindow -PassThru
    Start-Process -FilePath 'node' -ArgumentList "`"$server`"", '18081', 'notready' -RedirectStandardOutput (Join-Path $work 'fake-nr.txt') -RedirectStandardError (Join-Path $work 'fake-nr-err.txt') -NoNewWindow -PassThru
    Start-Process -FilePath 'node' -ArgumentList "`"$server`"", '18082', 'flat' -RedirectStandardOutput (Join-Path $work 'fake-flat.txt') -RedirectStandardError (Join-Path $work 'fake-flat-err.txt') -NoNewWindow -PassThru
    Start-Process -FilePath 'node' -ArgumentList "`"$server`"", '18083', 'stuck' -RedirectStandardOutput (Join-Path $work 'fake-stuck.txt') -RedirectStandardError (Join-Path $work 'fake-stuck-err.txt') -NoNewWindow -PassThru
)
$script:SeenQueued = 0
function Get-NewQueued {
    $all = @(Get-Content -LiteralPath $okOut -ErrorAction SilentlyContinue | Where-Object { $_ -like 'QUEUED *' } | ForEach-Object { [int]($_ -replace 'QUEUED ', '') })
    $new = @($all | Select-Object -Skip $script:SeenQueued)
    $script:SeenQueued = $all.Count
    return ,$new
}

try {
    $deadline = (Get-Date).AddSeconds(15)
    foreach ($p in 18080, 18081, 18082, 18083) {
        while ($true) {
            try { Invoke-WebRequest "http://127.0.0.1:$p/json" -UseBasicParsing -TimeoutSec 2 | Out-Null; break }
            catch { if ((Get-Date) -gt $deadline) { throw "Fake Steam on port $p did not start. Is Node.js installed?" }; Start-Sleep -Milliseconds 300 }
        }
    }

    . (Join-Path $work 'SteamAutoQueue.ps1') -Mode Lib

    # ------------------------------------------------------------ settings
    Write-Host 'Settings'
    Set-TestSettings 18080 "TestMode = maybe`r`nExcludeAppIds = 570; 730 abc`r`nDailyTime = 7:5x`r`nRecheckEveryMinutes = -4"
    $s = Get-Settings
    Check ($s.ExcludeAppIds -join ',' -eq '570,730') 'ExcludeAppIds accepts commas/semicolons and skips junk'
    Check ($s.TestMode -eq $false) 'unknown true/false value means false'
    Check ($s.DailyTime -eq '00:00') 'bad DailyTime is ignored (earlier valid value kept)'
    Check ($s.RecheckEveryMinutes -eq 0) 'negative numbers become 0'
    Check ($s.DebugPort -eq 18080) 'DebugPort read'
    Set-TestSettings 18080

    # ------------------------------------------------------------ queueing
    Write-Host 'Queueing (fake Steam)'
    $S = Get-Settings
    $r = Invoke-QueueUpdates $S
    Check ($r.Ok) 'talks to Steam'
    Check (((Get-NewQueued) -join ',') -eq '10') 'queues Scheduled on this PC only; skips excluded/unscheduled/active/done/other PCs'
    Check ((@($r.Queued | ForEach-Object { $_.name }) -join ',') -eq 'Game 10') 'reports only what Steam actually moved'
    Check ($r.Scheduled -eq 2 -and $r.Unscheduled -eq 1 -and $r.Excluded -eq 1) 'counts are right'
    Check ((Format-Result $r) -like 'Queued 1 update(s): Game 10*Unscheduled left alone*') 'result text'

    $S.QueueUnscheduledToo = $true; $S.ExcludeAppIds = @()
    $r = Invoke-QueueUpdates $S
    Check (((Get-NewQueued) -join ',') -eq '10,20,30') 'QueueUnscheduledToo queues Unscheduled too'

    $S.TestMode = $true
    $r = Invoke-QueueUpdates $S
    Check ((Get-NewQueued).Count -eq 0 -and (Format-Result $r) -like 'TEST MODE*3 update(s)*') 'TestMode queues nothing but reports'

    $S.TestMode = $false; $S.QueueUnscheduledToo = $false; $S.ExcludeAppIds = @()
    $S.DebugPort = 18082
    $r = Invoke-QueueUpdates $S
    Check ($r.Ok -and (@($r.Queued | ForEach-Object { $_.appid }) -join ',') -eq '10,20') 'older flat list format still works'

    $S.DebugPort = 18083
    $r = Invoke-QueueUpdates $S
    Check ((-not $r.Ok) -and $r.Reason -eq 'Error' -and $r.Detail -like '*did not move*') 'Steam ignoring the request is reported, not claimed as queued'

    $S.DebugPort = 18081
    Check ((Invoke-QueueUpdates $S).Reason -eq 'NotReady') 'Steam still loading -> NotReady'
    $S.DebugPort = 18099
    Check ((Invoke-QueueUpdates $S).Reason -eq 'NoPort') 'Steam without the switch -> NoPort'

    # ------------------------------------------------------------ tray logic
    Write-Host 'Tray logic'
    $script:Balloons = New-Object System.Collections.ArrayList
    function Show-Balloon([string]$Text, [string]$Kind = 'Info', [scriptblock]$OnClick = $null, [switch]$Force) {
        if (-not $Force -and -not $script:S.ShowNotifications) { return }
        $script:St.BalloonAction = $OnClick
        [void]$script:Balloons.Add("[$Kind] $Text")
    }
    $script:FakeStart = (Get-Date).AddMinutes(-1)
    function Get-SteamProcess { [pscustomobject]@{ Id = 4242; StartTime = $script:FakeStart } }
    function Get-SteamInfo { [pscustomobject]@{ Dir = 'C:\none'; Exe = 'C:\none\steam.exe'; RunningAppId = 0 } }
    function Wait-Tick {
        Invoke-TrayTick
        $until = (Get-Date).AddSeconds(60)
        while ($script:St.Work -and (Get-Date) -lt $until) { Start-Sleep -Milliseconds 300; Invoke-TrayTick }
    }

    $script:S = Get-Settings
    $script:St = @{
        State = Get-State; Settings = $script:S; Icons = @{ ok = 'ok'; paused = 'paused'; alert = 'alert' }
        Notify = [pscustomobject]@{ Icon = $null; Text = '' }
        MenuStatus = [pscustomobject]@{ Text = '' }; MenuPause = [pscustomobject]@{ Text = '' }
        Work = $null; InTick = $false; Problem = $null; LastText = $null; BalloonAction = $null
        SteamPid = 0; SteamStart = (Get-Date); RunAt = $null; NextAttempt = (Get-Date); LastRun = $null
        FixTried = $false; FailSince = $null; ErrorCount = 0; DailyDue = $false
        StartedForDaily = ''; ManualPending = $false
    }
    $St = $script:St

    Wait-Tick
    Check (((Get-NewQueued) -join ',') -eq '10') 'queues when Steam starts'
    Check ($St.Notify.Icon -eq 'ok' -and $St.Notify.Text -like '*queued 1*') 'green icon, tooltip shows result'
    Check ($St.State.LastDaily -eq (Get-Date).ToString('yyyy-MM-dd')) 'daily run marked done'
    Check ($St.Notify.Text.Length -le 63) 'tooltip fits Windows limit'

    $script:Balloons.Clear()
    Request-ManualRun; Wait-Tick
    Check (((Get-NewQueued) -join ',') -eq '10' -and $script:Balloons.Count -eq 1) 'double-click queues and notifies'

    $St.State.Paused = $true; $St.LastRun = (Get-Date).AddHours(-1)
    Invoke-TrayTick
    Check (-not $St.Work -and $St.Notify.Icon -eq 'paused' -and $St.MenuPause.Text -like 'Resume*') 'paused: no run, gray icon'
    $St.State.Paused = $false

    Set-TestSettings 18081
    $script:FakeStart = (Get-Date).AddMinutes(-20); $St.SteamPid = 0
    Wait-Tick
    $St.FailSince = (Get-Date).AddMinutes(-6); $St.NextAttempt = Get-Date
    Wait-Tick
    Check ($St.Notify.Icon -eq 'alert' -and $St.Problem -like '*Steam update*') 'Steam changed -> orange icon + alert'

    Set-TestSettings 18099
    $St.SteamPid = 0; $St.Problem = $null; $script:Balloons.Clear()
    Wait-Tick
    Check ($St.Problem -like '*without the helper switch*' -and $script:Balloons.Count -eq 1) 'missing switch on an older session -> alert, no surprise restart'

    $log = Get-Content -LiteralPath (Join-Path $work 'log.txt') -Raw
    Check ($log -notmatch '-login') 'log never contains Steam''s command line'

    # ------------------------------------------------------------ icon (Windows only)
    if ($onWindows) {
        Write-Host 'Icon'
        $bmp = New-AppBitmap 16 'alert'
        Check ($bmp.Width -eq 16 -and $bmp.GetPixel(8, 2).A -gt 0) 'draws tray bitmap'
        $ico = Join-Path $work 'test.ico'
        Save-AppIco $ico
        $loaded = New-Object System.Drawing.Icon $ico
        Check ($loaded.Width -gt 0) 'writes a valid .ico'
        $loaded.Dispose(); $bmp.Dispose()
    } else {
        Write-Host 'Icon (skipped - not Windows)'
    }

    # ------------------------------------------------------------ release build
    Write-Host 'Release build'
    & (Join-Path $repo 'tools\Build-Release.ps1') | Out-Null
    $zip = Get-ChildItem -Path (Join-Path $repo 'dist') -Filter 'SteamAutoQueue-*.zip' | Select-Object -First 1
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $z = [IO.Compression.ZipFile]::OpenRead($zip.FullName)
    $names = @($z.Entries | ForEach-Object { $_.FullName -replace '\\', '/' } | Sort-Object)
    $z.Dispose()
    Check (($names -join ',') -eq 'SteamAutoQueue/Install.cmd,SteamAutoQueue/README.txt,SteamAutoQueue/settings.ini,SteamAutoQueue/SteamAutoQueue.ps1,SteamAutoQueue/Uninstall.cmd') 'zip has exactly the 5 shipped files'
}
finally {
    foreach ($p in $servers) { try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } catch { } }
    Start-Sleep -Milliseconds 300
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($script:Failures -gt 0) { Write-Host "$script:Failures test(s) failed." -ForegroundColor Red; exit 1 }
Write-Host 'All tests passed.' -ForegroundColor Green
