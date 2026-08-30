@echo off
rem ---------------------------------------------------------------------------
rem  One-click launcher for Invoke-SqlExpressBackup.ps1.
rem
rem  Double-click this file. Nothing happens to the server until a menu item is
rem  chosen, and the only item that changes anything permanently is [3] Install.
rem
rem  Elevation is requested per action rather than up front, so [1] Self test
rem  runs without an administrator prompt. The other actions need one because
rem  the sealed credential is readable only by SYSTEM and Administrators, and
rem  registering the schedule to run as SYSTEM requires it.
rem ---------------------------------------------------------------------------
setlocal EnableExtensions
title SQL Express Backup

set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
set "SCRIPT=%~dp0Invoke-SqlExpressBackup.ps1"

if not exist "%SCRIPT%" (
  echo.
  echo   Cannot find Invoke-SqlExpressBackup.ps1 next to this launcher.
  echo   Both files must sit in the same folder.
  echo.
  pause
  exit /b 1
)

if not "%~1"=="" goto :run

:menu
cls
echo.
echo   ==================================================================
echo    SQL Express Backup    -    %COMPUTERNAME%
echo   ==================================================================
echo.
echo     [1]  Self test     Prove it works here: backs up a scratch
echo                        database, checks retention, restores it,
echo                        then deletes everything it made.
echo                        No administrator prompt. Changes nothing.
echo.
echo     [F]  FULL INSTALL  One click, on this host, end to end:
echo                        make C:\SqlBackups, share it, set up against
echo                        it, schedule every 6 hours as SYSTEM, take a
echo                        backup now, then show the result.
echo                        A share on THIS host is not an offsite copy.
echo.
echo     [2]  Set up        Pick the instance, the file share and the
echo                        credential. Proves the connection, the
echo                        staging folder and the share before it
echo                        writes anything.
echo.
echo     [3]  Install       Back up every database every 6 hours as
echo                        SYSTEM, starting now and after every boot.
echo                        THIS IS THE ONE THAT MAKES IT PERMANENT.
echo.
echo     [4]  Status        What is scheduled, and what is on the share.
echo.
echo     [5]  Uninstall     Remove the schedule. Backups are not touched.
echo.
echo     [0]  Exit
echo.
set "CHOICE="
set /p "CHOICE=   Choose: "
if "%CHOICE%"=="1" (
  call :selftest
  goto :menu
)
if /i "%CHOICE%"=="F" (
  call :elevate fullinstall
  goto :menu
)
if "%CHOICE%"=="2" (
  call :elevate setup
  goto :menu
)
if "%CHOICE%"=="3" (
  call :elevate install
  goto :menu
)
if "%CHOICE%"=="4" (
  call :elevate status
  goto :menu
)
if "%CHOICE%"=="5" (
  call :elevate uninstall
  goto :menu
)
if "%CHOICE%"=="0" exit /b 0
goto :menu

:selftest
echo.
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -SelfTest
echo.
pause
goto :eof

:elevate
rem Re-launch this same launcher elevated, carrying the chosen action. UAC will
rem ask for an administrator - on a tiered-admin domain that is a DIFFERENT
rem account from the one signed in, and that is expected.
"%PS%" -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -ArgumentList '%1' -Verb RunAs"
goto :eof

rem --- the elevated copy re-enters here with the action as argument 1 ---------
:run
if /i "%~1"=="selftest"  goto :act_selftest
if /i "%~1"=="fullinstall" goto :act_fullinstall
if /i "%~1"=="setup"     goto :act_setup
if /i "%~1"=="install"   goto :act_install
if /i "%~1"=="status"    goto :act_status
if /i "%~1"=="uninstall" goto :act_uninstall
echo   Unknown action "%~1". Valid: selftest fullinstall setup install status uninstall
pause
exit /b 1

:act_selftest
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -SelfTest
echo.
pause
exit /b %ERRORLEVEL%

:act_fullinstall
echo.
echo   ==================================================================
echo    FULL INSTALL
echo   ==================================================================
echo.
echo   This will, on %COMPUTERNAME%:
echo     1. create C:\SqlBackups and share it as \\%COMPUTERNAME%\SqlBackups
echo     2. set up against that share using Windows authentication
echo     3. register a scheduled task: EVERY database, every 6 hours, as SYSTEM
echo     4. take one backup immediately
echo     5. show the result
echo.
echo   EVERY database on the instance is included, production ones too.
echo   A share on THIS host is not an offsite copy - if this disk dies the
echo   backups die with it. Re-run Set up against a real file server later.
echo.
set "GO="
set /p "GO=   Type YES to continue: "
if /i not "%GO%"=="YES" (
  echo.
  echo   Not installed. Nothing was changed.
  pause
  exit /b 1
)
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -FullInstall
echo.
pause
exit /b %ERRORLEVEL%

:act_setup
echo.
echo   ==================================================================
echo    Set up
echo   ==================================================================
echo.
echo   Backups are copied to a file share, for example:
echo       \\fileserver\sqlbackups
echo.
echo   The account the backup runs as (SYSTEM, which on the network is the
echo   machine account DOMAIN\%COMPUTERNAME%$) must be able to write there.
echo.
set "SHARE="
set /p "SHARE=   Share path: "
if "%SHARE%"=="" (
  echo.
  echo   No share path given. Nothing was changed.
  pause
  exit /b 1
)
echo.
echo   Windows authentication stores NO password - the scheduled task connects
echo   as SYSTEM. Choose it unless the instance refuses Windows logins.
echo.
echo   A SQL login is sealed to this machine instead. Prefer a login holding
echo   only dbcreator and db_backupoperator over sa.
echo.
set "AUTH="
set /p "AUTH=   Use Windows authentication? [Y/n]: "
if /i "%AUTH%"=="n" goto :setup_sql
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -Setup -SharePath "%SHARE%" -UseWindowsAuth
echo.
pause
exit /b %ERRORLEVEL%

:setup_sql
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -Setup -SharePath "%SHARE%"
echo.
pause
exit /b %ERRORLEVEL%

:act_install
echo.
echo   This registers a scheduled task that backs up EVERY database on the
echo   instance every 6 hours, as SYSTEM, starting now and after every boot.
echo.
set "GO="
set /p "GO=   Type YES to continue: "
if /i not "%GO%"=="YES" (
  echo.
  echo   Not installed. Nothing was changed.
  pause
  exit /b 1
)
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -Install -As Task
echo.
pause
exit /b %ERRORLEVEL%

:act_status
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -Status
echo.
pause
exit /b %ERRORLEVEL%

:act_uninstall
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -Uninstall
echo.
pause
exit /b %ERRORLEVEL%
