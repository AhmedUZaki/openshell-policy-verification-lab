@echo off
setlocal
cd /d "%~dp0"
wsl -d Ubuntu-24.04 bash ./run-network-tests.sh
set "RESULT=%ERRORLEVEL%"
if not "%~1"=="nopause" pause
exit /b %RESULT%
