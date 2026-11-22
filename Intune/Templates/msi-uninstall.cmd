@echo off
rem Generic MSI uninstall for an Intune Win32 app (runs as SYSTEM). Copy as uninstall.cmd.
rem CHANGE: the ProductCode (read it with Build-Win32Package.ps1 or the steps in Win32-Packaging.md) and the log name.
rem Uninstall commands get no environment variables from Intune's command line field, but this script is a file,
rem so %ProgramData% works here.
setlocal
msiexec /x {00000000-0000-0000-0000-000000000000} /qn /norestart /l*v "%ProgramData%\Microsoft\IntuneManagementExtension\Logs\ContosoApp-uninstall.log"
set "RC=%ERRORLEVEL%"

rem Remove files the MSI did not install (secret file, copied config, logs), then the folder if empty.
rem del /f /q "%ProgramW6432%\ContosoApp\secret.key" >nul 2>&1
rem rmdir "%ProgramW6432%\ContosoApp" >nul 2>&1

rem 1605 = this product is not installed: the goal state is reached, report success.
if "%RC%"=="1605" exit /b 0
exit /b %RC%
