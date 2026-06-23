<#
.SYNOPSIS
Parallel delegation runner for Executive Orchestrator.
.DESCRIPTION
Builds a parallel agent_manager -mode worktree delegation plan from task records,
validates file_scope isolation, writes a manifest, optionally invokes agent_manager
when an executable is available, optionally waits for task completion, and then calls
consolidate-results.ps1.

The script is intentionally dry-run safe and uses common.ps1 for all memory paths.
.PARAMETER Group
ParallelGroup name to resolve from tasks.jsonl.
.PARAMETER TaskIds
Explicit task IDs to delegate.
.PARAMETER TasksJson
Path to a JSON file containing either an array of task objects or { "tasks": [...] }.
.PARAMETER ParentTaskId
When Group/TaskIds/TasksJson are omitted, select child tasks whose parent_id equals this value.
.PARAMETER ContextPacketPath
Context Packet file to prepend to every generated subagent prompt.
.PARAMETER PromptSuffix
Optional prompt text appended after the generated handoff contract.
.PARAMETER MaxAgents
Maximum agents to launch in one batch. Default: 4.
.PARAMETER DryRun
Print the plan without writing manifests or invoking agents.
.PARAMETER InvokeAgentManager
Try to invoke an agent_manager command when present. If no command exists, the script still
writes a manifest and prints the MCP tool invocation JSON.
.PARAMETER RequireAgentManager
Fail if agent_manager cannot be invoked as a command.
.PARAMETER WaitForCompletion
Poll tasks.jsonl until all selected tasks reach a terminal state, then consolidate.
.PARAMETER TimeoutSeconds
Timeout for -WaitForCompletion. Default: 3600.
.PARAMETER NoConsolidate
Do not call consolidate-results.ps1 even when all selected tasks are terminal.
#>

[CmdletBinding(SupportsShouldProcess=$true)]
param(
    [string]$Group,
    [string[]]$TaskIds = @(),
    [string]$TasksJson,
    [string]$ParentTaskId,
    [string]$ContextPacketPath,
    [string]$PromptSuffix = '',
    [ValidateRange(1, 32)]
    [int]$MaxAgents = 4,
    [ValidateRange(0, 10)]
    [int]$MaxRetries = 3,
    [switch]$DryRun,
    [bool]$InvokeAgentManager = $true,
    [switch]$RequireAgentManager,
    [switch]$WaitForCompletion,
    [ValidateRange(30, 86400)]
    [int]$TimeoutSeconds = 3600,
    [switch]$NoConsolidate
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\common.ps1"
Ensure-MemoryDirectories

$tasksPath = Get-TasksPath
$memoryPath = Get-MemoryPath
$terminalStatuses = @('completed', 'failed', 'blocked')
$variantIds = @()
$ParallelRunId = ''

function Write-RunnerError {
    param([string]$Message)
    Write-Host "[parallel-runner] ERROR: $Message" -ForegroundColor Red
}

function Normalize-PathValue {
    param([AllowNull()][string]$Value)
    if (-not $Value) { return '' }
    $normalized = $Value.Trim().Replace('\', '/')
    $normalized = $normalized -replace '/{2,}', '/'
    return $normalized.TrimEnd('/').ToLowerInvariant()
}

function Test-PathOverlap {
    param(
        [AllowNull()][string]$Left,
        [AllowNull()][string]$Right
    )
    $left = Normalize-PathValue $Left
    $right = Normalize-PathValue $Right
    if (-not $left -or -not $right) { return $false }
    if ($left -eq $right) { return $true }
    if ($left.StartsWith("$right/") -or $right.StartsWith("$left/")) { return $true }
    return $false
}

function Get-TaskProperty {
    param(
        [Parameter(Mandatory=$true)]$Task,
        [Parameter(Mandatory=$true)][string]$Name
    )
    if ($Task.PSObject.Properties.Name -contains $Name) {
        return $Task.$Name
    }
    return $null
}

function Get-TaskScope {
    param([Parameter(Mandatory=$true)]$Task)
    $scopeValue = Get-TaskProperty -Task $Task -Name 'file_scope'
    if ($null -eq $scopeValue) { $scopeValue = Get-TaskProperty -Task $Task -Name 'FileScope' }
    if ($null -eq $scopeValue) { return @() }

    $items = @()
    if ($scopeValue -is [string]) {
        $trimmed = $scopeValue.Trim()
        if ($trimmed -match '^\[') {
            try {
                $parsed = $trimmed | ConvertFrom-Json
                $items = @($parsed | ForEach-Object { [string]$_ } | Where-Object { $_ })
            } catch {
                $items = @($trimmed -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
            }
        } else {
            $items = @($trimmed -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        }
    } else {
        $items = @($scopeValue | ForEach-Object { [string]$_ } | Where-Object { $_ })
    }

    return @($items | ForEach-Object { Normalize-PathValue $_ } | Where-Object { $_ })
}

function Get-TaskAgent {
    param([Parameter(Mandatory=$true)]$Task)
    $agent = Get-TaskProperty -Task $Task -Name 'agent'
    if (-not $agent) { $agent = Get-TaskProperty -Task $Task -Name 'assigned_agent' }
    if (-not $agent) { $agent = 'coding-agent' }
    return [string]$agent
}

function Get-TaskPrompt {
    param([Parameter(Mandatory=$true)]$Task)
    $prompt = Get-TaskProperty -Task $Task -Name 'prompt'
    if (-not $prompt) { $prompt = Get-TaskProperty -Task $Task -Name 'Prompt' }
    return [string]$prompt
}

function Get-TaskBranchName {
    param([Parameter(Mandatory=$true)]$Task, [string]$Group)
    $branch = Get-TaskProperty -Task $Task -Name 'branchName'
    if (-not $branch) { $branch = Get-TaskProperty -Task $Task -Name 'BranchName' }
    if (-not $branch) { $branch = Get-TaskProperty -Task $Task -Name 'worktree' }
    if (-not $branch) { $branch = "parallel-$Group-$(Get-TaskProperty -Task $Task -Name 'task_id')" }

    $safe = ([string]$branch).ToLowerInvariant() -replace '[^a-z0-9\-]+', '-'
    $safe = $safe -replace '^-+|-+$', ''
    if (-not $safe) { $safe = "parallel-$Group" }
    return $safe
}

function Get-TaskWorktree {
    param([Parameter(Mandatory=$true)]$Task)
    $worktree = Get-TaskProperty -Task $Task -Name 'worktree'
    if (-not $worktree) { $worktree = Get-TaskProperty -Task $Task -Name 'Worktree' }
    return [string]$worktree
}

function Resolve-TaskWorktreeName {
    param(
        [Parameter(Mandatory=$true)]$Task,
        [string]$Group
    )
    $worktree = Get-TaskWorktree -Task $Task
    if ($worktree) { return $worktree }
    return Get-TaskBranchName -Task $Task -Group $Group
}

function Escape-YamlScalar {
    param([AllowNull()][string]$Value)
    if ($null -eq $Value) { return 'null' }
    return ([string]$Value).Replace('\', '\\').Replace('"', '\"').Replace("`r", ' ').Replace("`n", ' ')
}

function Get-TaskReadiness {
    param(
        [Parameter(Mandatory=$true)]$Task,
        [Parameter(Mandatory=$true)][array]$AllTasks
    )
    $blocked = @()
    $dependsOn = @()
    if ($Task.PSObject.Properties.Name -contains 'depends_on' -and $Task.depends_on) { $dependsOn = @($Task.depends_on) }
    foreach ($dep in $dependsOn) {
        if (-not $dep) { continue }
        $depTask = $AllTasks | Where-Object { $_.task_id -eq [string]$dep } | Select-Object -First 1
        if (-not $depTask) {
            $blocked += "$dep(MISSING)"
        } elseif ($depTask.status -ne 'completed') {
            $blocked += "$dep($($depTask.status))"
        }
    }

    if ($blocked.Count -gt 0) {
        return @{ Ready = $false; Blocked = $blocked }
    }
    return @{ Ready = $true; Blocked = @() }
}

function Test-ActiveParallelGroupTasks {
    param(
        [Parameter(Mandatory=$true)][string]$Group,
        [Parameter(Mandatory=$true)][string[]]$ExcludeTaskIds = @()
    )
    $tasks = Read-Jsonl -Path $tasksPath
    $activeInGroup = $tasks | Where-Object {
        ($_.PSObject.Properties.Name -contains 'parallel_group') -and 
        ([string]$_.parallel_group -eq $Group) -and
        ($_.status -eq 'in_progress') -and
        ($ExcludeTaskIds -notcontains $_.task_id)
    }
    return @($activeInGroup | ForEach-Object { [string]$_.task_id })
}

function Resolve-InputTasks {
    param(
        [string]$ResolvedGroup,
        [string[]]$ResolvedTaskIds,
        [string]$ResolvedTasksJson,
        [string]$ResolvedParentTaskId
    )

    if ($ResolvedTasksJson) {
        if (-not (Test-Path -LiteralPath $ResolvedTasksJson)) {
            throw "TasksJson not found: $ResolvedTasksJson"
        }
        $json = Get-Content -LiteralPath $ResolvedTasksJson -Raw | ConvertFrom-Json
        if ($json.PSObject.Properties.Name -contains 'tasks') {
            return @($json.tasks)
        }
        return @($json)
    }

    if (-not (Test-Path -LiteralPath $tasksPath)) {
        throw "tasks.jsonl not found at $tasksPath"
    }

    $allTasks = Read-Jsonl -Path $tasksPath
    if ($ResolvedTaskIds.Count -gt 0) {
        return @($allTasks | Where-Object { $ResolvedTaskIds -contains [string]$_.task_id })
    }

    if ($ResolvedGroup) {
        return @($allTasks | Where-Object {
            ($_.PSObject.Properties.Name -contains 'parallel_group') -and ([string]$_.parallel_group -eq $ResolvedGroup)
        })
    }

    if ($ResolvedParentTaskId) {
        return @($allTasks | Where-Object {
            ($_.PSObject.Properties.Name -contains 'parent_id') -and ([string]$_.parent_id -eq $ResolvedParentTaskId)
        })
    }

    throw 'Provide -Group, -TaskIds, -TasksJson, or -ParentTaskId.'
}

function Build-HandoffContract {
    param(
        [Parameter(Mandatory=$true)]$Task,
        [string]$ResolvedGroup,
        [string[]]$Scope,
        [string]$ResolvedWorktree
    )
    $taskId = [string]$Task.task_id
    $agent = Get-TaskAgent -Task $Task
    $dependsOn = @()
    if ($Task.PSObject.Properties.Name -contains 'depends_on' -and $Task.depends_on) {
        $dependsOn = @($Task.depends_on | ForEach-Object { [string]$_ } | Where-Object { $_ })
    }
    $objective = Escape-YamlScalar ([string]$Task.objective)

    $scopeLines = if ($Scope.Count -gt 0) {
        @($Scope | ForEach-Object { "    - `"$($_)`"" }) -join "`n"
    } else {
        '    []'
    }

    $dependencyLines = if ($dependsOn.Count -gt 0) {
        @($dependsOn | ForEach-Object { "      - `"$($_)`"" }) -join "`n"
    } else {
        '      - none'
    }

@"
handoff_contract:
  contract_id: "handoff-$ResolvedGroup-$taskId"
  from_agent: "executive-orchestrator"
  to_agent: "$agent"
  task_id: "$taskId"
  task_name: "$taskId"
  parallel_group: "$ResolvedGroup"
  agent: "$agent"
  objective: "$objective"
  worktree: "$ResolvedWorktree"
  file_scope:
$scopeLines
  isolation:
    mode: "file_scope_plus_worktree"
    worktree_must_be_unique: true
  constraints:
    - "Strict file_scope: modify ONLY files listed in file_scope."
    - "Never edit files in another ParallelGroup member's file_scope."
    - "Never share a worktree with another parallel task."
    - "If dependency, file_scope, or worktree conflict is detected, stop and return status: blocked."
    - "Do not read or modify other agents' temporary files."
    - "You MUST call update-heartbeat.ps1 -TaskId $taskId periodically (every few steps) to prevent the Orchestrator's Circuit Breaker from terminating your task as stalled."
  dependencies:
    depends_on:
$dependencyLines
  success_criteria:
    - "All created or modified files are inside file_scope."
    - "No file outside file_scope is changed."
    - "Task uses the assigned unique worktree."
    - "coding_result.status is completed, failed, or blocked with evidence."
  output_format: "coding_result_yaml"
"@
}

function Build-AgentManagerTasks {
    param(
        [Parameter(Mandatory=$true)][array]$SelectedTasks,
        [Parameter(Mandatory=$true)][hashtable]$ScopeMap,
        [Parameter(Mandatory=$true)][hashtable]$WorktreeMap,
        [string]$ResolvedGroup,
        [string]$ResolvedContextPacketPath,
        [string]$ResolvedPromptSuffix
    )

    $context = ''
    if ($ResolvedContextPacketPath -and (Test-Path -LiteralPath $ResolvedContextPacketPath)) {
        $context = Get-Content -LiteralPath $ResolvedContextPacketPath -Raw
    } elseif ($ResolvedContextPacketPath) {
        Write-Warning "ContextPacketPath not found: $ResolvedContextPacketPath"
    }

    $agentManagerTasks = @()
    foreach ($task in $SelectedTasks) {
        $scope = $ScopeMap[[string]$task.task_id]
        $worktree = $WorktreeMap[[string]$task.task_id]
        $contract = Build-HandoffContract -Task $task -ResolvedGroup $ResolvedGroup -Scope $scope -ResolvedWorktree $worktree
        $explicitPrompt = Get-TaskPrompt -Task $task
        $promptParts = @()
        if ($context) { $promptParts += $context }
        if ($explicitPrompt) { $promptParts += $explicitPrompt }
        $promptParts += $contract
        if ($ResolvedPromptSuffix) { $promptParts += $ResolvedPromptSuffix }

        $item = [ordered]@{
            name = "parallel-$ResolvedGroup-$($task.task_id)"
            prompt = ($promptParts -join "`n`n")
        }
        $branchName = Get-TaskBranchName -Task $task -Group $ResolvedGroup
        if ($branchName) { $item.branchName = $branchName }
        if ($worktree) { $item.worktree = $worktree }
        $item.file_scope = @($scope)
        $agentManagerTasks += $item
    }
    return $agentManagerTasks
}

function Get-Batches {
    param(
        [Parameter(Mandatory=$true)][array]$Items,
        [int]$BatchSize
    )
    $batches = @()
    for ($i = 0; $i -lt $Items.Count; $i += $BatchSize) {
        $end = [Math]::Min($i + $BatchSize - 1, $Items.Count - 1)
        $batches += ,@($Items[$i..$end])
    }
    return $batches
}

function Write-PlanSummary {
    param(
        [string]$ResolvedGroup,
        [array]$SelectedTasks,
        [array]$Batches,
        [bool]$ResolvedDryRun,
        [hashtable]$ScopeMap,
        [hashtable]$WorktreeMap
    )
    Write-Host ''
    Write-Host ('=' * 70) -ForegroundColor Cyan
    Write-Host " PARALLEL RUNNER PLAN - $ResolvedGroup" -ForegroundColor Cyan
    Write-Host ('=' * 70) -ForegroundColor Cyan
    Write-Host "  Mode     : $(if ($ResolvedDryRun) { 'DRY RUN' } else { 'LIVE' })" -ForegroundColor White
    Write-Host "  Tasks    : $($SelectedTasks.Count)" -ForegroundColor White
    Write-Host "  MaxAgents: $MaxAgents" -ForegroundColor White
    Write-Host "  Batches  : $($Batches.Count)" -ForegroundColor White
    Write-OrchestratorUiParallelStatus -Group $ResolvedGroup -Summary ("planned tasks: {0}" -f $SelectedTasks.Count)
    foreach ($task in $SelectedTasks) {
        Write-Host ("  - {0} ({1}) worktree={2} scope={3}" -f $task.task_id, (Get-TaskAgent -Task $task), (($WorktreeMap[[string]$task.task_id])), (($ScopeMap[[string]$task.task_id]) -join ';')) -ForegroundColor Gray
    }
    Write-Host ''
}

function Invoke-AgentManagerCommand {
    param(
        [Parameter(Mandatory=$true)][array]$AgentManagerTasks,
        [int]$ResolvedMaxRetries = 3,
        [string]$TaskId = ''
    )
    $command = Get-Command agent_manager -ErrorAction SilentlyContinue
    if ($command) {
        if ($TaskId) {
            Write-ExecutionTrace -TaskId $TaskId -Phase 'delegation' -Status 'parallel_dispatch_attempt' -Data @{
                backend = 'agent_manager'
                task_count = $AgentManagerTasks.Count
            } -Event 'delegation.parallel_dispatch_attempt' -Actor 'parallel-runner' | Out-Null
        }
        $retryCount = 0
        while ($retryCount -lt $ResolvedMaxRetries) {
            try {
                Write-Host "  Invoking agent_manager command (attempt $($retryCount + 1)/$ResolvedMaxRetries) with stagger..." -ForegroundColor DarkGray
                $allSuccess = $true
                for ($i = 0; $i -lt $AgentManagerTasks.Count; $i++) {
                    $task = $AgentManagerTasks[$i]
                    & agent_manager -mode worktree -tasks @($task)
                    if ($LASTEXITCODE -ne 0) {
                        $allSuccess = $false
                        break
                    }
                    if ($i -lt $AgentManagerTasks.Count - 1) {
                        Start-Sleep -Milliseconds (100 + (Get-Random -Maximum 100))
                    }
                }
                if ($allSuccess) {
                    $finalResult = @{ success = $true; attempts = ($retryCount + 1); backend = 'agent_manager' }
                    if ($TaskId) {
                        Write-ExecutionTrace -TaskId $TaskId -Phase 'delegation' -Status 'parallel_dispatch_result' -Data @{
                            backend = 'agent_manager'
                            ok = $true
                            invoked = $true
                            reason = 'dispatched'
                            fallbackRequired = $false
                        } -Event 'delegation.parallel_dispatch_result' -Actor 'parallel-runner' | Out-Null
                    }
                    return $finalResult
                }
            } catch {
                if ($retryCount -ge ($ResolvedMaxRetries - 1)) {
                    $errResult = @{ success = $false; reason = "agent_manager failed after $ResolvedMaxRetries attempts: $($_.Exception.Message)"; backend = 'agent_manager' }
                    if ($TaskId) {
                        Write-ExecutionTrace -TaskId $TaskId -Phase 'delegation' -Status 'parallel_dispatch_result' -Data @{
                            backend = 'agent_manager'
                            ok = $false
                            invoked = $false
                            reason = $errResult.reason
                            fallbackRequired = $true
                        } -Event 'delegation.parallel_dispatch_result' -Actor 'parallel-runner' | Out-Null
                    }
                    return $errResult
                }
                Write-Warning "agent_manager attempt $($retryCount + 1) failed, retrying... ($($_.Exception.Message))"
            }
            $retryCount++
            if ($retryCount -lt $ResolvedMaxRetries) {
                Start-Sleep -Milliseconds (200 * [Math]::Pow(2, $retryCount))
            }
        }
        $retryResult = @{ success = $false; reason = 'max_retries_exceeded'; backend = 'agent_manager' }
        if ($TaskId) {
            Write-ExecutionTrace -TaskId $TaskId -Phase 'delegation' -Status 'parallel_dispatch_result' -Data @{
                backend = 'agent_manager'
                ok = $false
                invoked = $false
                reason = 'max_retries_exceeded'
                fallbackRequired = $true
            } -Event 'delegation.parallel_dispatch_result' -Actor 'parallel-runner' | Out-Null
        }
        return $retryResult
    }

    # Fallback: try Node.js kilo-sdk-delegate.js stub
    $sdkScript = $null
    $sdkCandidates = @(
        (Join-Path $PSScriptRoot 'kilo-sdk-delegate.js'),
        (Join-Path (Get-BasePath) 'delegation' 'kilo-sdk-delegate.js')
    )
    foreach ($candidate in $sdkCandidates) {
        if (Test-Path -LiteralPath $candidate) { $sdkScript = $candidate; break }
    }

    if ((Get-Command node -ErrorAction SilentlyContinue) -and $sdkScript) {
        if ($TaskId) {
            Write-ExecutionTrace -TaskId $TaskId -Phase 'delegation' -Status 'parallel_dispatch_attempt' -Data @{
                backend = 'kilo-sdk-delegate'
                task_count = $AgentManagerTasks.Count
            } -Event 'delegation.parallel_dispatch_attempt' -Actor 'parallel-runner' | Out-Null
        }
        try {
            Write-Host "  Invoking Kilo SDK stub via parallel-runner..." -ForegroundColor DarkGray
            $tasksPath = Join-Path $env:TEMP ("kilo-delegation-parallel-{0}.json" -f [guid]::NewGuid().ToString('N').Substring(0,8))
            $AgentManagerTasks | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $tasksPath -Encoding UTF8
            $nodeResult = & node $sdkScript $tasksPath 2>&1
            if (Test-Path -LiteralPath $tasksPath) { Remove-Item -LiteralPath $tasksPath -Force | Out-Null }
            $parsed = $nodeResult | ConvertFrom-Json -ErrorAction SilentlyContinue
            if ($parsed -and $parsed.invoked) {
                $finalResult = @{ success = $true; attempts = 1; backend = 'kilo-sdk-delegate' }
                if ($TaskId) {
                    Write-ExecutionTrace -TaskId $TaskId -Phase 'delegation' -Status 'parallel_dispatch_result' -Data @{
                        backend = 'kilo-sdk-delegate'
                        ok = $true
                        invoked = $true
                        reason = 'dispatched'
                        fallbackRequired = $false
                    } -Event 'delegation.parallel_dispatch_result' -Actor 'parallel-runner' | Out-Null
                }
                return $finalResult
            }
            $sdkResult = @{ success = $false; reason = 'sdk_stub_fallback_completed_not_invoked'; manifestPath = if ($parsed) { $parsed.manifestPath } else { '' }; backend = 'kilo-sdk-delegate' }
            if ($TaskId) {
                Write-ExecutionTrace -TaskId $TaskId -Phase 'delegation' -Status 'parallel_dispatch_result' -Data @{
                    backend = 'kilo-sdk-delegate'
                    ok = $false
                    invoked = $false
                    reason = 'manual_invoke_required'
                    manifestPath = $sdkResult.manifestPath
                    fallbackRequired = $true
                } -Event 'delegation.parallel_dispatch_result' -Actor 'parallel-runner' | Out-Null
            }
            return $sdkResult
        } catch {
            $errResult = @{ success = $false; reason = "sdk_stub_fallback_failed: $($_.Exception.Message)"; backend = 'kilo-sdk-delegate' }
            if ($TaskId) {
                Write-ExecutionTrace -TaskId $TaskId -Phase 'delegation' -Status 'parallel_dispatch_result' -Data @{
                    backend = 'kilo-sdk-delegate'
                    ok = $false
                    invoked = $false
                    reason = $errResult.reason
                    fallbackRequired = $true
                } -Event 'delegation.parallel_dispatch_result' -Actor 'parallel-runner' | Out-Null
            }
            return $errResult
        }
    }

    if ($TaskId) {
        Write-ExecutionTrace -TaskId $TaskId -Phase 'delegation' -Status 'parallel_dispatch_attempt' -Data @{
            backend = 'none'
            task_count = $AgentManagerTasks.Count
            reason = 'no_executor_available'
        } -Event 'delegation.dispatch_attempt' -Actor 'parallel-runner' | Out-Null
    }

    Write-Warning "agent_manager command not found in PowerShell. Manifest contains the MCP tool invocation; call agent_manager -mode worktree from the orchestrator session."
    $finalResult = @{ success = $false; reason = 'command_not_found'; backend = 'none' }
    if ($TaskId) {
        Write-ExecutionTrace -TaskId $TaskId -Phase 'delegation' -Status 'parallel_dispatch_result' -Data @{
            backend = 'none'
            ok = $false
            invoked = $false
            reason = 'command_not_found'
            fallbackRequired = $true
        } -Event 'delegation.parallel_dispatch_result' -Actor 'parallel-runner' | Out-Null
    }
    return $finalResult
}

function Test-AllTerminal {
    param([Parameter(Mandatory=$true)][string[]]$Ids)
    $current = Read-Jsonl -Path $tasksPath
    foreach ($id in $Ids) {
        $task = $current | Where-Object { $_.task_id -eq $id } | Select-Object -First 1
        if (-not $task -or $task.status -notin $terminalStatuses) { return $false }
    }
    return $true
}

function Wait-ForTerminalTasks {
    param(
        [Parameter(Mandatory=$true)][string[]]$Ids,
        [int]$ResolvedTimeoutSeconds
    )
    $deadline = (Get-Date).AddSeconds($ResolvedTimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $currentTasks = Read-Jsonl -Path $tasksPath
        $terminalCount = 0
        $failedCount = 0
        $blockedCount = 0
        foreach ($id in $Ids) {
            $task = $currentTasks | Where-Object { $_.task_id -eq $id } | Select-Object -First 1
            if ($task) {
                if ($task.status -in $terminalStatuses) {
                    $terminalCount++
                } else {
                    $heartbeatDir = Join-Path (Get-MemoryPath) "heartbeats"
                    $pulseFile = Join-Path $heartbeatDir "$id.json"
                    $stalled = $false
                    if (Test-Path -LiteralPath $pulseFile) {
                        try {
                            $pulse = Get-Content -LiteralPath $pulseFile -Raw | ConvertFrom-Json
                            $lastPulse = [datetime]$pulse.last_pulse
                            if (((Get-Date) - $lastPulse).TotalMinutes -gt 5) {
                                $stalled = $true
                            }
                        } catch {}
                    }
                    if ($stalled) {
                        Write-Warning "Task $id appears stalled (no heartbeat for >5m). Invoking Circuit Breaker."
                        & "$PSScriptRoot\update-task-status.ps1" -TaskId $id -Status 'failed' | Out-Null
                        $failedCount++
                        $terminalCount++ # Include it in terminal count since we just failed it
                    }
                }
                
                if ($task.status -eq 'failed') {
                    $failedCount++
                }
                if ($task.status -eq 'blocked') {
                    $blockedCount++
                }
            }
        }
        
        $healStatus = if ($failedCount -gt 0) { 'remediation' } else { 'pending' }
        $verifyStatus = if ($failedCount -gt 0) { 'fail' } elseif ($blockedCount -gt 0) { 'needs review' } elseif ($terminalCount -eq $Ids.Count) { 'pass' } else { 'pending' }
        
        Write-OrchestratorUiParallelStatus `
            -Group $Group `
            -Summary ("{0}/{1} completed" -f $terminalCount, $Ids.Count) `
            -TasksDetail ("failed: {0}, blocked: {1}" -f $failedCount, $blockedCount)

        if ($terminalCount -eq $Ids.Count) { return $true }
        Start-Sleep -Seconds 5
    }
    return (Test-AllTerminal -Ids $Ids)
}

function Invoke-Consolidation {
    param(
        [string]$ResolvedGroup,
        [string[]]$Ids
    )
    if ($NoConsolidate) {
        Write-Host "  Consolidation skipped by -NoConsolidate." -ForegroundColor Yellow
        return
    }

    $consolidateScript = Join-Path $PSScriptRoot 'consolidate-results.ps1'
    if (-not (Test-Path -LiteralPath $consolidateScript)) {
        throw "consolidate-results.ps1 not found: $consolidateScript"
    }

    Write-Host "  Consolidating parallel results with consolidate-results.ps1." -ForegroundColor DarkGray
    & $consolidateScript -Group $ResolvedGroup -Variants $Ids
}

try {
    if ($ContextPacketPath -and -not (Test-Path -LiteralPath $ContextPacketPath)) {
        throw "ContextPacketPath not found: $ContextPacketPath"
    }

    $selectedTasks = @(Resolve-InputTasks -ResolvedGroup $Group -ResolvedTaskIds $TaskIds -ResolvedTasksJson $TasksJson -ResolvedParentTaskId $ParentTaskId)
    if ($selectedTasks.Count -eq 0) {
        throw 'No tasks matched the parallel delegation selector.'
    }

    $ParallelRunId = "parallel_$(Get-Date -Format yyyyMMddHHmmss)_$([guid]::NewGuid().ToString('N').Substring(0,8))"
    $env:KILO_RUN_ID = $ParallelRunId
    $env:KILO_TRACE_ACTOR = 'parallel-runner'

    $allTasks = Read-Jsonl -Path $tasksPath
    # Pre-flight check: ensure no other agents are running in this parallel group
    $activeInGroup = @()
    if ($Group) {
        $activeInGroup = Test-ActiveParallelGroupTasks -Group $Group -ExcludeTaskIds @()
        if ($activeInGroup.Count -gt 0) {
            Write-Warning "Pre-flight: Found active tasks in group '$Group': $($activeInGroup -join ', '). Consider completing them first."
        }
    }
    if (-not $Group) {
        $groups = @($selectedTasks | ForEach-Object {
            if ($_.PSObject.Properties.Name -contains 'parallel_group') { $_.parallel_group } else { $null }
        } | Where-Object { $_ }) | Select-Object -Unique
        if (@($groups).Count -eq 1) {
            $Group = [string]$groups[0]
        } else {
            $Group = "manual_$(Get-Date -Format 'yyyyMMddHHmmss')"
        }
    }

    $scopeMap = @{}
    foreach ($task in $selectedTasks) {
        $scope = @(Get-TaskScope -Task $task)
        if ($scope.Count -eq 0) {
            throw "Task $($task.task_id) has no file_scope; parallel delegation requires explicit file_scope."
        }
        $scopeMap[[string]$task.task_id] = $scope
    }

    $worktreeMap = @{}
    foreach ($task in $selectedTasks) {
        $worktree = Resolve-TaskWorktreeName -Task $task -Group $Group
        if (-not $worktree) {
            throw "Task $($task.task_id) has no worktree and no derivable fallback."
        }
        $worktreeMap[[string]$task.task_id] = $worktree
    }

    $worktreeCollisions = @()
    $seenWorktrees = @{}
    foreach ($taskId in $worktreeMap.Keys) {
        $normalizedWorktree = Normalize-PathValue $worktreeMap[$taskId]
        if ($seenWorktrees.ContainsKey($normalizedWorktree)) {
            $worktreeCollisions += "$taskId<->$($seenWorktrees[$normalizedWorktree]) => $($worktreeMap[$taskId])"
        } else {
            $seenWorktrees[$normalizedWorktree] = $taskId
        }
    }
    if ($worktreeCollisions.Count -gt 0) {
        throw "worktree collision detected: $($worktreeCollisions -join '; ')"
    }

    $overlaps = @()
    for ($i = 0; $i -lt $selectedTasks.Count; $i++) {
        for ($j = $i + 1; $j -lt $selectedTasks.Count; $j++) {
            $left = $selectedTasks[$i]
            $right = $selectedTasks[$j]
            foreach ($leftPath in $scopeMap[[string]$left.task_id]) {
                foreach ($rightPath in $scopeMap[[string]$right.task_id]) {
                    if (Test-PathOverlap -Left $leftPath -Right $rightPath) {
                        $overlaps += "$($left.task_id)<->$($right.task_id): $leftPath / $rightPath"
                    }
                }
            }
        }
    }
    if ($overlaps.Count -gt 0) {
        throw "file_scope overlap detected: $($overlaps -join '; ')"
    }

    # Pre-flight check: File Scope Guard against active tasks globally
    Write-Host "  Validating file_scope isolation against all active tasks..." -ForegroundColor DarkGray
    foreach ($task in $selectedTasks) {
                $taskScope = $scopeMap[[string]$task.task_id]
                & "$PSScriptRoot\file-scope-guard.ps1" -TaskId $task.task_id -FileScopes $taskScope | Out-Null
                if ($LASTEXITCODE -ne 0) {
                    throw "File scope guard failed for task $($task.task_id). Check overlaps with other running agents."
                }
                Write-ExecutionTrace -TaskId $task.task_id -Phase 'parallel' -Status 'dispatched' -Data @{ group = $Group; run_id = $ParallelRunId; agent = (Get-TaskAgent -Task $task) } -RunId $ParallelRunId -CorrelationId (New-TraceCorrelationId -TaskId $task.task_id -RunId $ParallelRunId) -Event 'parallel.task.dispatched' -Actor 'parallel-runner' | Out-Null
    }

    $readinessErrors = @()
    foreach ($task in $selectedTasks) {
        $readiness = Get-TaskReadiness -Task $task -AllTasks $allTasks
        if (-not $readiness.Ready) {
            $readinessErrors += "$($task.task_id): blocked_by=$($readiness.Blocked -join ',')"
        }
    }
    if ($readinessErrors.Count -gt 0) {
        throw "One or more selected tasks are not ready: $($readinessErrors -join '; ')"
    }

    $agentManagerTasks = @(Build-AgentManagerTasks -SelectedTasks $selectedTasks -ScopeMap $scopeMap -WorktreeMap $worktreeMap -ResolvedGroup $Group -ResolvedContextPacketPath $ContextPacketPath -ResolvedPromptSuffix $PromptSuffix)
    $batches = @(Get-Batches -Items $agentManagerTasks -BatchSize $MaxAgents)
    $variantIds = @($selectedTasks | ForEach-Object { [string]$_.task_id })

    $safeGroup = ($Group.ToLowerInvariant() -replace '[^a-z0-9\-]+', '-') -replace '^-+|-+$', ''
    if (-not $safeGroup) { $safeGroup = 'manual' }
    $groupDir = Join-Path $memoryPath "parallel-groups\$safeGroup"
    $manifestPath = Join-Path $groupDir 'manifest.json'
    $invocationPath = Join-Path $groupDir 'agent-manager-invocation.json'

    $invocation = [ordered]@{
        tool = 'agent_manager'
        mode = 'worktree'
        tasks = $agentManagerTasks
    }

    Write-PlanSummary -ResolvedGroup $Group -SelectedTasks $selectedTasks -Batches $batches -ResolvedDryRun:$DryRun -ScopeMap $scopeMap -WorktreeMap $worktreeMap

    if ($DryRun) {
        Write-Host '  [DryRun] No manifest, task status, or agent_manager invocation will be written.' -ForegroundColor Yellow
        Write-Host '  agent_manager MCP tool payload:' -ForegroundColor DarkGray
        $invocation | ConvertTo-Json -Depth 30
        exit 0
    }

    if (-not (Test-Path -LiteralPath $groupDir)) {
        New-Item -ItemType Directory -Path $groupDir -Force | Out-Null
    }

    $manifest = [ordered]@{
        group = $Group
        parallel_group = [ordered]@{
            group = $Group
            task_ids = $variantIds
            file_scopes = $scopeMap
            worktrees = $worktreeMap
            created_at = (Get-Date).ToString('o')
        }
        created_at = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssZ')
        max_agents = $MaxAgents
        mode = 'agent_manager_worktree'
        variant_task_ids = $variantIds
        batches = $batches
        agent_manager_invocation = $invocation
        consolidation = [ordered]@{
            script = 'consolidate-results.ps1'
            group = $Group
            variants = $variantIds
            pending = -not (Test-AllTerminal -Ids $variantIds)
        }
    }

    $manifest | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
    $invocation | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $invocationPath -Encoding UTF8

    Write-Host "  Manifest written: $manifestPath" -ForegroundColor Green
    Update-SystemState -Key 'last_parallel_group' -Value [ordered]@{
        group = $Group
        run_id = $ParallelRunId
        parallel_group = [ordered]@{
            task_ids = $variantIds
            file_scopes = $scopeMap
            worktrees = $worktreeMap
        }
        manifest = $manifestPath
        invocation = $invocationPath
        updated_at = (Get-Date).ToString('o')
    }
    Update-SystemState -Key 'parallel_group' -Value [ordered]@{
        group = $Group
        run_id = $ParallelRunId
        task_ids = $variantIds
        file_scopes = $scopeMap
        worktrees = $worktreeMap
        manifest = $manifestPath
        invocation = $invocationPath
        updated_at = (Get-Date).ToString('o')
    }
    Write-ExecutionTrace -TaskId (($variantIds | Select-Object -First 1)) -Phase 'parallel' -Status 'manifested' -Data @{
        group = $Group
        run_id = $ParallelRunId
        manifest = $manifestPath
        task_count = $variantIds.Count
        worktree_count = $worktreeMap.Count
    } -RunId $ParallelRunId -CorrelationId (New-TraceCorrelationId -TaskId (($variantIds | Select-Object -First 1)) -RunId $ParallelRunId) -Event 'parallel.manifested' -Actor 'parallel-runner' | Out-Null

    if ($InvokeAgentManager) {
        try {
            $invoked = Invoke-AgentManagerCommand -AgentManagerTasks $agentManagerTasks -ResolvedMaxRetries $MaxRetries -TaskId (($variantIds | Select-Object -First 1))
            if (-not $invoked.success -and $RequireAgentManager) {
                throw "agent_manager command was required but failed: $($invoked.reason)"
            }
            if ($invoked.success -and $invoked.attempts -gt 1) {
                Write-Host "  agent_manager succeeded after $($invoked.attempts) attempts" -ForegroundColor Green
            }
        } catch {
            Write-RunnerError $_.Exception.Message
            exit 1
        }
    } else {
        Write-Host '  agent_manager invocation skipped by -InvokeAgentManager:$false.' -ForegroundColor Yellow
    }

    if ($WaitForCompletion) {
        Write-Host "  Waiting up to $TimeoutSeconds seconds for tasks to become terminal..." -ForegroundColor DarkGray
        $completed = Wait-ForTerminalTasks -Ids $variantIds -ResolvedTimeoutSeconds $TimeoutSeconds
        if (-not $completed) {
            Write-RunnerError "Timed out waiting for parallel tasks to finish."
            exit 2
        }
        Invoke-Consolidation -ResolvedGroup $Group -Ids $variantIds
    } elseif (Test-AllTerminal -Ids $variantIds) {
        Invoke-Consolidation -ResolvedGroup $Group -Ids $variantIds
    } else {
        Write-Host "  Consolidation pending. Run with -WaitForCompletion after agents finish, or call consolidate-results.ps1 -Group $Group -Variants $($variantIds -join ',')." -ForegroundColor Yellow
    }

    Write-Host "Parallel runner completed for group $Group." -ForegroundColor Green
    Write-OrchestratorUiParallelStatus -Group $Group -Summary ("completed tasks: {0}" -f $variantIds.Count)
    Write-ExecutionTrace -TaskId (($variantIds | Select-Object -First 1)) -Phase 'parallel' -Status 'completed' -Data @{
        group = $Group
        run_id = $ParallelRunId
        variants = $variantIds
        worktrees = $worktreeMap
    } -RunId $ParallelRunId -CorrelationId (New-TraceCorrelationId -TaskId (($variantIds | Select-Object -First 1)) -RunId $ParallelRunId) -Event 'parallel.completed' -Actor 'parallel-runner' | Out-Null
    exit 0
}
catch {
    if ($variantIds) {
        Write-OrchestratorUiParallelStatus -Group $(if ($Group) { $Group } else { 'unknown' }) -Summary "error: $($_.Exception.Message)"
        Write-ExecutionTrace -TaskId (($variantIds | Select-Object -First 1)) -Phase 'parallel' -Status 'failed' -Data @{
            group = $(if ($Group) { $Group } else { 'unknown' })
            error = $_.Exception.Message
            run_id = $(if ($ParallelRunId) { $ParallelRunId } else { '' })
        } -RunId $(if ($ParallelRunId) { $ParallelRunId } else { '' }) -CorrelationId (New-TraceCorrelationId -TaskId (($variantIds | Select-Object -First 1)) -RunId $(if ($ParallelRunId) { $ParallelRunId } else { '' })) -Event 'parallel.failed' -FailureMode 'parallel_plan_failure' -Actor 'parallel-runner' | Out-Null
    }
    Write-RunnerError $_.Exception.Message
    exit 1
}
