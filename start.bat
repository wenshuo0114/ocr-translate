@echo off
cd /d "%~dp0"
if not exist "%~dp0run.ps1" (
  echo Missing run.ps1
  pause
  exit /b 1
)
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0run.ps1"
if errorlevel 1 (
  echo Window failed to start.
  if exist "%~dp0last-start-error.txt" type "%~dp0last-start-error.txt"
  pause
)
