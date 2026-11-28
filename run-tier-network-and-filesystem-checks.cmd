@echo off
setlocal
cd /d "%~dp0"

where wsl >nul 2>nul
if errorlevel 1 (
  echo WSL is required. Run setup\2-install-wsl.cmd first.
  exit /b 2
)

if /i "%~1"=="nopause" (
  wsl -d Ubuntu-24.04 bash ./run-tier-network-and-filesystem-checks.sh %2 %3 %4
) else (
  wsl -d Ubuntu-24.04 bash ./run-tier-network-and-filesystem-checks.sh %*
)
set "RESULT=%ERRORLEVEL%"

echo.
if "%RESULT%"=="0" echo Completed: all checks that ran passed.
if "%RESULT%"=="1" echo Completed: at least one check reported a measured violation. Review the output above.
if "%RESULT%"=="2" echo Incomplete: setup or infrastructure error. Review the output above.
echo Reports: audit-reports\tier-checks\

if /i not "%~1"=="nopause" pause
exit /b %RESULT%
