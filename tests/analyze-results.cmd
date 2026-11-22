@echo off
setlocal
cd /d "%~dp0"
wsl -d Ubuntu-24.04 bash ./analyze-results.sh %*
exit /b %ERRORLEVEL%
