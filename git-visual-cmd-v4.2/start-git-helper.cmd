@echo off
setlocal
cd /d "%~dp0"
title Git Helper - local graph service
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0server.ps1"
if errorlevel 1 (
    echo.
    echo Git Helper stopped with an error.
    pause
)
endlocal
