@echo off
rem Zabbix agent 2 - Intune Win32 uninstall (runs as SYSTEM). Intune runs this from the package content, so the
rem MSI is next to it and is used to uninstall: no version-specific ProductCode to maintain.
rem UNTESTED: uninstall by package path (production used the ProductCode); verify on a pilot host that detection turns false.
setlocal
set "ZBXDIR=%ProgramW6432%\Zabbix Agent 2"
set "MSI="
for %%F in ("%~dp0zabbix_agent2-*.msi") do set "MSI=%%~fF"
if not defined MSI exit /b 2

msiexec /x "%MSI%" /qn /norestart /l*v "%ProgramData%\Microsoft\IntuneManagementExtension\Logs\ZabbixAgent2-uninstall.log"
set "RC=%ERRORLEVEL%"

rem Remove what the MSI did not install: the PSK, a copied config and the agent log.
del /f /q "%ZBXDIR%\psk.key" >nul 2>&1
del /f /q "%ZBXDIR%\zabbix_agent2.conf" >nul 2>&1
del /f /q "%ZBXDIR%\zabbix_agent2.log" >nul 2>&1
rmdir "%ZBXDIR%" >nul 2>&1

rem 1605 = not installed: the goal state is reached.
if "%RC%"=="1605" exit /b 0
exit /b %RC%
