@echo off
rem ===========================================================================
rem  localhost-wp Control Panel - launcher
rem  Opens the Control Panel in its own window: electron\localhost-wp.exe
rem  (portable Electron). After the first run that exe, the localhost-wp
rem  shortcut in this folder, or a taskbar pin open it directly; this bat is
rem  only needed when electron\ is missing. It is then downloaded once, in
rem  this console. If the download fails, the dashboard opens in an Edge app
rem  window instead. Nothing is installed either way.
rem ===========================================================================
if exist "%~dp0electron\localhost-wp.exe" goto run

title localhost-wp - getting the Control Panel window
echo.
echo  The Control Panel window (portable Electron) is not in this stack yet.
echo  Getting it once into %~dp0electron\
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\helper\get-electron.ps1" -Console
if exist "%~dp0electron\localhost-wp.exe" goto run

echo.
echo  Could not get Electron - opening the Control Panel in Edge instead.
timeout /t 8 >nul
goto edge

:run
start "" "%~dp0electron\localhost-wp.exe"
goto :eof

:edge
start "" powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0dashboard\server\server.ps1"
