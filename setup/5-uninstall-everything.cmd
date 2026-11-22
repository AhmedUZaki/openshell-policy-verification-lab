@echo off
REM Removes what setup\1..4 installed, one item at a time, chosen by number.
REM Items 1-5 are done inside WSL by 5-uninstall-everything.sh (which is also
REM the macOS/Linux uninstaller). Items 6 and 7 are Windows-only and ALWAYS
REM need their own extra typed confirmation, even when you choose them.
REM Double-click this file, or run it from cmd/PowerShell.
REM Arguments: "dry" shows what would be removed and changes nothing;
REM            "nopause" skips the final pause.
setlocal EnableExtensions EnableDelayedExpansion

set "DISTRO=Ubuntu-24.04"
set "DRY=0"
set "NOPAUSE=0"
for %%A in (%*) do (
  if /i "%%A"=="dry" set "DRY=1"
  if /i "%%A"=="nopause" set "NOPAUSE=1"
)
cd /d "%~dp0"

set "D1=Docker containers, images and volumes named nemoclaw or openshell (the sandboxes)"
set "D2=The OpenShell gateway service (nemoclaw-openshell-gateway) inside %DISTRO%"
set "D3=The nemoclaw / openshell / nemohermes commands and the npm package nemoclaw inside %DISTRO%"
set "D4=The folder ~/.nemoclaw inside %DISTRO% (pinned NemoClaw source)"
set "D5=nvm and every Node.js it installed (~/.nvm) inside %DISTRO%. WARNING: other tools of yours may use it"
set "D6=Docker Desktop itself, uninstalled from Windows. Affects ALL your Docker use, not only this project"
set "D7=The whole %DISTRO% WSL distro. Deletes EVERYTHING inside it, including your own files. No undo"

echo.
echo This will DELETE things from this computer. Choose what to remove:
echo.
for %%N in (1 2 3 4 5 6 7) do echo   %%N^) !D%%N!
echo   0^) Items 1 to 5 only. Never includes 6 or 7: those must be chosen by number
echo.
set "CHOICE="
set /p "CHOICE=Numbers separated by spaces or commas (e.g. 1 3 4), or 0, anything else quits: "
set "CHOICE=!CHOICE:,= !"

set "SEL="
for %%N in (!CHOICE!) do (
  set "OK=0"
  for %%V in (0 1 2 3 4 5 6 7) do if "%%N"=="%%V" set "OK=1"
  if "!OK!"=="0" (
    echo Not a valid choice: %%N. Nothing was changed.
    goto :end
  )
  if "%%N"=="0" (set "SEL=!SEL! 1 2 3 4 5") else set "SEL=!SEL! %%N"
)
if not defined SEL (
  echo Nothing selected. Nothing was changed.
  goto :end
)

for %%N in (!SEL!) do set "S%%N=1"
set "LINUX="
for %%N in (1 2 3 4 5) do if defined S%%N set "LINUX=!LINUX! %%N"

echo.
echo You chose to DELETE:
for %%N in (1 2 3 4 5 6 7) do if defined S%%N echo   %%N^) !D%%N!
if "!DRY!"=="1" echo.
if "!DRY!"=="1" echo ^(dry run: nothing will actually be deleted^)
echo.
set "CONFIRM="
set /p "CONFIRM=This cannot be undone. Type DELETE to continue, anything else cancels: "
if not "!CONFIRM!"=="DELETE" (
  echo Cancelled. Nothing was changed.
  goto :end
)

if defined S6 (
  echo.
  echo EXTRA CONFIRMATION for item 6: Docker Desktop will be uninstalled from Windows.
  set "C6="
  set /p "C6=Type DELETE DOCKER to include it, anything else skips item 6: "
  if not "!C6!"=="DELETE DOCKER" (
    echo Skipped item 6.
    set "S6="
  )
)
if defined S7 (
  echo.
  echo EXTRA CONFIRMATION for item 7: %DISTRO% will be unregistered. Every file inside it is lost for good.
  set "C7="
  set /p "C7=Type DELETE UBUNTU to include it, anything else skips item 7: "
  if not "!C7!"=="DELETE UBUNTU" (
    echo Skipped item 7.
    set "S7="
  )
)

REM Order matters: Linux-side items first, then Docker Desktop, the distro last.
if defined LINUX (
  echo.
  echo Removing items!LINUX! inside %DISTRO%...
  wsl -d %DISTRO% -e bash -c "exit 0" >nul 2>nul
  if not "!errorlevel!"=="0" (
    echo   %DISTRO% was not found or cannot run bash; skipped items!LINUX!.
  ) else (
    set "LINUXC=!LINUX: =,!"
    set "SHARGS=--items !LINUXC! --yes"
    if "!DRY!"=="1" set "SHARGS=!SHARGS! --dry-run"
    wsl -d %DISTRO% bash ./5-uninstall-everything.sh !SHARGS!
  )
)

if defined S6 (
  echo.
  echo [6] Uninstalling Docker Desktop...
  if "!DRY!"=="1" (
    echo     [dry-run] winget uninstall --id Docker.DockerDesktop --exact
  ) else (
    taskkill /f /im "Docker Desktop.exe" >nul 2>nul
    winget uninstall --id Docker.DockerDesktop --exact
    if not "!errorlevel!"=="0" echo     winget returned !errorlevel!: Docker Desktop may already be gone, or needs an administrator terminal.
  )
)

if defined S7 (
  echo.
  echo [7] Unregistering %DISTRO%...
  if "!DRY!"=="1" (
    echo     [dry-run] wsl --unregister %DISTRO%
  ) else (
    wsl --terminate %DISTRO% >nul 2>nul
    wsl --unregister %DISTRO%
  )
)

echo.
if "!DRY!"=="1" (echo Done. ^(dry run: nothing was deleted^)) else echo Done.

:end
if "!NOPAUSE!"=="0" pause
exit /b 0
