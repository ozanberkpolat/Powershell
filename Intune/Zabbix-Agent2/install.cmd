@echo off
rem Zabbix agent 2 - Intune Win32 install (runs as SYSTEM). Package content: this file, uninstall.cmd,
rem the Zabbix agent 2 MSI (zabbix_agent2-<version>-windows-amd64-openssl.msi), psk.key and, optionally,
rem zabbix_agent2.conf (a full config that replaces the one the MSI writes).
rem
rem Intune install command:   install.cmd <server> <psk-identity> [host-metadata]
rem   server         Zabbix server or proxy address(es) for Server/ServerActive, for example 192.0.2.10
rem   psk-identity   TLSPSKIdentity configured for this PSK on the Zabbix side (not secret, but not the key)
rem   host-metadata  optional HostMetadata for auto-registration, default AVD
rem UNTESTED: this parameterised variant (the production package had the values inline); test once on a pilot host.
rem The PSK value itself is NEVER on a command line: it ships as psk.key and is locked to SYSTEM and Administrators.
setlocal

if "%~1"=="" exit /b 87
if "%~2"=="" exit /b 87
set "ZBXSERVER=%~1"
set "ZBXPSKID=%~2"
set "ZBXMETA=%~3"
if "%ZBXMETA%"=="" set "ZBXMETA=AVD"

rem The Intune Management Extension starts .cmd files with a 32-bit cmd: %ProgramFiles% is then
rem "Program Files (x86)". %ProgramW6432% is always the 64-bit folder, where the amd64 MSI installs.
set "ZBXDIR=%ProgramW6432%\Zabbix Agent 2"
set "LOG=%ProgramData%\Microsoft\IntuneManagementExtension\Logs\ZabbixAgent2-install.log"

set "MSI="
for %%F in ("%~dp0zabbix_agent2-*.msi") do set "MSI=%%~fF"
if not defined MSI exit /b 2
if not exist "%~dp0psk.key" exit /b 2

rem Place the PSK BEFORE the MSI so the service finds it on its first start. Well-known SIDs (SYSTEM, Administrators)
rem work on every Windows display language.
if not exist "%ZBXDIR%" mkdir "%ZBXDIR%"
copy /y "%~dp0psk.key" "%ZBXDIR%\psk.key" >nul || exit /b 1
icacls "%ZBXDIR%\psk.key" /inheritance:r /grant:r "*S-1-5-18:F" "*S-1-5-32-544:F" >nul || exit /b 1

rem The same values go in as MSI properties so the config the MSI writes is consistent. No Hostname is set:
rem the agent then uses the computer name, which is what pooled AVD session hosts need.
msiexec /i "%MSI%" /qn /norestart ^
  SERVER="%ZBXSERVER%" SERVERACTIVE="%ZBXSERVER%" LISTENPORT=10050 ^
  TLSCONNECT=psk TLSACCEPT=psk TLSPSKIDENTITY="%ZBXPSKID%" TLSPSKFILE="%ZBXDIR%\psk.key" ^
  HOSTMETADATA="%ZBXMETA%" ENABLEPATH=1 ^
  /l*v "%LOG%"
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" if not "%RC%"=="3010" exit /b %RC%

net stop "Zabbix Agent 2" >nul 2>&1
if exist "%~dp0zabbix_agent2.conf" (
  copy /y "%~dp0zabbix_agent2.conf" "%ZBXDIR%\zabbix_agent2.conf" >nul || exit /b 1
)
rem Delayed start: on busy hosts the service otherwise hit the 30 s service-control timeout at boot (event 7009)
rem and stayed stopped, which reads as "agent not available" in Zabbix.
sc config "Zabbix Agent 2" start= delayed-auto >nul
net start "Zabbix Agent 2" >nul 2>&1 || exit /b 1

exit /b %RC%
