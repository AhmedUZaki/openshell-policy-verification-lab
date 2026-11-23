@echo off
setlocal
cd /d "%~dp0"

set "DRY_RUN=0"
set "VERSIONED=0"
set "HAS_SCOPE=0"
set "SELECTED_SCOPE="
for %%A in (%*) do if /i "%%~A"=="--dry-run" set "DRY_RUN=1"
for %%A in (%*) do if /i "%%~A"=="--compare" set "VERSIONED=1"
for %%A in (%*) do if /i "%%~A"=="--openshell-version" set "VERSIONED=1"
for %%A in (%*) do if /i "%%~A"=="--openshell-versions" set "VERSIONED=1"
for %%A in (%*) do if /i "%%~A"=="--all" set "HAS_SCOPE=1"
for %%A in (%*) do if /i "%%~A"=="--network-only" set "HAS_SCOPE=1"
for %%A in (%*) do if /i "%%~A"=="--filesystem-only" set "HAS_SCOPE=1"

where wsl >nul 2>nul
if errorlevel 1 (
  echo WSL is required. Run setup\2-install-wsl.cmd first.
  exit /b 2
)

if "%HAS_SCOPE%"=="0" (
  echo.
  echo Choose the tests to run:
  echo   1. Both network and filesystem
  echo   2. Network only
  echo   3. Filesystem only
  choice /c 123 /n /m "Selection [1-3]: "
  if errorlevel 3 goto choose_filesystem
  if errorlevel 2 goto choose_network
  set "SELECTED_SCOPE=--all"
  goto scope_selected
)
goto scope_selected

:choose_filesystem
set "SELECTED_SCOPE=--filesystem-only"
goto scope_selected

:choose_network
set "SELECTED_SCOPE=--network-only"

:scope_selected

if /i "%~1"=="nopause" (
  wsl -d Ubuntu-24.04 bash ./run-enforcement-audit.sh %SELECTED_SCOPE% %2 %3 %4 %5 %6 %7 %8 %9
) else (
  wsl -d Ubuntu-24.04 bash ./run-enforcement-audit.sh %SELECTED_SCOPE% %*
)
set "RESULT=%ERRORLEVEL%"

echo.
if "%DRY_RUN%"=="1" if "%RESULT%"=="0" echo Dry run completed: no tests were executed and no results were written.
if "%DRY_RUN%"=="0" if "%RESULT%"=="0" echo Completed: all measured expectations passed.
if "%DRY_RUN%"=="0" if "%RESULT%"=="1" echo Completed: at least one measured expectation failed. Review audit-reports\LATEST.md.
if "%DRY_RUN%"=="0" if "%RESULT%"=="2" echo Incomplete: setup, infrastructure, or inconclusive result. Review the output above.

if "%VERSIONED%"=="1" echo Per-version reports: audit-reportsy-version ^| comparison of two or more versions: audit-reportsCOMPARISON.md
if /i not "%~1"=="nopause" pause
exit /b %RESULT%
