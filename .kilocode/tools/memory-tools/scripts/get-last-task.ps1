<#
.SYNOPSIS
Get the last created task ID
.DESCRIPTION
Returns the task_id of the most recently created task in tasks.jsonl
.EXAMPLE
.\get-last-task.ps1
#>

. "$PSScriptRoot\common.ps1"
$lastTask = Get-LatestTaskRecord

if (-not $lastTask) {
    Write-Error "No tasks found"
    exit 1
}

Write-Output $lastTask.task_id
exit 0
