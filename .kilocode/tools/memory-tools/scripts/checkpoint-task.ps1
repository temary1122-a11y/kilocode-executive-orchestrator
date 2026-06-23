<#
.SYNOPSIS
Task Checkpoint Manager - saves task state before context compression.
.DESCRIPTION
Creates recovery checkpoints to prevent task loss during agent restarts.
.USAGE
.\checkpoint-task.ps1 -TaskId <id> -Checkpoint "<state_yaml>"
#>

param(
    [Parameter(Mandatory=$true)][string]$TaskId,
    [Parameter(Mandatory=$true)][string]$Checkpoint
)

. "$PSScriptRoot\common.ps1"

$memoryPath = Get-MemoryPath
$checkpointsPath = Get-CheckpointsPath
$tasksPath = Get-TasksPath
$decisionsMdPath = Get-DecisionsMdPath

# Ensure checkpoints directory exists
if (-not (Test-Path $checkpointsPath)) {
    New-Item -ItemType Directory -Path $checkpointsPath -Force | Out-Null
}

$checkpointPath = Join-Path $checkpointsPath "$TaskId.json"

$checkpointData = @{
    task_id = $TaskId
    checkpoint = $Checkpoint
    created_at = Get-Date -Format "o"
    type = "task_state"
}

Write-ExecutionTrace -TaskId $TaskId -Phase 'checkpoint' -Status 'start' -Data @{ checkpoint_type = 'task_state' } -Event 'checkpoint.start' -Actor 'checkpoint-task' | Out-Null

$checkpointData | ConvertTo-Json -Depth 10 | Set-Content $checkpointPath

# Update system state
Update-SystemState -Key "last_checkpoint" -Value $checkpointPath
Sync-SystemStateFromTasks

# Run health check
& "$PSScriptRoot\health-check.ps1"
if ($LASTEXITCODE -ne 0) {
    Write-Error "Health check failed after checkpoint"
    exit 1
}

Write-Host "Checkpoint saved for $TaskId" -ForegroundColor Green
Write-Host "Path: $checkpointPath" -ForegroundColor Gray

# Log to decisions.md
$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
$logEntry = @"
### $timestamp - Checkpoint Created

- Task: $TaskId
- State: $Checkpoint

"@

Safe-AppendToFile -Path $decisionsMdPath -Content $logEntry
Write-Host "Logged to: $decisionsMdPath" -ForegroundColor DarkGray

Write-ExecutionTrace -TaskId $TaskId -Phase 'checkpoint' -Status 'saved' -Data @{
    checkpoint_path = $checkpointPath
} | Out-Null

exit 0
