@echo off
rem Starts the M365 MFA Administration Tool by double-click (Windows PowerShell 5.1).
rem -ExecutionPolicy Bypass applies to this process only and does not change any system setting.
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Minimized -File "%~dp0Start-M365MfaTool.ps1"
