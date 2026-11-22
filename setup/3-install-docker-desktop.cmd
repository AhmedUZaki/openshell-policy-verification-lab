@echo off
REM Installs Docker Desktop, if it is not already installed, and makes sure
REM it is running with WSL integration reachable from Ubuntu-24.04.
REM Windows-only: there is no .sh counterpart (on macOS, Docker Desktop is
REM installed with 'brew install --cask docker' instead).
REM Double-click this file, or run it from cmd/PowerShell.
REM An argument "nopause" skips the final pause.
setlocal EnableExtensions EnableDelayedExpansion

set "DISTRO=Ubuntu-24.04"
set "DOCKER_EXE=C:\Program Files\Docker\Docker\Docker Desktop.exe"
REM Per-user installs live under %LOCALAPPDATA% instead.
if not exist "%DOCKER_EXE%" if exist "%LOCALAPPDATA%\Programs\DockerDesktop\Docker Desktop.exe" set "DOCKER_EXE=%LOCALAPPDATA%\Programs\DockerDesktop\Docker Desktop.exe"
cd /d "%~dp0"

echo [1/4] Checking whether Docker Desktop is already installed
if exist "%DOCKER_EXE%" (
  echo       Already installed.
) else (
  echo       Not installed. Installing it with winget ^(needs internet^)...
  where winget >nul 2>nul
  if errorlevel 1 (
    echo [FAIL] winget was not found. Install Docker Desktop yourself: https://www.docker.com/products/docker-desktop
    if /i not "%~1"=="nopause" pause
    exit /b 1
  )
  winget install --id Docker.DockerDesktop --exact --accept-package-agreements --accept-source-agreements
  if not "!errorlevel!"=="0" (
    echo [FAIL] winget could not install Docker Desktop. See the message above.
    if /i not "%~1"=="nopause" pause
    exit /b 1
  )
  if not exist "%DOCKER_EXE%" (
    echo [FAIL] Docker Desktop was installed but %DOCKER_EXE% was not found. A restart may be needed; try again after one.
    if /i not "%~1"=="nopause" pause
    exit /b 1
  )
)

echo [2/4] Making sure %DISTRO% is the default WSL distro
REM Docker Desktop only auto-enables WSL integration for whichever distro
REM wsl.exe considers "default" (its own EnableIntegrationWithDefaultWslDistro
REM setting). If Docker Desktop was ALREADY running before %DISTRO% became
REM the default -- e.g. right after reinstalling WSL -- it will not notice
REM until it is quit and reopened; that case is called out below rather than
REM done automatically here.
set "DOCKER_WAS_RUNNING=0"
tasklist /FI "IMAGENAME eq Docker Desktop.exe" 2>nul | find /I "Docker Desktop.exe" >nul
if not errorlevel 1 set "DOCKER_WAS_RUNNING=1"
wsl --set-default %DISTRO% >nul 2>nul
if not "!errorlevel!"=="0" (
  echo [FAIL] Could not set %DISTRO% as the default WSL distro. Is it installed? Run: setup\2-install-wsl.cmd
  if /i not "%~1"=="nopause" pause
  exit /b 1
)

echo [3/4] Making sure Docker Desktop is running
REM A FRESH install's first-ever start is slower than any later start (it
REM sets up its backend VM from scratch), so this gives it up to 6 minutes
REM -- not the 2 minutes a normal start needs -- and prints something every
REM 10 seconds so a long wait does not look like it has frozen.
if "%DOCKER_WAS_RUNNING%"=="0" (
  echo       Starting it... first start after installing can take several minutes, and it
  echo       may ask you to accept its terms once.
  start "" "%DOCKER_EXE%"
) else (
  echo       Already running -- since it was running before %DISTRO% became the default distro,
  echo       it may not notice the change until it is quit and reopened ^(see below if this fails^).
)
set "TRIES=0"
:waitdocker
wsl -d %DISTRO% -e docker info >nul 2>nul
if "!errorlevel!"=="0" goto :ready
set /a TRIES+=1
set /a "SECS=TRIES*2"
set /a "REM5=TRIES%%5"
if "%REM5%"=="0" echo       ... still waiting ^(%SECS%s so far^)
if %TRIES% GEQ 180 (
  echo [FAIL] Docker did not become ready within 6 minutes.
  echo        Most likely cause: Docker Desktop's WSL integration is switched off, which can
  echo        happen by default on a fresh install. Open Docker Desktop itself -^> Settings -^>
  echo        Resources -^> WSL integration, and turn ON "Enable integration with my default
  echo        WSL distro" ^(or add %DISTRO% under "additional distros"^), then Apply ^& Restart.
  echo        See setup\README.md for a screenshot. Then run this file again.
  echo        If that was already on: quit Docker Desktop completely ^(right-click its tray icon
  echo        ^> Quit Docker Desktop, not just the window^), reopen it, and run this file again.
  if /i not "%~1"=="nopause" pause
  exit /b 1
)
timeout /t 2 /nobreak >nul
goto :waitdocker

:ready
echo [4/4] Confirmed: docker is reachable from inside %DISTRO%

echo.
echo DONE. Docker Desktop is installed, running, and reachable from %DISTRO%.
if /i not "%~1"=="nopause" pause
exit /b 0
