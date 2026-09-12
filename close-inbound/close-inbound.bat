@echo off
cd /d "%~dp0"
net session >nul 2>&1
if not %errorLevel%==0 (
  echo Need admin. Click Yes in the popup.
  powershell.exe -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0close-inbound.ps1"
echo.
echo Inbound closed. Outbound web ports not changed.
echo See close-inbound-result.txt
pause
