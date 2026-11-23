@echo off
REM Windows entry point for 4b-install-openshell-versions.sh. OpenShell lives
REM inside WSL, so this forwards into WSL (Ubuntu) and runs the real script.
REM Nothing is installed by this file itself.
REM
REM Examples:
REM   4b-install-openshell-versions.cmd                      downloads 0.0.116 and 0.1.9
REM   4b-install-openshell-versions.cmd install 0.1.5 0.1.9  downloads the versions you list
REM   4b-install-openshell-versions.cmd use 0.1.9            makes 0.1.9 the active version
REM   4b-install-openshell-versions.cmd list                 shows stored versions
REM Add "nopause" as the LAST argument to skip the final pause.

cd /d "%~dp0"

where wsl >nul 2>nul
if errorlevel 1 (
  echo WSL was not found. Install it from an administrator PowerShell: wsl --install -d Ubuntu-24.04
  pause
  exit /b 1
)

set "NOPAUSE=0"
set "ARGS=%*"
if /i "%~1"=="nopause" (
  set "NOPAUSE=1"
  set "ARGS="
)
for %%A in (%*) do if /i "%%~A"=="nopause" set "NOPAUSE=1"
if "%ARGS%"=="" goto run
set "ARGS=%ARGS: nopause=%"

:run
wsl -d Ubuntu-24.04 bash ./4b-install-openshell-versions.sh %ARGS%
set "RESULT=%ERRORLEVEL%"

echo.
if "%RESULT%"=="0" (
  echo Finished successfully.
) else (
  echo Finished with errors ^(exit code %RESULT%^). See the messages above.
)
if "%NOPAUSE%"=="0" pause
exit /b %RESULT%
