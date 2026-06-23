<#
.SYNOPSIS
Update task status in tasks.jsonl.
.DESCRIPTION
Updates task status and records a lightweight user-model completion pattern when a task completes.
.EXAMPLE
.\update-task-status.ps1 -TaskId task_123 -Status completed
#>

param(
    [Parameter(Mandatory=$true)][string]$TaskId,
    [Parameter(Mandatory=$true)][string]$Status,
    [string]$CompletedAt
)

if ($Status -notin @('pending', 'in_progress', 'completed', 'failed', 'blocked')) {
    Write-Error 'Status must be: pending, in_progress, completed, failed, or blocked'
    exit 1
}

# Support last/current for TaskId
if ($TaskId -eq 'last') {
    $TaskId = & "$PSScriptRoot\get-last-task.ps1"
} elseif ($TaskId -eq 'current') {
    $TaskId = & "$PSScriptRoot\get-current-task.ps1"
}

. "$PSScriptRoot\common.ps1"
$tasksPath = Get-TasksPath

if (-not (Test-Path $tasksPath)) {
    Write-Error "Tasks file not found: $tasksPath"
    exit 1
}

$script:updated = $false
$script:updatedTask = $null

$null = Lock-AndUpdateJsonl -Path $tasksPath -UpdateAction {
    param($tasks)
    
    for ($i = 0; $i -lt $tasks.Count; $i++) {
        if ($tasks[$i].task_id -eq $TaskId) {
            $tasks[$i].status = $Status
            if ($Status -eq 'completed') {
                if ($CompletedAt) {
                    $tasks[$i] | Add-Member -NotePropertyName completed_at -NotePropertyValue $CompletedAt -Force
                } else {
                    $tasks[$i] | Add-Member -NotePropertyName completed_at -NotePropertyValue (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssZ') -Force
                }
            }
            if ($null -eq $tasks[$i].depends_on) { $tasks[$i] | Add-Member -NotePropertyName depends_on -NotePropertyValue @() -Force }
            if ($null -eq $tasks[$i].estimated_complexity) { $tasks[$i] | Add-Member -NotePropertyName estimated_complexity -NotePropertyValue 'medium' -Force }
            $script:updated = $true
            $script:updatedTask = $tasks[$i]
        }
    }
    return $tasks
}

if (-not $script:updated) {
    Write-Error "Task $TaskId not found"
    exit 1
}

Sync-SystemStateFromTasks

if ($Status -eq 'completed') {
    Publish-Event -Type 'task.completed' -Data @{ task_id = $TaskId }
    try {
        & "$PSScriptRoot\user-profile.ps1" -Action record-task-completion `
            -TaskId $updatedTask.task_id `
            -TaskType $updatedTask.type `
            -Priority $updatedTask.priority `
            -Agent $updatedTask.assigned_agent `
            -Objective $updatedTask.objective | Out-Null
    } catch {
        Write-Log "Failed to update user profile after task completion: $_" -Level 'WARN' -Component 'update-task-status'
    }
    Write-ExecutionTrace -TaskId $TaskId -Phase 'task-status' -Status 'completed' -Data @{
        completed_at = if ($CompletedAt) { $CompletedAt } else { (Get-Date).ToString('o') }
        status = $Status
    } | Out-Null
} else {
    Publish-Event -Type 'task.updated' -Data @{ task_id = $TaskId; status = $Status }
    Write-ExecutionTrace -TaskId $TaskId -Phase 'task-status' -Status 'updated' -Data @{
        status = $Status
    } | Out-Null
}

Write-Host "Task $TaskId status updated to $Status" -ForegroundColor Green
exit 0
