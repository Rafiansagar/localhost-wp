@echo off
set "BASE=%~dp0"
set "BASE=%BASE:~0,-1%"
set "VERSION=unknown"
if exist "%BASE%\VERSION" set /p VERSION=<"%BASE%\VERSION"
echo [*] Running WordPress Stack initializer v%VERSION%...
powershell -ExecutionPolicy Bypass -File "%BASE%\init.ps1" -Base "%BASE%"
if %ERRORLEVEL% NEQ 0 (
    echo.
    echo [!] Init failed. See error above.
)
pause
