@echo off
REM Installs WSL 2 with Ubuntu-24.04, if it is not already installed.
REM Windows-only: there is no .sh counterpart here, because installing WSL
REM is a Windows-only concept (macOS and Linux need nothing like it).
REM Double-click this file, or run it from cmd/PowerShell.
REM An argument "nopause" skips the final pause.
setlocal EnableExtensions EnableDelayedExpansion

set "DISTRO=Ubuntu-24.04"
cd /d "%~dp0"

where wsl >nul 2>nul
if errorlevel 1 (
  echo [FAIL] The 'wsl' command itself was not found. This needs Windows 10 2004+ or Windows 11.
  echo        Install it from an administrator PowerShell: wsl --install
  if /i not "%~1"=="nopause" pause
  exit /b 1
)

echo [1/3] Checking whether %DISTRO% is already installed
wsl -l -q 2>nul | findstr /i /c:"%DISTRO%" >nul
if not errorlevel 1 (
  echo       Already installed.
  goto :checkversion
)

echo       Not installed. Installing %DISTRO% ^(this needs internet, and may ask to restart^)...
echo       If a window opens asking for a Linux username and password, create one -- that
echo       account is what every script in this project will run as.
net session >nul 2>nul
if errorlevel 1 echo       NOTE: this window is not elevated. If the install fails or does nothing, re-run it from an administrator terminal ^(right-click, Run as administrator^).
wsl --install -d %DISTRO%
if not "!errorlevel!"=="0" (
  echo [FAIL] WSL install returned an error. See the message above.
  if /i not "%~1"=="nopause" pause
  exit /b 1
)
echo.
echo [DONE for now] %DISTRO% was installed. If it asked you to restart Windows, do that now.
echo Finish Ubuntu's first-run username/password setup, then run this file again to confirm it.
if /i not "%~1"=="nopause" pause
exit /b 10

:checkversion
echo [2/3] Making sure it is WSL 2 ^(not WSL 1^)
wsl --set-version %DISTRO% 2
if not "!errorlevel!"=="0" (
  echo [FAIL] Could not set %DISTRO% to WSL 2. See the message above.
  if /i not "%~1"=="nopause" pause
  exit /b 1
)

echo [3/3] Verifying it can run a command
wsl -d %DISTRO% -e bash -c "exit 0"
if not "!errorlevel!"=="0" (
  echo [FAIL] %DISTRO% cannot run bash yet. Open it from the Start menu once to finish its first-run setup, then run this file again.
  if /i not "%~1"=="nopause" pause
  exit /b 1
)

echo.
echo DONE. %DISTRO% is installed and running as WSL 2.
if /i not "%~1"=="nopause" pause
exit /b 0
