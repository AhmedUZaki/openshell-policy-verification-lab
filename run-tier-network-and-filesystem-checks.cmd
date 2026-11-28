@echo off
setlocal
cd /d "%~dp0"

set "HAS_SCOPE=0"
for %%A in (%*) do if /i "%%~A"=="--live" set "HAS_SCOPE=1"
for %%A in (%*) do if /i "%%~A"=="--monotonicity-only" set "HAS_SCOPE=1"
for %%A in (%*) do if /i "%%~A"=="--invariance-only" set "HAS_SCOPE=1"
for %%A in (%*) do if /i "%%~A"=="--live-only" set "HAS_SCOPE=1"

where wsl >nul 2>nul
if errorlevel 1 (
  echo WSL is required. Run setup\2-install-wsl.cmd first.
  exit /b 2
)

rem Choose what to run, unless a scope flag was already given on the command line.
set "SELECTED_SCOPE="
if "%HAS_SCOPE%"=="0" (
  echo.
  echo Choose what to run:
  echo   1. Network monotonicity only ^(offline, no sandbox: compares the real NemoClaw tier
  echo      policy text so every destination allowed in a narrower tier stays allowed in a wider one^)
  echo   2. Filesystem invariance only ^(real sandboxes, no internet: reruns the F1-F4 filesystem
  echo      suite under all 3 tiers and checks the network tier changed none of its results^)
  echo   3. Live network reachability only ^(real sandboxes + live internet: makes a real request
  echo      to pypi.org and wttr.in under each tier to prove enforcement, not just the policy text^)
  echo   4. All three together ^(1 and 2 always; 3 needs internet to pypi.org and wttr.in^)
  choice /c 1234 /n /m "Selection [1-4]: "
  if errorlevel 4 set "SELECTED_SCOPE=--live" & goto scope_selected
  if errorlevel 3 set "SELECTED_SCOPE=--live-only" & goto scope_selected
  if errorlevel 2 set "SELECTED_SCOPE=--invariance-only" & goto scope_selected
  set "SELECTED_SCOPE=--monotonicity-only"
)
:scope_selected

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
