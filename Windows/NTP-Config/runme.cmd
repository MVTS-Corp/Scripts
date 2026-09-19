@echo off
rem
rem runme.cmd
rem 2026-09-18
rem Version: v1.1.0
rem
rem PURPOSE:
rem Double-click launcher for Configure-NtpConfig.ps1. Re-launches itself
rem elevated if not already running as Administrator (Configure-NtpConfig.ps1
rem requires elevation on its own, but fails with a plain console error
rem rather than a UAC prompt if launched from a non-elevated Explorer
rem double-click), then runs the tool from this same folder regardless of
rem whether it is on the machine PATH.
rem
rem CHANGELOG:
rem   v1.1.0 - Passes the tool's exit code back as this script's exit code,
rem            and only pauses when started with no arguments (a double-click).
rem            With arguments (a scripted call such as -TimeSource Default)
rem            it no longer waits for a keypress, so it cannot hang a caller.
rem            A calling script should still prefer running
rem            Configure-NtpConfig.ps1 directly; this launcher exists for
rem            the double-click case. Elevation does not forward arguments.

setlocal

net session >nul 2>&1
if %errorlevel% neq 0 (
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Configure-NtpConfig.ps1" %*
set "NTP_RC=%errorlevel%"
if "%~1"=="" pause
exit /b %NTP_RC%
