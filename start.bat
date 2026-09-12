@echo off
cd /d "%~dp0"
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0OcrTranslate.ps1"
if errorlevel 1 (
  echo 窗口没打开。上面若有红字，先看那一行。
  pause
)
