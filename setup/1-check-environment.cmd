@echo off
REM Read-only readiness check for the whole project, on Windows: WSL and
REM Docker Desktop, then everything inside WSL (1-check-environment.sh).
REM Changes nothing. Double-click this file, or run it from cmd/PowerShell.
setlocal EnableExtensions EnableDelayedExpansion

cd /d "%~dp0"
set "FAILS=0"
set "DISTRO=Ubuntu-24.04"

echo.
echo Windows
REM These next two checks are different things, even though both say "WSL":
REM   1. wsl.exe is the WSL MANAGER -- it ships with Windows itself, so this
REM      check almost always passes, even right after deleting every distro.
REM   2. A Linux DISTRO (Ubuntu-24.04) is a separate thing wsl.exe manages.
REM      Deleting it (wsl --unregister) leaves wsl.exe itself untouched, so
REM      check 1 still passes -- only check 2, which actually runs a command
REM      INSIDE a distro, can notice the distro is gone.
where wsl >nul 2>nul
if errorlevel 1 (
  echo   [FAIL] wsl.exe ^(the WSL manager built into Windows^) was not found. Run: setup\2-install-wsl.cmd
  set /a FAILS+=1
  goto :summary
)
echo   [PASS] wsl.exe ^(the WSL manager^) is present -- this does NOT mean a Linux distro is installed, see the next line

wsl -d %DISTRO% -e bash -c "exit 0" >nul 2>nul
if not "!errorlevel!"=="0" (
  echo   [FAIL] %DISTRO% was not found under wsl.exe, or cannot run bash. Run: setup\2-install-wsl.cmd
  set /a FAILS+=1
  goto :summary
)
echo   [PASS] %DISTRO% is installed under wsl.exe and runs bash

wsl -d %DISTRO% -e bash -c "uname -r | grep -qi wsl2" >nul 2>nul
if not "!errorlevel!"=="0" (
  echo   [FAIL] %DISTRO% is not WSL 2. Run: setup\2-install-wsl.cmd
  set /a FAILS+=1
) else (
  echo   [PASS] WSL 2
)

set "DOCKER_OK=0"
if exist "C:\Program Files\Docker\Docker\Docker Desktop.exe" set "DOCKER_OK=1"
if exist "%LOCALAPPDATA%\Programs\DockerDesktop\Docker Desktop.exe" set "DOCKER_OK=1"
where docker >nul 2>nul && set "DOCKER_OK=1"
if "%DOCKER_OK%"=="1" (
  echo   [PASS] Docker Desktop is installed
) else (
  echo   [FAIL] Docker Desktop was not found. Run: setup\3-install-docker-desktop.cmd
  set /a FAILS+=1
)

echo.
echo Inside WSL
wsl -d %DISTRO% bash ./1-check-environment.sh
if not "!errorlevel!"=="0" set /a FAILS+=1

:summary
echo.
if %FAILS% GTR 0 (
  echo Result: NOT ready. Fix the [FAIL] items above ^(%FAILS% problem^(s^)^).
  if /i not "%~1"=="nopause" pause
  exit /b 1
)
echo Result: ready. Install with: setup\4-install-nemoclaw.cmd
if /i not "%~1"=="nopause" pause
exit /b 0
