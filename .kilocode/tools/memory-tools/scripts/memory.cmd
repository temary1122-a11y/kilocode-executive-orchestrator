@echo off
REM Memory tool wrappers - call PowerShell scripts with any method
set SCRIPTSPATH=%~dp0

if "%1"=="" (
    echo Usage: memory add-task ^| update-task ^| log-decision ^| get-tasks ^| get-last-task ^| get-current-task
    exit /b 1
)

if "%1"=="add-task" (
    powershell -ExecutionPolicy Bypass -File "%SCRIPTSPATH%add-task.ps1" %*
    goto :eof
)

if "%1"=="update-task" (
    powershell -ExecutionPolicy Bypass -File "%SCRIPTSPATH%update-task-status.ps1" %*
    goto :eof
)

if "%1"=="log-decision" (
    powershell -ExecutionPolicy Bypass -File "%SCRIPTSPATH%record-decision.ps1" %*
    goto :eof
)

if "%1"=="get-tasks" (
    powershell -ExecutionPolicy Bypass -File "%SCRIPTSPATH%get-active-tasks.ps1" %*
    goto :eof
)

if "%1"=="get-last-task" (
    powershell -ExecutionPolicy Bypass -File "%SCRIPTSPATH%get-last-task.ps1" %*
    goto :eof
)

if "%1"=="get-current-task" (
    powershell -ExecutionPolicy Bypass -File "%SCRIPTSPATH%get-current-task.ps1" %*
    goto :eof
)

echo Unknown command: %1
echo Usage: memory add-task ^| update-task ^| log-decision ^| get-tasks