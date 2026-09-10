@echo off
setlocal
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0backup-desktop.ps1" %*
set ERR=%ERRORLEVEL%
if not "%NASPI_NOPAUSE%"=="1" if "%~1"=="" pause
exit /b %ERR%
