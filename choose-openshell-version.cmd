@echo off
rem Windows version of choose-openshell-version.sh: the ONLY place in this lab that downloads a
rem new OpenShell version. Meant to be invoked with "call" from another .cmd in the project root
rem (run-enforcement-audit.cmd, run-tier-network-and-filesystem-checks.cmd). It is NOT a
rem standalone entry point: it has no setlocal of its own, so the variables it sets (PREPARED,
rem PREP_FAILED) are visible to the caller after the call returns.
rem
rem (Kept as a native batch menu rather than forwarding to choose-openshell-version.sh's "read -p"
rem prompt: piped/console input reaching an interactive bash prompt through wsl.exe is not
rem reliable from a plain "call" like this, whereas cmd's own "choice" is.)
rem
rem Usage (from a caller that already did "cd /d %%~dp0" to the project root):
rem   set "PREP_FLAGS=--dry-run"   (optional, before calling)
rem   call .\choose-openshell-version.cmd single   (one version only; no "All" option)
rem   call .\choose-openshell-version.cmd multi    (adds "All installed, then compare")
rem
rem On return:
rem   PREP_FAILED=1   the user cancelled, or the download/verification failed; caller should stop.
rem   PREPARED        the resolved version(s), comma-separated (e.g. "0.1.9" or "0.1.9,0.1.10").
rem                    Only "multi" mode's "All" option can produce more than one.

set "MODE=%~1"
if "%MODE%"=="" set "MODE=single"
set "PREPARED="
set "PREP_FAILED=0"

echo.
echo Which OpenShell version? It is downloaded and verified now, before anything runs.
echo   1. 0.0.116
echo   2. 0.1.9
echo   3. 0.1.10
if /i "%MODE%"=="multi" (
  echo   4. All: every version installed on this machine now, then compare them
  choice /c 1234 /n /m "Selection [1-4]: "
  if errorlevel 4 set "PREP=all" & goto prepare
  if errorlevel 3 set "PREP=0.1.10" & goto prepare
  if errorlevel 2 set "PREP=0.1.9" & goto prepare
  set "PREP=0.0.116"
) else (
  choice /c 123 /n /m "Selection [1-3]: "
  if errorlevel 3 set "PREP=0.1.10" & goto prepare
  if errorlevel 2 set "PREP=0.1.9" & goto prepare
  set "PREP=0.0.116"
)

:prepare
rem "prepare" downloads and verifies the selection. It runs as a normal command (not inside
rem "for /f") so the console input reaches its prompts; it hands the result back in a small
rem file: the versions that are ready, e.g. 0.1.10,0.1.7
set "PREP_OUT=.prepared-versions.tmp"
if exist "%PREP_OUT%" del "%PREP_OUT%"
wsl -d Ubuntu-24.04 bash ./setup/4b-install-openshell-versions.sh prepare %PREP_FLAGS% --out ./%PREP_OUT% %PREP%
if exist "%PREP_OUT%" set /p PREPARED=<"%PREP_OUT%"
if exist "%PREP_OUT%" del "%PREP_OUT%"
if not defined PREPARED (
  set "PREP_FAILED=1"
  exit /b 1
)
echo.
echo Ready: %PREPARED%
exit /b 0
