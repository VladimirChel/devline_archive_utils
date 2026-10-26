@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Repair-LineMp4.ps1" %*
set "repairExit=%ERRORLEVEL%"
echo.
echo Exit code: %repairExit%
echo See the CSV report for per-file results.
pause
exit /b %repairExit%
