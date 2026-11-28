@echo off
setlocal
cd /d "%~dp0"
wsl -d Ubuntu-24.04 bash ./cleanup-filesystem-test-environment.sh
set "RESULT=%ERRORLEVEL%"
if not "%~1"=="nopause" pause
exit /b %RESULT%
