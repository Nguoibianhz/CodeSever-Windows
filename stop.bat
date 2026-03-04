@echo off
setlocal
cd /d "%~dp0"

powershell -NoProfile -ExecutionPolicy Bypass -File "scripts\stop.ps1"
set "EXIT_CODE=%ERRORLEVEL%"

if not "%EXIT_CODE%"=="0" (
  echo.
  echo [WARN] stop.ps1 returned code %EXIT_CODE%.
)

endlocal
exit /b %EXIT_CODE%
