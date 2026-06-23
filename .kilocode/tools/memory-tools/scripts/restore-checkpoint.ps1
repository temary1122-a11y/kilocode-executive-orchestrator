<#
.SYNOPSIS
Restore a task from a checkpoint file.
.DESCRIPTION
Reads a JSON checkpoint from memory/checkpoints and re-applies the state
to the task in tasks.jsonl.
#>

param(
    [Parameter(Mandatory=$true)][string]$TaskId,
    [string]$CheckpointId
)

. "$PSScriptRoot\common.ps1"

$memoryPath = Get-MemoryPath
$checkpointsPath = Get-CheckpointsPath
$tasksPath = Get-TasksPath

if (-not $CheckpointId) {
    # Pick the latest checkpoint for the task
    $files = Get-ChildItem -Path $checkpointsPath -Filter "$TaskId*.json" | Sort-Object LastWriteTime -Descending
    if ($files.Count -eq 0) {
        Write-Error "No checkpoints found for task $TaskId"
        exit 1
    }
    $CheckpointFile = $files[0].FullName
} else {
    # Look for specific checkpoint pattern
    $checkpointPattern = "$TaskId-$CheckpointId.json"
    $CheckpointFile = Join-Path $checkpointsPath $checkpointPattern
    if (-not (Test-Path $CheckpointFile)) {
        # Try direct task_id.json pattern
        $CheckpointFile = Join-Path $checkpointsPath "$TaskId.json"
        if (-not (Test-Path $CheckpointFile)) {
            Write-Error "Checkpoint $CheckpointFile does not exist"
            exit 1
        }
    }
}

# Read checkpoint data
try {
    $checkpoint = Get-Content $CheckpointFile -Raw | ConvertFrom-Json
} catch {
    Write-Error "Failed to read checkpoint: $_"
    exit 1
}

# Read tasks
try {
    $tasksRaw = Get-Content $tasksPath | Where-Object { $_ -and $_.Trim() }
    $tasks = @()
    foreach ($line in $tasksRaw) {
        $tasks += $line.Trim() | ConvertFrom-Json
    }
} catch {
    Write-Error "Failed to read tasks.jsonl: $_"
    exit 1
}

# Find task index
$taskIndex = -1
for ($i = 0; $i -lt $tasks.Count; $i++) {
    if ($tasks[$i].task_id -eq $TaskId) { $taskIndex = $i; break }
}

if ($taskIndex -eq -1) {
    Write-Log "Task $TaskId not found in tasks.jsonl" -Level 'ERROR'
    exit 1
}

# Update task properties (with -Force to overwrite)
foreach ($prop in $checkpoint.PSObject.Properties) {
    if ($prop.Name -ne 'task_id') {  # task_id shouldn't change
        $tasks[$taskIndex] | Add-Member -MemberType NoteProperty -Name $prop.Name -Value $prop.Value -Force
    }
}

# Write back as JSONL
$tasks | ForEach-Object { $_ | ConvertTo-Json -Compress } | Set-Content $tasksPath

# Update system state
Update-SystemState -Key "current_task" -Value $TaskId
Update-SystemState -Key "last_checkpoint" -Value $CheckpointFile
Sync-SystemStateFromTasks

# Run health check
& "$PSScriptRoot\health-check.ps1"
if ($LASTEXITCODE -ne 0) {
    Write-Error "Health check failed after restore"
    exit 1
}

Write-Host "Checkpoint restored for task $TaskId" -ForegroundColor Green
Write-Host "File: $CheckpointFile" -ForegroundColor Gray
Write-ExecutionTrace -TaskId $TaskId -Phase 'checkpoint' -Status 'restored' -Data @{
    checkpoint_path = $CheckpointFile
} | Out-Null
exit 0
