@echo off
echo [*] Running WordPress Stack initializer...
set "BASE=%~dp0"
set "BASE=%BASE:~0,-1%"
powershell -ExecutionPolicy Bypass -File "%BASE%\init.ps1" -Base "%BASE%"
if %ERRORLEVEL% NEQ 0 (
    echo.
    echo [!] Init failed. See error above.
)
pause
