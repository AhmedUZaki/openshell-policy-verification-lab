@echo off
REM Windows entry point for 4-install-nemoclaw.sh. NemoClaw and OpenShell live
REM inside WSL, so this just forwards into WSL (Ubuntu) and runs the real
REM installer there. Nothing is installed by this file itself.
REM Prerequisites: WSL 2 with Ubuntu, and Docker Desktop with WSL integration
REM enabled for that distro.
REM Double-click this file, or run it from cmd/PowerShell.
REM An argument "nopause" skips the final pause.

cd /d "%~dp0"

where wsl >nul 2>nul
if errorlevel 1 (
  echo WSL was not found. Install it from an administrator PowerShell: wsl --install -d Ubuntu-24.04
  if /i not "%~1"=="nopause" pause
  exit /b 1
)

echo Installing NemoClaw (progress is printed below)...
wsl -d Ubuntu-24.04 bash ./4-install-nemoclaw.sh
set "RESULT=%ERRORLEVEL%"

echo.
if "%RESULT%"=="0" (
  echo Finished: the install step completed successfully.
) else (
  echo Finished: the install step FAILED ^(exit code %RESULT%^). See the messages above.
)
if /i not "%~1"=="nopause" pause
exit /b %RESULT%
