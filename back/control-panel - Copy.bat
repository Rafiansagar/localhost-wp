@echo off
rem ===========================================================================
rem  localhost-wp Control Panel - launcher
rem  Starts the dashboard server (dashboard\server\server.ps1) hidden; it opens
rem  the Control Panel window itself.
rem ===========================================================================
start "" powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0dashboard\server\server.ps1"
