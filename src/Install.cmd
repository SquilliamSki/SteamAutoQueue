@echo off
title Steam Auto Queue - Install
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0SteamAutoQueue.ps1" -Mode Install
echo.
pause
