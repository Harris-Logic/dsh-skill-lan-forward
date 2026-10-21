@echo off
chcp 65001 >nul
setlocal
set "BASH=%ProgramFiles%\Git\bin\bash.exe"
if not exist "%BASH%" set "BASH=%LOCALAPPDATA%\Programs\Git\bin\bash.exe"
if not exist "%BASH%" (
  echo [ERROR] bash.exe not found. Install Git for Windows, or edit BASH in this file.
  exit /b 1
)
"%BASH%" -lc "cd \"$(cygpath -u '%~dp0')\" && ./forward.sh %*"
exit /b %ERRORLEVEL%
