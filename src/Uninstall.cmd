@echo off
title Steam Auto Queue - Uninstall
set "SAQ=%LOCALAPPDATA%\SteamAutoQueue\SteamAutoQueue.ps1"
if not exist "%SAQ%" set "SAQ=%~dp0SteamAutoQueue.ps1"
copy /y "%SAQ%" "%TEMP%\SteamAutoQueue-uninstall.ps1" >nul
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%TEMP%\SteamAutoQueue-uninstall.ps1" -Mode Uninstall
del "%TEMP%\SteamAutoQueue-uninstall.ps1" >nul 2>&1
echo.
pause
