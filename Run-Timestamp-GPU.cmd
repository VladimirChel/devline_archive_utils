@echo off
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Burn-Timestamp.ps1" -Mode GPU %*
if errorlevel 1 (
  echo.
  echo Timestamp conversion failed. See the error above.
  pause
  exit /b 1
)
pause
