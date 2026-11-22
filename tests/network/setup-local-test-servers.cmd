@echo off
setlocal EnableExtensions
cd /d "%~dp0"

wsl -d Ubuntu-24.04 bash ./setup-local-test-servers.sh
if errorlevel 1 goto :failed

echo Local HTTPS origins are ready.
set "RESULT=0"
goto :end

:failed
echo Local HTTPS origin setup failed.
set "RESULT=1"

:end
if /i not "%~1"=="nopause" pause
exit /b %RESULT%
