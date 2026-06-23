<#
.SYNOPSIS
Get task ID that is currently in progress
.EXAMPLE
.\get-current-task.ps1
#>

. "$PSScriptRoot\common.ps1"
$currentTask = Get-CurrentTaskRecord

if (-not $currentTask) {
    Write-Error "No task in progress"
    exit 1
}

Write-Output $currentTask.task_id
exit 0
