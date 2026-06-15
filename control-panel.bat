@echo off
rem ===========================================================================
rem  localhost-wp Control Panel - launcher
rem  Shows a loading message and stays open until the GUI window appears,
rem  then closes. The GUI keeps running detached.
rem ===========================================================================
title localhost-wp Control Panel
set "FLAG=%TEMP%\localhost-wp-cp.ready"
del "%FLAG%" >nul 2>&1
echo.
echo   Starting localhost-wp Control Panel...
echo   Please wait - the window will open shortly.
echo.
start "" powershell -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0scripts\control-panel.ps1"
for /L %%i in (1,1,90) do (
    if exist "%FLAG%" goto ready
    ping -n 2 127.0.0.1 >nul
)
:ready
del "%FLAG%" >nul 2>&1
exit
