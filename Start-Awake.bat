@echo off
rem Run Awake from source (no build needed). It sits in the system tray: right-click the icon to Start/Stop.
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0awake.ps1"
