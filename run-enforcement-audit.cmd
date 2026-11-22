@echo off
setlocal
cd /d "%~dp0"

set "DRY_RUN=0"
for %%A in (%*) do if /i "%%~A"=="--dry-run" set "DRY_RUN=1"

where wsl >nul 2>nul
if errorlevel 1 (
  echo WSL is required. Run setup\2-install-wsl.cmd first.
  exit /b 2
)

if /i "%~1"=="nopause" (
  wsl -d Ubuntu-24.04 bash ./run-enforcement-audit.sh %2 %3 %4 %5 %6 %7 %8 %9
) else (
  wsl -d Ubuntu-24.04 bash ./run-enforcement-audit.sh %*
)
set "RESULT=%ERRORLEVEL%"

echo.
if "%DRY_RUN%"=="1" if "%RESULT%"=="0" echo Dry run completed: no tests were executed and no results were written.
if "%DRY_RUN%"=="0" if "%RESULT%"=="0" echo Completed: all measured expectations passed.
if "%DRY_RUN%"=="0" if "%RESULT%"=="1" echo Completed: at least one measured expectation failed. Review audit-reports\LATEST.md.
if "%DRY_RUN%"=="0" if "%RESULT%"=="2" echo Incomplete: setup, infrastructure, or inconclusive result. Review the output above.

if /i not "%~1"=="nopause" pause
exit /b %RESULT%
