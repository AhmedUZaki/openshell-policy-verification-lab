@echo off
setlocal enabledelayedexpansion
cd /d "%~dp0"

set "HAS_SCOPE=0"
set "HAS_PAIRS=0"
for %%A in (%*) do if /i "%%~A"=="--live" set "HAS_SCOPE=1"
for %%A in (%*) do if /i "%%~A"=="--monotonicity-only" set "HAS_SCOPE=1"
for %%A in (%*) do if /i "%%~A"=="--invariance-only" set "HAS_SCOPE=1"
for %%A in (%*) do if /i "%%~A"=="--live-only" set "HAS_SCOPE=1"
rem "for %%A in (%*)" splits on "=" too, so --pairs=... must be detected on the whole
rem argument string instead (findstr), not by re-tokenizing %* word by word.
echo %*| findstr /C:"--pairs=" >nul
if not errorlevel 1 set "HAS_PAIRS=1"

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
  echo.
  echo   1. Network monotonicity only
  echo        Offline, no sandbox. Compares the real NemoClaw tier policy text: every
  echo        destination allowed in a narrower tier must stay allowed in a wider one.
  echo.
  echo   2. Filesystem invariance only
  echo        Real sandboxes, no internet. Reruns the F1-F4 filesystem suite under all
  echo        3 tiers and checks that the network tier changed none of its results.
  echo.
  echo   3. Live network reachability only
  echo        Real sandboxes AND live internet. Makes a real request to pypi.org and
  echo        wttr.in under each tier to prove enforcement, not just the policy text.
  echo.
  echo   4. All three together
  echo        Runs 1 and 2 always; 3 is included too ^(needs internet^).
  echo.
  choice /c 1234 /n /m "Selection [1-4]: "
  if errorlevel 4 set "SELECTED_SCOPE=--live" & goto scope_selected
  if errorlevel 3 set "SELECTED_SCOPE=--live-only" & goto scope_selected
  if errorlevel 2 set "SELECTED_SCOPE=--invariance-only" & goto scope_selected
  set "SELECTED_SCOPE=--monotonicity-only"
)
:scope_selected

rem If the live check will run, let the user pick which of its 6 real operations to run,
rem unless --pairs= was already given on the command line.
set "SELECTED_PAIRS="
set "RUNS_LIVE=0"
if "%SELECTED_SCOPE%"=="--live" set "RUNS_LIVE=1"
if "%SELECTED_SCOPE%"=="--live-only" set "RUNS_LIVE=1"
for %%A in (%*) do if /i "%%~A"=="--live" set "RUNS_LIVE=1"
for %%A in (%*) do if /i "%%~A"=="--live-only" set "RUNS_LIVE=1"
if "%RUNS_LIVE%"=="1" if "%HAS_PAIRS%"=="0" (
  echo.
  echo Live network reachability makes up to 6 real requests ^(2 destinations x 3 tiers^).
  echo Choose which to run:
  echo.
  echo   1. Restricted -^> pypi.org      ^(expected: denied^)
  echo   2. Restricted -^> wttr.in       ^(expected: denied^)
  echo   3. Balanced   -^> pypi.org      ^(expected: allowed^)
  echo   4. Balanced   -^> wttr.in       ^(expected: denied^)
  echo   5. Open       -^> pypi.org      ^(expected: allowed^)
  echo   6. Open       -^> wttr.in       ^(expected: allowed^)
  echo   7. All six
  echo.
  set "SEL="
  set /p "SEL=Enter numbers separated by commas (e.g. 1,3,5), or 7 for all: "
  if "!SEL!"=="7" (
    set "SELECTED_PAIRS=all"
  ) else (
    set "PAIRLIST=!SEL:,= !"
    set "BUILD="
    for %%N in (!PAIRLIST!) do (
      if "%%N"=="1" set "BUILD=!BUILD!restricted:pypi,"
      if "%%N"=="2" set "BUILD=!BUILD!restricted:wttr,"
      if "%%N"=="3" set "BUILD=!BUILD!balanced:pypi,"
      if "%%N"=="4" set "BUILD=!BUILD!balanced:wttr,"
      if "%%N"=="5" set "BUILD=!BUILD!open:pypi,"
      if "%%N"=="6" set "BUILD=!BUILD!open:wttr,"
    )
    if "!BUILD!"=="" (
      echo No valid selection; running all six.
      set "SELECTED_PAIRS=all"
    ) else (
      set "SELECTED_PAIRS=!BUILD!"
    )
  )
)

set "PAIRS_ARG="
if not "%SELECTED_PAIRS%"=="" set "PAIRS_ARG=--pairs=%SELECTED_PAIRS%"

rem Note for direct command-line use (not the menus above): cmd.exe splits an unquoted
rem --pairs=a:b,c:d into separate %N parameters at "=", same as it does inside "for (%*)".
rem Quote it, e.g.: run-tier-network-and-filesystem-checks.cmd nopause --live-only "--pairs=restricted:pypi"
if /i "%~1"=="nopause" (
  wsl -d Ubuntu-24.04 bash ./run-tier-network-and-filesystem-checks.sh %SELECTED_SCOPE% %PAIRS_ARG% %2 %3 %4
) else (
  wsl -d Ubuntu-24.04 bash ./run-tier-network-and-filesystem-checks.sh %SELECTED_SCOPE% %PAIRS_ARG% %*
)
set "RESULT=%ERRORLEVEL%"

echo.
if "%RESULT%"=="0" echo Completed: all checks that ran passed.
if "%RESULT%"=="1" echo Completed: at least one check reported a measured violation. Review the output above.
if "%RESULT%"=="2" echo Incomplete: setup or infrastructure error. Review the output above.
echo Reports: audit-reports\tier-checks\

if /i not "%~1"=="nopause" pause
exit /b %RESULT%
