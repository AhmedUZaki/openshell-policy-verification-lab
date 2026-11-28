@echo off
setlocal
cd /d "%~dp0"

set "HAS_SCOPE=0"
for %%A in (%*) do if /i "%%~A"=="--live" set "HAS_SCOPE=1"

where wsl >nul 2>nul
if errorlevel 1 (
  echo WSL is required. Run setup\2-install-wsl.cmd first.
  exit /b 2
)

rem Choose what to run, unless --live was already given on the command line.
set "SELECTED_SCOPE="
if "%HAS_SCOPE%"=="0" (
  echo.
  echo Choose what to run:
  echo   1. Network monotonicity + filesystem invariance ^(offline, no internet^)
  echo   2. All three, including live network reachability ^(needs internet to pypi.org and wttr.in^)
  choice /c 12 /n /m "Selection [1-2]: "
  if errorlevel 2 set "SELECTED_SCOPE=--live"
)

if /i "%~1"=="nopause" (
  wsl -d Ubuntu-24.04 bash ./run-tier-network-and-filesystem-checks.sh %SELECTED_SCOPE% %2 %3 %4
) else (
  wsl -d Ubuntu-24.04 bash ./run-tier-network-and-filesystem-checks.sh %SELECTED_SCOPE% %*
)
set "RESULT=%ERRORLEVEL%"

echo.
if "%RESULT%"=="0" echo Completed: all checks that ran passed.
if "%RESULT%"=="1" echo Completed: at least one check reported a measured violation. Review the output above.
if "%RESULT%"=="2" echo Incomplete: setup or infrastructure error. Review the output above.
echo Reports: audit-reports\tier-checks\

if /i not "%~1"=="nopause" pause
exit /b %RESULT%
