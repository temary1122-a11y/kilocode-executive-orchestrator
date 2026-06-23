<#
.SYNOPSIS
Add a new task to tasks.jsonl
.EXAMPLE
.\add-task.ps1 -Type coding -Priority p1 -Objective "Create auth module" -Agent coding-agent
.PARAMETER ParallelGroup
Optional parallel group name for task consolidation
.PARAMETER MaxAgents
Maximum parallel agents for this task (default: 4)
.PARAMETER DependsOn
Comma-separated list or JSON array of task_ids this task depends on
.PARAMETER EstimatedComplexity
Estimated complexity: low, medium, high (default: medium)
#>

param(
    [Parameter(Mandatory=$true)][string]$Type,
    [Parameter(Mandatory=$true)][string]$Priority,
    [Parameter(Mandatory=$true)][string]$Objective,
    [Parameter(Mandatory=$true)][string]$Agent,
    [string]$ParentId = "",
    [string]$ParallelGroup = "",
    [int]$MaxAgents = 4,
    [string]$DependsOn = "",
    [ValidateSet("low", "medium", "high")][string]$EstimatedComplexity = "medium"
)

# Validate Type
if ($Type -notin @("research", "coding", "verification", "memory")) {
    Write-Error "Type must be: research, coding, verification, or memory"
    exit 1
}

# Validate Priority
if ($Priority -notin @("p0", "p1", "p2")) {
    Write-Error "Priority must be: p0, p1, or p2"
    exit 1
}

$timestamp = Get-Date -Format "yyyyMMddHHmmss"
$taskId = "task_$timestamp"
$isoTime = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssZ")

$taskRecord = [ordered]@{
    task_id = $taskId
    type = $Type
    priority = $Priority
    status = "pending"
    created_at = $isoTime
    assigned_agent = $Agent
    objective = $Objective
    estimated_complexity = $EstimatedComplexity
}

if ($ParentId) {
    $taskRecord.parent_id = $ParentId
}

if ($ParallelGroup) {
    $taskRecord.parallel_group = $ParallelGroup
    $taskRecord.max_agents = $MaxAgents
}

# Parse DependsOn as JSON array or comma-separated list
if ($DependsOn) {
    $dependsOnArray = @()
    # Try JSON array format first
    if ($DependsOn -match "^\[") {
        try {
            $dependsOnArray = ($DependsOn | ConvertFrom-Json)
        } catch {
            Write-Log "Invalid DependsOn JSON: $_" -Level 'WARN'
        }
    } else {
        # Treat as comma-separated list
        $dependsOnArray = $DependsOn -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    }
    $taskRecord.depends_on = $dependsOnArray
} else {
    $taskRecord.depends_on = @()
}

# Use common.ps1 path functions
. "$PSScriptRoot\common.ps1"
$tasksPath = Get-TasksPath

# Ensure directory exists
$tasksDir = Split-Path $tasksPath
if (-not (Test-Path $tasksDir)) {
    New-Item -ItemType Directory -Path $tasksDir -Force | Out-Null
}

# Validate and write JSONL atomically with lock
$jsonLine = $taskRecord | ConvertTo-Json -Compress -Depth 10
try {
    $jsonLine | ConvertFrom-Json | Out-Null
    # Use lock-aware append to prevent race conditions
    Safe-AppendToFile -Path $tasksPath -Content $jsonLine
    Publish-Event -Type 'task.created' -Data @{ task_id = $taskId; depends_on = @($taskRecord.depends_on); parallel_group = $ParallelGroup }
} catch {
    Write-Error "Generated invalid JSON or failed to write tasks.jsonl: $_"
    exit 1
}

Write-Host "Task $taskId added successfully" -ForegroundColor Green

exit 0
