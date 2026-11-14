@echo off
title AutoBox temporary virtual machine
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0client-vm.ps1"
pause
