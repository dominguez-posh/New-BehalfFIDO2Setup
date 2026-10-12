@echo off
rem Startet das M365 MFA Administration Tool per Doppelklick (Windows PowerShell 5.1).
rem -ExecutionPolicy Bypass gilt nur fuer diesen Prozess und aendert keine Systemeinstellung.
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Minimized -File "%~dp0Start-M365MfaTool.ps1"
