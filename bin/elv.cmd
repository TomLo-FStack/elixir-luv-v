@echo off
setlocal
set "SCRIPT_DIR=%~dp0"
escript "%SCRIPT_DIR%..\libexec\elv" %*
exit /b %ERRORLEVEL%
