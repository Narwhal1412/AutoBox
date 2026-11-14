@echo off
title AutoBox temporary container
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0client.ps1"
pause
