@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0CMP40HX-DriverToggle.ps1" -Simulation -SelfTest
set "RESULT=%ERRORLEVEL%"
echo.
if "%RESULT%"=="0" (
  echo Tat ca kiem thu mo phong da dat.
) else (
  echo Kiem thu mo phong that bai. Ma loi: %RESULT%
)
pause
exit /b %RESULT%
