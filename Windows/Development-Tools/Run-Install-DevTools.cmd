@echo off
rem ---------------------------------------------------------------------
rem Run-Install-DevTools.cmd
rem 2026-08-01
rem Version: v1.0.0
rem
rem PURPOSE:
rem One-click launcher for Install-DevTools.ps1. Self-elevates to
rem Administrator, then runs the PowerShell installer sitting next to
rem this file. Copy both files together to any folder; this file never
rem references its original location, only its own current one.
rem ---------------------------------------------------------------------

setlocal
title Development Tools Installer

net session >nul 2>&1
if not "%errorlevel%" == "0" (
    echo Administrator privileges are required. Requesting elevation...
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

set "SCRIPT_DIR=%~dp0"
set "PS1_PATH=%SCRIPT_DIR%Install-DevTools.ps1"

if not exist "%PS1_PATH%" (
    echo ERROR: Could not find Install-DevTools.ps1 next to this file.
    echo Expected it at: %PS1_PATH%
    echo Copy both Run-Install-DevTools.cmd and Install-DevTools.ps1 into the same folder.
    echo.
    pause
    exit /b 1
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS1_PATH%"
set "PS_EXIT=%errorlevel%"

echo.
if "%PS_EXIT%" == "0" (
    echo Installation completed successfully.
) else (
    echo Installation finished with errors, exit code %PS_EXIT%.
    echo Review the log file under C:\DATA\Tools\Logs for details.
)
echo.
pause

endlocal
exit /b %PS_EXIT%
