@echo off
REM SmartData Technologies Limited - LB Test Server launcher
REM Double-click this file (Run as Administrator recommended)
set PORT=80
if not "%1"=="" set PORT=%1
echo Starting LB test server on port %PORT% ...
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0LbTestServer.ps1" -Port %PORT%
pause
