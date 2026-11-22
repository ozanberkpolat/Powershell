@echo off
rem Generic MSI install for an Intune Win32 app (runs as SYSTEM). Copy this file next to the MSI as install.cmd
rem and replace the three values marked CHANGE. Nothing secret belongs in this file: ship secrets as a separate
rem file in the package and lock it down as shown below.
setlocal

rem CHANGE: MSI file name, install folder (only if you place files before the MSI), log name
set "MSI=app-x64.msi"
set "APPDIR=%ProgramW6432%\ContosoApp"
set "LOG=%ProgramData%\Microsoft\IntuneManagementExtension\Logs\ContosoApp-install.log"

rem The Intune Management Extension starts this script with a 32-bit cmd: %ProgramFiles% is then
rem "Program Files (x86)". %ProgramW6432% is always the 64-bit folder.

if not exist "%~dp0%MSI%" exit /b 1

rem Optional: place a secret file BEFORE the MSI so the service finds it on first start, and lock it to
rem SYSTEM and Administrators (well-known SIDs, so it works on any language of Windows).
rem if not exist "%APPDIR%" mkdir "%APPDIR%"
rem copy /y "%~dp0secret.key" "%APPDIR%\secret.key" >nul || exit /b 1
rem icacls "%APPDIR%\secret.key" /inheritance:r /grant:r "*S-1-5-18:F" "*S-1-5-32-544:F" >nul || exit /b 1

rem CHANGE: MSI properties. Server addresses and file paths are fine here; never put a key value on this line.
msiexec /i "%~dp0%MSI%" /qn /norestart ^
  SERVER=192.0.2.10 ^
  /l*v "%LOG%"
set "RC=%ERRORLEVEL%"

rem 0 = success, 3010 = success with reboot pending (Intune applies its restart behaviour). Anything else fails.
if not "%RC%"=="0" if not "%RC%"=="3010" exit /b %RC%

rem Optional post steps, for example replace the generated config and use delayed start so the service
rem does not hit the 30 s service-control timeout at boot:
rem net stop "Contoso Service" >nul 2>&1
rem copy /y "%~dp0app.conf" "%APPDIR%\app.conf" >nul || exit /b 1
rem sc config "Contoso Service" start= delayed-auto >nul
rem net start "Contoso Service" >nul 2>&1 || exit /b 1

exit /b %RC%
