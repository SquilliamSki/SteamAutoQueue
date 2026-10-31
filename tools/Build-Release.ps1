<#
    Builds the download people get from GitHub Releases:
        dist\SteamAutoQueue-<version>.zip   (one folder: SteamAutoQueue\...)

    Usage (from the repo root):
        powershell -ExecutionPolicy Bypass -File tools\Build-Release.ps1
        powershell -ExecutionPolicy Bypass -File tools\Build-Release.ps1 -Tag v1.2.0   # also checks the tag matches
#>
param([string]$Tag = '')

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$src  = Join-Path $root 'src'
$dist = Join-Path $root 'dist'

# Only these files ship. Anything else in src\ (logs, state, icons made by a
# local test install) is left out on purpose.
$files = 'Install.cmd', 'Uninstall.cmd', 'SteamAutoQueue.ps1', 'settings.ini', 'README.txt'

$script = Get-Content -LiteralPath (Join-Path $src 'SteamAutoQueue.ps1') -Raw
if ($script -notmatch "\`$AppVersion\s*=\s*'([0-9.]+)'") { throw 'Could not find $AppVersion in src\SteamAutoQueue.ps1' }
$version = $Matches[1]

if ($Tag) {
    $tagVersion = $Tag -replace '^refs/tags/', '' -replace '^[vV]', ''
    if ($tagVersion -ne $version) { throw "Tag '$Tag' does not match `$AppVersion '$version' in src\SteamAutoQueue.ps1. Bump one so they match." }
}

$stage = Join-Path $dist 'stage'
$pkg   = Join-Path $stage 'SteamAutoQueue'
if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
New-Item -ItemType Directory -Path $pkg -Force | Out-Null

foreach ($f in $files) {
    $text = [IO.File]::ReadAllText((Join-Path $src $f))
    if ($text -match '[^\x00-\x7F]') { throw "$f contains non-ASCII characters; Windows PowerShell 5.1 may misread them." }
    # Always ship Windows line endings, whatever the checkout used.
    $text = ($text -replace "`r`n", "`n") -replace "`n", "`r`n"
    [IO.File]::WriteAllText((Join-Path $pkg $f), $text, (New-Object Text.ASCIIEncoding))
}

$zip = Join-Path $dist "SteamAutoQueue-$version.zip"
if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
Compress-Archive -Path $pkg -DestinationPath $zip
Remove-Item -LiteralPath $stage -Recurse -Force

Write-Output $zip
