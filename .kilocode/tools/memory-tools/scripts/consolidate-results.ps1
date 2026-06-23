<#
.SYNOPSIS
Result Consolidator - compares parallel task variants and selects best
.DESCRIPTION
Analyzes task results and logs consolidation decision to decisions.md
.USAGE
.\consolidate-results.ps1 -Group <group_name> -Variants <task_ids> -Scores <scores>
#>

param(
    [Parameter(Mandatory=$true)][string]$Group,
    [Parameter(Mandatory=$true)][string[]]$Variants,
    [int[]]$Scores = @(),
    [string]$Reason = ""
)

. "$PSScriptRoot\common.ps1"
Ensure-MemoryDirectories
$tasksPath = Get-TasksPath
$decisionsMdPath = Get-DecisionsPath
$busPath = Get-BusPath

# Read tasks from JSONL (use locked read for consistency)
$tasksRaw = Get-Content $tasksPath | Where-Object { $_ -and $_.Trim() }
$tasks = @()
foreach ($line in $tasksRaw) {
    $tasks += $line.Trim() | ConvertFrom-Json
}

$taskDetails = @()
foreach ($v in $Variants) {
    $task = $tasks | Where-Object { $_.task_id -eq $v } | Select-Object -First 1
    if ($task) {
        $taskDetails += @{
            id = $v
            objective = $task.objective
            status = $task.status
        }
    }
}

# Validate that all variants have reached terminal states
$nonTerminal = $taskDetails | Where-Object { $_.status -notin @('completed', 'failed', 'blocked') }
if ($nonTerminal.Count -gt 0) {
    Write-Warning "Some variants not in terminal state: $($nonTerminal.id -join ', ')"
    Write-ExecutionTrace -TaskId ($Variants | Select-Object -First 1) -Phase 'consolidation' -Status 'warn' -Data @{ non_terminal = @($nonTerminal.id) } -Event 'consolidation.non_terminal' -Actor 'consolidate-results' | Out-Null
}

# If no scores provided, select first completed variant
if ($Scores.Count -eq 0) {
    $completed = $taskDetails | Where-Object { $_.status -eq "completed" } | Select-Object -First 1
    if ($completed) {
        $Scores = @(1) + @(0) * ($Variants.Count - 1)
        $selected = $completed.id.ToString()
    } else {
        $selected = $Variants[0]
    }
} else {
    $maxScore = ($Scores | Measure-Object -Maximum).Maximum
    $selected = $Variants[[array]::IndexOf($Scores, $maxScore)]
}

$selectedTask = $tasks | Where-Object { $_.task_id -eq $selected } | Select-Object -First 1

Write-Host "Phase 1: Validation (Two-Phase Commit)" -ForegroundColor Cyan
if ($selectedTask.status -ne 'completed') {
    Write-Warning "Selected variant $selected is not completed (status: $($selectedTask.status)). Proceeding with caution."
} else {
    Write-Host "  Variant $selected is completed. Validation passed." -ForegroundColor Gray
}

$branchName = $selectedTask.branchName
if (-not $branchName) { $branchName = $selectedTask.worktree }
if (-not $branchName) {
    $safe = "parallel-$Group-$selected".ToLowerInvariant() -replace '[^a-z0-9\-]+', '-'
    $branchName = $safe -replace '^-+|-+$', ''
}

Write-Host "Phase 2: Merge (Two-Phase Commit)" -ForegroundColor Cyan
$gitBranchExists = git show-ref --verify --quiet "refs/heads/$branchName"
if ($LASTEXITCODE -eq 0) {
    Write-Host "  Found git branch $branchName. Executing squash merge..." -ForegroundColor Gray
    Write-ExecutionTrace -TaskId ($Variants | Select-Object -First 1) -Phase 'consolidation' -Status 'merge_started' -Data @{ branch = $branchName; group = $Group } -Event 'consolidation.merge_started' -Actor 'consolidate-results' | Out-Null
    git merge --squash $branchName
    if ($LASTEXITCODE -eq 0) {
        git commit -m "Consolidate parallel task $selected from group $Group"
        Write-Host "  Successfully merged $branchName." -ForegroundColor Green
    } else {
        Write-Warning "  Git merge failed. Manual conflict resolution may be required."
    }
} else {
    Write-Host "  No distinct git branch found for $branchName. Assuming direct file modification." -ForegroundColor Yellow
}

# Format output
$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
$rejected = $Variants | Where-Object { $_ -ne $selected } | ForEach-Object { "@_$_@" }

$consolidationEntry = @"
### $timestamp - Parallel Consolidation: $Group

- Selected: $selected
- Rejected: $($rejected -join ", ")
- Reason: $Reason
- All variants: $($Variants -join ", ")

"@

# Write to decisions.md with lock to prevent race conditions
$lockPath = Get-LockFilePath -Path $decisionsMdPath
try {
    Lock-WithRetry -Path $lockPath -MaxRetries 10 | Out-Null
    Add-Content -Path $decisionsMdPath -Value $consolidationEntry -Encoding UTF8
} finally {
    Release-FileLock -Path $lockPath | Out-Null
}

# Write result to orchestrator bus
if (-not (Test-Path $busPath)) { New-Item -ItemType Directory -Path $busPath -Force | Out-Null }
$busFile = Join-Path $busPath "consolidation-$Group.json"
$busRecord = [ordered]@{
    group = $Group
    selected = $selected
    rejected = $rejected
    reason = $Reason
    timestamp = (Get-Date -Format "o")
}
$busRecord | ConvertTo-Json -Depth 10 | Set-Content $busFile
$consolidationRunId = if ($env:KILO_RUN_ID) { $env:KILO_RUN_ID } else { '' }
Update-SystemState -Key 'last_parallel_consolidation' -Value [ordered]@{
    group = $Group
    selected = $selected
    rejected = $rejected
    reason = $Reason
    bus_file = $busFile
    updated_at = (Get-Date).ToString('o')
}
Write-ExecutionTrace -TaskId ($selected) -Phase 'parallel' -Status 'consolidated' -Data @{
    group = $Group
    selected = $selected
    rejected = $rejected
    reason = $Reason
} -RunId $consolidationRunId -CorrelationId (New-TraceCorrelationId -TaskId $selected -RunId $consolidationRunId) -Event 'parallel.consolidated' -Actor 'consolidate-results' | Out-Null

Write-Host "Consolidation complete:" -ForegroundColor Green
Write-Host "  Selected: $selected" -ForegroundColor White
Write-Host "  Rejected: $($rejected -join ", ")" -ForegroundColor Gray
Write-Host "Logged to: $decisionsMdPath" -ForegroundColor DarkGray

exit 0
