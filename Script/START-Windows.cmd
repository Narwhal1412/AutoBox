@echo off
title Proxmox Container Manager
rem Double-click this file. It runs proxmox_lxc.ps1 using the PowerShell that is
rem already built into Windows. -ExecutionPolicy Bypass applies to this run only.
rem You can also use it from a terminal:  START-Windows.cmd list
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0proxmox_lxc.ps1" %*
set RC=%ERRORLEVEL%
if "%~1"=="" pause
exit /b %RC%
