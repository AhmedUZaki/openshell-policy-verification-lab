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
for %%A in (%*) do if /i "%%~A"=="--choose-version" set "VERSIONED=1"
for %%A in (%*) do if /i "%%~A"=="--all-installed" set "VERSIONED=1"
for %%A in (%*) do if /i "%%~A"=="--all-available" set "VERSIONED=1"
for %%A in (%*) do if /i "%%~A"=="--all" set "HAS_SCOPE=1"
for %%A in (%*) do if /i "%%~A"=="--network-only" set "HAS_SCOPE=1"
for %%A in (%*) do if /i "%%~A"=="--filesystem-only" set "HAS_SCOPE=1"

where wsl >nul 2>nul
if errorlevel 1 (
  echo WSL is required. Run setup\2-install-wsl.cmd first.
  exit /b 2
)

rem Step 1 (menu runs only when no scope and no version option was given): choose the OpenShell version.
rem The version is downloaded and verified right away, BEFORE the tests are chosen in step 2.
set "VERSION_ARGS="
set "PREP_FLAGS="
if "%DRY_RUN%"=="1" set "PREP_FLAGS=--dry-run"
set "PREP_FAILED=0"
if "%HAS_SCOPE%"=="0" if "%VERSIONED%"=="0" call :ask_versions
if "%PREP_FAILED%"=="1" (
  echo.
  echo No OpenShell version was prepared ^(cancelled, or the download failed^). Nothing was run.
  if /i not "%~1"=="nopause" pause
  exit /b 2
)

rem Step 2: choose the tests to run.
if "%HAS_SCOPE%"=="0" (
  echo.
  echo Step 2: choose the tests to run:
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
  wsl -d Ubuntu-24.04 bash ./run-enforcement-audit.sh %SELECTED_SCOPE% %VERSION_ARGS% %2 %3 %4 %5 %6 %7 %8 %9
) else (
  wsl -d Ubuntu-24.04 bash ./run-enforcement-audit.sh %SELECTED_SCOPE% %VERSION_ARGS% %*
)
set "RESULT=%ERRORLEVEL%"

echo.
if "%DRY_RUN%"=="1" if "%RESULT%"=="0" echo Dry run completed: no tests were executed and no results were written.
if "%DRY_RUN%"=="0" if "%RESULT%"=="0" echo Completed: all measured expectations passed.
if "%DRY_RUN%"=="0" if "%RESULT%"=="1" echo Completed: at least one measured expectation failed. Review audit-reports\LATEST.md.
if "%DRY_RUN%"=="0" if "%RESULT%"=="2" echo Incomplete: setup, infrastructure, or inconclusive result. Review the output above.

if "%VERSIONED%"=="1" echo Per-version reports: audit-reports\by-version\ ^| comparison of two or more versions: audit-reports\COMPARISON.md
if /i not "%~1"=="nopause" pause
exit /b %RESULT%

:ask_versions
echo.
echo Step 1: choose the OpenShell version to test. It is downloaded and verified before you choose the tests.
echo   1. 0.0.116
echo   2. 0.1.9
echo   3. 0.1.10
echo   4. All: every version installed on this machine now, then compare them
echo   5. Another version: list every release available now ^(new releases appear automatically^)
choice /c 12345 /n /m "Selection [1-5]: "
if errorlevel 5 set "PREP=choose" & goto prepare_versions
if errorlevel 4 set "PREP=all" & goto prepare_versions
if errorlevel 3 set "PREP=0.1.10" & goto prepare_versions
if errorlevel 2 set "PREP=0.1.9" & goto prepare_versions
set "PREP=0.0.116"

:prepare_versions
rem "prepare" downloads and verifies the selection. It runs as a normal command (not inside "for /f") so the console input
rem reaches its prompts; it hands the result over in a small file: the versions that are ready, e.g. 0.1.10,0.1.7
set "PREP_OUT=.prepared-versions.tmp"
if exist "%PREP_OUT%" del "%PREP_OUT%"
wsl -d Ubuntu-24.04 bash ./setup/4b-install-openshell-versions.sh prepare %PREP_FLAGS% --out ./%PREP_OUT% %PREP%
set "PREPARED="
if exist "%PREP_OUT%" set /p PREPARED=<"%PREP_OUT%"
if exist "%PREP_OUT%" del "%PREP_OUT%"
if not defined PREPARED (
  set "PREP_FAILED=1"
  exit /b 1
)
echo.
echo Ready: %PREPARED%
set "VERSION_ARGS=--openshell-versions %PREPARED%"
set "VERSIONED=1"
exit /b 0
