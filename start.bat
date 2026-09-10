@echo off
cd /d "%~dp0"
start "" powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0OcrTranslate.ps1"
