<#
.SYNOPSIS
Batch memory operations - executes multiple add-task, record-decision, update-task-status in one call.
.PARAMETER Operations
JSON string representing an array of operations. Each operation object must have:
  - type: add-task | update-task-status | record-decision
  - For add-task: task_type, priority, objective, agent (and optional: parent_id, parallel_group, max_agents, depends_on, estimated_complexity)
  - For update-task-status: task_id, status (and optional: agent, note, progress)
  - For record-decision: topic, choice (and optional: problem, rationale, task_id, agent, status)
.EXAMPLE
.\batch-memory.ps1 '[{"type":"add-task","task_type":"coding","priority":"p1","objective":"Test task","agent":"coding-agent"}]'
#>
param(
    [Parameter(Mandatory=$true, Position=0)]
    [string]$Operations,
    [switch]$Quiet,
    [switch]$Json,
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

function Convert-ToSwitchValue {
    param($Value)
    if ($Value -is [bool]) { return $Value }
    if ($Value -is [int]) { return $Value }
    if ($Value -is [string]) { return $Value }
    return $Value
}

function Invoke-BatchOperation {
    param([Parameter(Mandatory=$true)][object]$Op)

    $opType = $Op.type

    if (-not $opType) {
        return [ordered]@{ ok = $false; error = "Operation type is required" }
    }

    $arguments = @()

    switch ($opType) {
        "add-task" {
            $taskType = $Op.task_type
            $priority = $Op.priority
            $objective = $Op.objective
            $agent = $Op.agent
            $parentId = $Op.parent_id
            $parallelGroup = $Op.parallel_group
            $maxAgents = $Op.max_agents
            $dependsOn = $Op.depends_on
            $estimatedComplexity = $Op.estimated_complexity

            if (-not $taskType -or -not $priority -or -not $objective -or -not $agent) {
                return [ordered]@{ ok = $false; error = "add-task requires task_type, priority, objective, agent" }
            }

            if ($taskType -notin @("research", "coding", "verification", "memory")) {
                return [ordered]@{ ok = $false; error = "Task type must be: research, coding, verification, or memory" }
            }

            if ($priority -notin @("p0", "p1", "p2")) {
                return [ordered]@{ ok = $false; error = "Priority must be: p0, p1, or p2" }
            }

            $arguments = @(
                '-Type', $taskType,
                '-Priority', $priority,
                '-Objective', $objective,
                '-Agent', $agent
            )

            if ($parentId) { $arguments += '-ParentId', $parentId }
            if ($parallelGroup) { $arguments += '-ParallelGroup', $parallelGroup }
            if ($maxAgents -and $maxAgents -is [int]) { $arguments += '-MaxAgents', $maxAgents }
            elseif ($parallelGroup) { $arguments += '-MaxAgents', 4 }

            if ($dependsOn) {
                if ($dependsOn -is [array]) {
                    $arguments += '-DependsOn', ($dependsOn | ConvertTo-Json -Compress)
                } else {
                    $arguments += '-DependsOn', $dependsOn
                }
            }

            if ($estimatedComplexity) { $arguments += '-EstimatedComplexity', $estimatedComplexity }

            $arguments += '-Json'
        }

        "record-decision" {
            $topic = $Op.topic
            $choice = $Op.choice
            $problem = $Op.problem
            $rationale = $Op.rationale
            $task = $Op.task_id
            $agent = $Op.agent
            $artifacts = $Op.artifacts
            $status = $Op.status

            if (-not $topic -or -not $choice) {
                return [ordered]@{ ok = $false; error = "record-decision requires topic and choice" }
            }

            $arguments = @(
                '-Topic', $topic,
                '-Choice', $choice
            )

            if ($problem) { $arguments += '-Problem', $problem }
            if ($rationale) { $arguments += '-Rationale', $rationale }
            if ($task) { $arguments += '-Task', $task }
            if ($agent) { $arguments += '-Agent', $agent }
            if ($artifacts -and $artifacts -is [array]) { $arguments += '-Artifacts', ($artifacts | ConvertTo-Json -Compress) }
            if ($status) { $arguments += '-Status', $status }

            $arguments += '-Json'
        }

        "update-task-status" {
            $taskId = $Op.task_id
            $status = $Op.status
            $agent = $Op.agent
            $note = $Op.note
            $progress = $Op.progress

            if (-not $taskId -or -not $status) {
                return [ordered]@{ ok = $false; error = "update-task-status requires task_id and status" }
            }

            if ($status -notin @('pending', 'in_progress', 'completed', 'failed', 'blocked')) {
                return [ordered]@{ ok = $false; error = 'Status must be: pending, in_progress, completed, failed, or blocked' }
            }

            $arguments = @(
                '-TaskId', $taskId,
                '-Status', $status
            )

            if ($agent) { $arguments += '-Agent', $agent }
            if ($note) { $arguments += '-Note', $note }
            if ($progress) { $arguments += '-Progress', $progress }

            $arguments += '-Json'
        }

        default {
            return [ordered]@{ ok = $false; error = "Unknown operation type: $opType" }
        }
    }

    try {
        $scriptPath = Join-Path $PSScriptRoot ("{0}.ps1" -f $opType)
        if (-not (Test-Path $scriptPath)) {
            return [ordered]@{ ok = $false; error = "Script not found for operation type: $opType" }
        }

        $ProgressPreference = 'SilentlyContinue'
        $output = & $scriptPath @arguments 2>&1

        if ($output -is [string]) {
            try {
                $result = $output | ConvertFrom-Json
                return $result
            } catch {
                return [ordered]@{ ok = $false; error = "Failed to parse script output as JSON: $output" }
            }
        } elseif ($output -is [hashtable] -or $output -is [pscustomobject]) {
            return $output
        }

        return [ordered]@{ ok = $true }
    } catch {
        return [ordered]@{ ok = $false; error = $_.Exception.Message }
    }
}

if (-not $Operations) {
    Write-FailureResult -Message "Operations JSON string is required"
}

$ops = @()
try {
    $ops = $Operations | ConvertFrom-Json
    if ($ops -isnot [array]) {
        $ops = @($ops)
    }
} catch {
    Write-FailureResult -Message "Failed to parse input JSON: $_"
}

if ($null -eq $ops -or $ops.Count -eq 0) {
    Write-FailureResult -Message "Input must be a non-empty JSON array"
}

foreach ($op in $ops) {
    $index = $script:results.Count
    $opType = $op.type
    $result = [ordered]@{
        index = $index
        op = $opType
        ok = $true
    }

    $script:results += $result

    try {
        $r = Invoke-BatchOperation -Op $op
        $result.ok = $r.ok
        if ($r.ok) {
            if ($opType -eq 'add-task') { $result.task_id = $r.task_id }
            if ($opType -eq 'record-decision') { $result.id = $r.id }
            if ($opType -eq 'update-task-status') {
                $result.task_id = $r.task_id
                $result.status = $r.status
            }
        } else {
            $result.error = $r.error
        }
    } catch {
        $result.ok = $false
        $result.error = $_.Exception.Message
        $script:failed = $true
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