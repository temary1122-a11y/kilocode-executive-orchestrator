<#
.SYNOPSIS
Batch memory operations - executes multiple add-task, record-decision, update-task-status in one call
.PARAMETER InputFile
Path to JSON file containing array of operations
.PARAMETER InputJson
JSON string containing array of operations
.PARAMETER Quiet
Suppress human-readable output
.PARAMETER Json
Output structured JSON result
.PARAMETER NoProgress
Suppress progress indicators
.PARAMETER ContinueOnError
Continue processing after first failure
#>
param(
    [string]$InputFile = "",
    [string]$InputJson = "",
    [switch]$Quiet,
    [switch]$Json,
    [switch]$NoProgress,
    [switch]$ContinueOnError
)

$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\common.ps1"

$script:results = @()
$script:failed = $false
$script:stoppedAt = $null

function Write-FailureResult {
    param([string]$Message)
    if ($Json) {
        Write-JsonResult -Data ([ordered]@{
            ok = $false
            error = $Message
            operation = "batch"
        })
    }
    exit 1
}

function Invoke-BatchAddTask {
    param([Parameter(Mandatory=$true)][object]$Op)

    $type = $Op.type
    $priority = $Op.priority
    $objective = $Op.objective
    $agent = $Op.agent
    $parentId = $Op.parent_id
    $parallelGroup = $Op.parallel_group
    $maxAgents = $Op.max_agents
    $dependsOn = $Op.depends_on
    $estimatedComplexity = $Op.estimated_complexity

    if (-not $type -or -not $priority -or -not $objective -or -not $agent) {
        return [ordered]@{ ok = $false; error = "add-task requires type, priority, objective, agent" }
    }

    if ($type -notin @("research", "coding", "verification", "memory")) {
        return [ordered]@{ ok = $false; error = "Type must be: research, coding, verification, or memory" }
    }

    if ($priority -notin @("p0", "p1", "p2")) {
        return [ordered]@{ ok = $false; error = "Priority must be: p0, p1, or p2" }
    }

    if (-not $estimatedComplexity) { $estimatedComplexity = "medium" }

    $timestamp = Get-Date -Format "yyyyMMddHHmmss"
    $taskId = "task_$timestamp"
    $isoTime = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssZ")

    $taskRecord = [ordered]@{
        task_id = $taskId
        type = $type
        priority = $priority
        status = "pending"
        created_at = $isoTime
        assigned_agent = $agent
        objective = $objective
        estimated_complexity = $estimatedComplexity
    }

    if ($parentId) {
        $taskRecord.parent_id = $parentId
    }

    if ($parallelGroup) {
        $taskRecord.parallel_group = $parallelGroup
        $taskRecord.max_agents = if ($maxAgents -is [int]) { $maxAgents } else { 4 }
    }

    $dependsOnArray = @()
    if ($dependsOn) {
        if ($dependsOn -is [string]) {
            if ($dependsOn -match "^\[") {
                try {
                    $dependsOnArray = @($dependsOn | ConvertFrom-Json)
                } catch {
                    $dependsOnArray = @($dependsOn -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ })
                }
            } else {
                $dependsOnArray = $dependsOn -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ }
            }
        } elseif ($dependsOn -is [array]) {
            $dependsOnArray = @($dependsOn)
        }
    }
    $taskRecord.depends_on = $dependsOnArray

    $tasksPath = Get-TasksPath
    $tasksDir = Split-Path $tasksPath
    if (-not (Test-Path $tasksDir)) {
        New-Item -ItemType Directory -Path $tasksDir -Force | Out-Null
    }

    $jsonLine = $taskRecord | ConvertTo-Json -Compress -Depth 10
    try {
        $jsonLine | ConvertFrom-Json | Out-Null
        Safe-AppendToFile -Path $tasksPath -Content $jsonLine
        Publish-Event -Type 'task.created' -Data @{ task_id = $taskId; depends_on = ,@($dependsOnArray); parallel_group = $parallelGroup }
    } catch {
        return [ordered]@{ ok = $false; error = "Failed to write tasks.jsonl: $($_.Exception.Message)" }
    }

    return [ordered]@{ ok = $true; task_id = $taskId }
}

function Invoke-BatchRecordDecision {
    param([Parameter(Mandatory=$true)][object]$Op)

    $topic = $Op.topic
    $choice = $Op.choice
    $problem = $Op.problem
    $rationale = $Op.rationale
    $task = $Op.task_id
    $agent = $Op.agent
    $status = $Op.status

    if (-not $topic -or -not $choice) {
        return [ordered]@{ ok = $false; error = "record-decision requires topic and choice" }
    }

    $decisionsMdPath = Get-DecisionsMdPath
    $decisionsJsonlPath = Get-DecisionsJsonlPath

    $decisionsDir = Split-Path $decisionsMdPath
    if (-not (Test-Path $decisionsDir)) {
        New-Item -ItemType Directory -Path $decisionsDir -Force | Out-Null
    }

    if (-not (Test-Path $decisionsMdPath)) {
        "# Decisions Log" | Set-Content $decisionsMdPath
    }

    if (-not (Test-Path $decisionsJsonlPath)) {
        "" | Set-Content $decisionsJsonlPath
    }

    $date = Get-Date -Format 'yyyy-MM-dd'
    $lineSeparator = [Environment]::NewLine

    $sections = @(
        "### $date $topic",
        '',
        '**Problem:**',
        $problem,
        '',
        '**Solution:**',
        "- Chosen: $choice",
        "- Rationale: $rationale"
    )

    if ($task) {
        $sections += '', "**Task:** $task"
    }

    $decision = ($sections -join $lineSeparator)
    $decisionWithNewline = ($decision.TrimEnd() + ($lineSeparator * 2))

    try {
        Add-Content -Path $decisionsMdPath -Value $decisionWithNewline

        $record = [ordered]@{
            id = [System.Guid]::NewGuid().ToString("N").Substring(0,8)
            timestamp = (Get-Date -Format "o")
            topic = $topic
            problem = $problem
            choice = $choice
            rationale = $rationale
            task = $task
            artifacts = ,@()
        }
        if ($agent) { $record.agent = $agent }
        if ($status) { $record.status = $status }

        $record | ConvertTo-Json -Compress | Add-Content -Path $decisionsJsonlPath
    } catch {
        return [ordered]@{ ok = $false; error = "Failed to record decision: $($_.Exception.Message)" }
    }

    $decisionId = $record.id
    return [ordered]@{ ok = $true; id = $decisionId }
}

function Invoke-BatchUpdateTaskStatus {
    param([Parameter(Mandatory=$true)][object]$Op)

    $taskId = $Op.task_id
    $status = $Op.status
    $agent = $Op.agent
    $note = $Op.note
    $progress = $Op.progress

    if (-not $taskId -or -not $status) {
        return [ordered]@{ ok = $false; error = "update-task-status requires task_id and status" }
    }

    if ($taskId -eq 'last') {
        $lastTask = Get-LatestTaskRecord
        if (-not $lastTask) {
            return [ordered]@{ ok = $false; error = "No tasks found for -task_id last" }
        }
        $taskId = $lastTask.task_id
    } elseif ($taskId -eq 'current') {
        $currentTask = Get-CurrentTaskRecord
        if (-not $currentTask) {
            return [ordered]@{ ok = $false; error = "No task in progress for -task_id current" }
        }
        $taskId = $currentTask.task_id
    }

    if ($status -notin @('pending', 'in_progress', 'completed', 'failed', 'blocked')) {
        return [ordered]@{ ok = $false; error = 'Status must be: pending, in_progress, completed, failed, or blocked' }
    }

    $tasksPath = Get-TasksPath
    if (-not (Test-Path $tasksPath)) {
        return [ordered]@{ ok = $false; error = "Tasks file not found: $tasksPath" }
    }

    $script:updated = $false
    $script:updatedTask = $null

    try {
        $null = Lock-AndUpdateJsonl -Path $tasksPath -UpdateAction {
            param($tasks)

            for ($i = 0; $i -lt $tasks.Count; $i++) {
                if ($tasks[$i].task_id -eq $taskId) {
                    $tasks[$i].status = $status
                    if ($status -eq 'completed') {
                        $completedAt = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssZ')
                        if ($null -eq $tasks[$i].depends_on) { $tasks[$i] | Add-Member -NotePropertyName depends_on -NotePropertyValue @() -Force }
                        if ($null -eq $tasks[$i].estimated_complexity) { $tasks[$i] | Add-Member -NotePropertyName estimated_complexity -NotePropertyValue 'medium' -Force }
                        $tasks[$i] | Add-Member -NotePropertyName completed_at -NotePropertyValue $completedAt -Force
                    }
                    if ($agent) {
                        $tasks[$i].assigned_agent = $agent
                    }
                    if ($note) {
                        $tasks[$i] | Add-Member -NotePropertyName note -NotePropertyValue $note -Force
                    }
                    if ($progress) {
                        $tasks[$i] | Add-Member -NotePropertyName progress -NotePropertyValue $progress -Force
                    }
                    $script:updated = $true
                    $script:updatedTask = $tasks[$i]
                    break
                }
            }
            return $tasks
        }

        if (-not $script:updated) {
            return [ordered]@{ ok = $false; error = "task_not_found" }
        }
    } catch {
        return [ordered]@{ ok = $false; error = "Failed to update task: $($_.Exception.Message)" }
    }

    if ($status -eq 'completed') {
        try {
            Publish-Event -Type 'task.completed' -Data @{ task_id = $taskId }
        } catch {}
    } else {
        try {
            Publish-Event -Type 'task.updated' -Data @{ task_id = $taskId; status = $status }
        } catch {}
    }

    return [ordered]@{ ok = $true; task_id = $taskId; status = $status }
}

if (-not $InputFile -and -not $InputJson) {
    Write-FailureResult -Message "Either -InputFile or -InputJson must be provided"
}

$ops = @()
try {
    if ($InputJson) {
        $ops = $InputJson | ConvertFrom-Json
if ($ops -isnot [array]) {
    $ops = @($ops)
}
    } else {
        if (-not (Test-Path $InputFile)) {
            Write-FailureResult -Message "InputFile not found: $InputFile"
        }
        $content = Get-Content -LiteralPath $InputFile -Raw
        $ops = $content | ConvertFrom-Json
        if ($ops -isnot [array]) {
            $ops = @($ops)
        }
    }
} catch {
    Write-FailureResult -Message "Failed to parse input JSON: $_"
}

if ($null -eq $ops -or $ops.Count -eq 0) {
    Write-FailureResult -Message "Input must be a non-empty JSON array"
}

foreach ($op in $ops) {
    $index = $script:results.Count
    $opType = $op.op
    $result = [ordered]@{
        index = $index
        op = $opType
        ok = $true
    }

    $script:results += $result

    try {
        switch ($opType) {
            "add-task" {
                $r = Invoke-BatchAddTask -Op $op
                $result.ok = $r.ok
                if ($r.ok) {
                    $result.task_id = $r.task_id
                } else {
                    $result.error = $r.error
                }
            }
            "record-decision" {
                $r = Invoke-BatchRecordDecision -Op $op
                $result.ok = $r.ok
                if ($r.ok) {
                    $result.id = $r.id
                } else {
                    $result.error = $r.error
                }
            }
            "update-task-status" {
                $r = Invoke-BatchUpdateTaskStatus -Op $op
                $result.ok = $r.ok
                if ($r.ok) {
                    $result.task_id = $r.task_id
                    $result.status = $r.status
                } else {
                    $result.error = $r.error
                }
            }
            default {
                $result.ok = $false
                $result.error = "Unknown operation: $opType"
                $script:failed = $true
                if (-not $ContinueOnError) {
                    $script:stoppedAt = $index
                    break
                }
                continue
            }
        }
    } catch {
        $result.ok = $false
        $result.error = $_.Exception.Message
        $script:failed = $true
        if (-not $ContinueOnError) {
            $script:stoppedAt = $index
            break
        }
    }

    if (-not $result.ok -and -not $ContinueOnError) {
        $script:failed = $true
        $script:stoppedAt = $index
        break
    }
    if (-not $result.ok) {
        $script:failed = $true
    }
}

$succeeded = 0
$failedCount = 0
foreach ($r in $script:results) {
    if ($r.ok) { $succeeded++ } else { $failedCount++ }
}

$output = [ordered]@{
    ok = (-not $script:failed)
    operation = "batch"
    total = $script:results.Count
    succeeded = $succeeded
    failed = $failedCount
    results = @($script:results)
}

if ($script:stoppedAt -ne $null) {
    $output.stopped_at = $script:stoppedAt
}

Write-JsonResult -Data $output -Depth 10
exit 0
