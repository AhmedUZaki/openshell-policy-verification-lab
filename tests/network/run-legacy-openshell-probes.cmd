@echo off
REM Windows entry point for run-legacy-openshell-probes.sh.
REM this forwards into Ubuntu-24.04 and runs the real test script there.
REM It starts the OpenShell gateway if needed and creates (then deletes) one
REM sandbox; the first run may pull a container image and take several minutes.
REM Prerequisites: setup\4-install-nemoclaw.cmd done, Docker Desktop running.
REM Double-click this file, or run it from cmd/PowerShell.
REM Arguments: "dry" lists the probes and touches nothing; "nopause" skips the pause.
setlocal EnableExtensions EnableDelayedExpansion

set "DISTRO=Ubuntu-24.04"
set "DRY=0"
set "NOPAUSE=0"
for %%A in (%*) do (
  if /i "%%A"=="dry" set "DRY=1"
  if /i "%%A"=="nopause" set "NOPAUSE=1"
)
cd /d "%~dp0"

where wsl >nul 2>nul
if errorlevel 1 (
  echo WSL was not found. Run setup\2-install-wsl.cmd first.
  set "RESULT=1"
  goto :end
)
wsl -d %DISTRO% -e bash -c "exit 0" >nul 2>nul
if not "!errorlevel!"=="0" (
  echo %DISTRO% was not found or cannot run bash. Run setup\2-install-wsl.cmd first.
  set "RESULT=1"
  goto :end
)

echo Running the OpenShell phase 1 tests inside %DISTRO%...
if "!DRY!"=="1" (
  wsl -d %DISTRO% env DRY_RUN=1 bash ./run-legacy-openshell-probes.sh
) else (
  wsl -d %DISTRO% bash ./run-legacy-openshell-probes.sh
)
set "RESULT=!errorlevel!"

echo.
if "!DRY!"=="1" (
  echo Dry run finished: nothing was started or created.
  goto :end
)
if "!RESULT!"=="0" (
  echo Finished: no probe failed. The report is in tests\network\results.
) else (
  echo Finished with problems ^(exit code !RESULT!^). See the messages above and tests\network\results.
)

:end
if "!NOPAUSE!"=="0" pause
exit /b !RESULT!
