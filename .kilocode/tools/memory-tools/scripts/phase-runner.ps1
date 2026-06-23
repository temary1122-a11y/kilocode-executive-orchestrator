<#
.SYNOPSIS
Compact 7-phase orchestrator for Executive Orchestrator.

.DESCRIPTION
Runs intake, research, planning, context enrichment, delegation, monitoring,
and verification with a single source of truth for task state and execution
traces.
#>

[CmdletBinding(SupportsShouldProcess=$true)]
param(
    [string]$TaskId,
    [string]$Objective,
    [ValidateSet('research', 'coding', 'verification', 'memory')]
    [string]$Type = 'memory',
    [ValidateSet('p0', 'p1', 'p2')]
    [string]$Priority = 'p1',
    [ValidateSet('low', 'medium', 'high')]
    [string]$EstimatedComplexity = 'medium',
    [string]$Agent = 'executive-orchestrator',
    [switch]$DryRun,
    [switch]$SkipResearch,
    [switch]$SkipResearchInclude,
    [switch]$IncludeResearch,
    [ValidateRange(1000, 50000)]
    [int]$MaxContextSize = 8000,
    [ValidateSet('research', 'coding', 'verification', 'memory', 'review')]
    [string]$Role,
    [switch]$Force,
    [switch]$EnableParallel,
    [switch]$EnableParallelAuto = $true,
    [ValidateRange(1, 32)]
    [int]$MaxAgents = 4
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$RunId = ''
$CorrelationId = ''
$env:KILO_TRACE_WRITE = '1'

. "$PSScriptRoot\common.ps1"
Ensure-MemoryDirectories

$tasksPath = Get-TasksPath
$statePath = Get-StatePath
$decisionsPath = Get-DecisionsJsonlPath
$contextPacketsPath = Get-ContextEnrichmentPath
$reportsPath = Get-ResearchReportsPath
$tracesPath = Get-ExecutionTracesPath

$researchScript = Join-Path $PSScriptRoot 'research-report.ps1'
$contextScript = Join-Path $PSScriptRoot 'context-enrichment.ps1'
$parallelScript = Join-Path $PSScriptRoot 'parallel-runner.ps1'
$recordDecisionScript = Join-Path $PSScriptRoot 'record-decision.ps1'
$updateTaskScript = Join-Path $PSScriptRoot 'update-task-status.ps1'
$checkpointScript = Join-Path $PSScriptRoot 'checkpoint-task.ps1'
$agentStatusScript = Join-Path $PSScriptRoot 'agent-status.ps1'
$healthCheckScript = Join-Path $PSScriptRoot 'health-check.ps1'
$addTaskScript = Join-Path $PSScriptRoot 'add-task.ps1'
$getLastTaskScript = Join-Path $PSScriptRoot 'get-last-task.ps1'

function Invoke-OrchestratorScript {
    param(
        [Parameter(Mandatory=$true)][string]$ScriptPath,
        [string[]]$Arguments = @()
    )
    return Invoke-PhaseScript -ScriptPath $ScriptPath -Arguments $Arguments
}

function Write-PhaseLine {
    param([string]$Phase, [string]$Status, [string]$Detail)
    $color = switch ($Status) {
        'DONE' { 'Green' }
        'SKIP' { 'Yellow' }
        'WARN' { 'Yellow' }
        'FAIL' { 'Red' }
        default { 'Gray' }
    }
    Write-Host ("[{0}] [{1}] {2}" -f $Phase, $Status, $Detail) -ForegroundColor $color
}

function Read-TaskById {
    param([string]$Id)
    $tasks = Read-JsonlSafe -Path $tasksPath
    return ($tasks | Where-Object { $_.task_id -eq $Id } | Select-Object -First 1)
}

function New-HandoffContract {
    param(
        [Parameter(Mandatory=$true)]$Task,
        [string]$ResearchReportPath,
        [string]$ContextPacketPath
    )
    $roleValue = if ($Role) { $Role } elseif ($Task.type) { [string]$Task.type } else { 'coding' }
    $contract = [ordered]@{
        task_id = [string]$Task.task_id
        objective = [string]$Task.objective
        role = $roleValue
        task_type = [string]$Task.type
        priority = [string]$Task.priority
        agent = [string]$Task.assigned_agent
        context_packet = [string]$ContextPacketPath
        research_report = [string]$ResearchReportPath
        file_scope = if ($Task.PSObject.Properties.Name -contains 'file_scope') { @($Task.file_scope) } else { @() }
        constraints = @(
            'Stay within file_scope.'
            'Respect context packet and success criteria.'
            'Do not claim completion without verification.'
        )
        success_criteria = @(
            'Implementation matches objective.'
            'Verification phase passes.'
            'Role-specific evidence is returned in markdown.'
        )
        stop_conditions = @(
            'Stop and report if required context is missing.'
            'Stop and report if file_scope, dependency, or worktree constraints cannot be satisfied.'
            'Do not claim completion without evidence.'
        )
        output_format = 'markdown'
        version = '1.0'
    }
    if ($Task.PSObject.Properties.Name -contains 'parallel_group') {
        $contract.parallel_group = [string]$Task.parallel_group
    }
    if ($Task.PSObject.Properties.Name -contains 'worktree') {
        $contract.worktree = [string]$Task.worktree
    }
    return [pscustomobject]$contract
}

function Ensure-TaskInProgress {
    param([string]$Id)
    if ($DryRun) { return }
    $task = Read-TaskById -Id $Id
    if ($task -and $task.status -ne 'in_progress') {
        Invoke-OrchestratorScript -ScriptPath $updateTaskScript -Arguments @('-TaskId', $Id, '-Status', 'in_progress') | Out-Null
    }
}

function Resolve-Task {
    if ($TaskId) {
        $task = Read-TaskById -Id $TaskId
        if ($task) { return $task }
        if (-not $Objective) {
            throw "TaskId $TaskId not found and Objective was not supplied."
        }
    }

    if (-not $Objective) {
        $task = Get-LatestTaskRecord
        if ($task) { return $task }
        throw 'No task found and Objective was not supplied.'
    }

    if ($DryRun) {
        return [pscustomobject]@{
            task_id = if ($TaskId) { $TaskId } else { "task_dryrun_$(Get-Date -Format yyyyMMddHHmmss)" }
            type = $Type
            priority = $Priority
            status = 'pending'
            objective = $Objective
            assigned_agent = $Agent
        }
    }

    $creation = Invoke-OrchestratorScript -ScriptPath $addTaskScript -Arguments @(
        '-Type', $Type,
        '-Priority', $Priority,
        '-Objective', $Objective,
        '-Agent', $Agent
    )
    $newTaskId = $null
    if ($creation -match '(task_\d{14})') {
        $newTaskId = $Matches[1]
    } elseif ($creation -match '(task_[A-Za-z0-9_\-]+)') {
        $newTaskId = $Matches[1]
    }
    if (-not $newTaskId) {
        $newTaskId = "task_$(Get-Date -Format yyyyMMddHHmmss)"
    }
    return (Read-TaskById -Id $newTaskId)
}

function Invoke-PhaseScript {
    param(
        [Parameter(Mandatory=$true)][string]$ScriptPath,
        [string[]]$Arguments = @()
    )
    if (-not (Test-Path -LiteralPath $ScriptPath)) { return $null }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell.exe'
    $quotedArgs = @(
        '-NoProfile'
        '-NonInteractive'
        '-ExecutionPolicy', 'Bypass'
        '-File', "`"$ScriptPath`""
    ) + ($Arguments | ForEach-Object {
        if ($_ -match '\s') { "`"$($_.Replace('"', '`"'))`"" } else { $_ }
    })
    $psi.Arguments = $quotedArgs -join ' '
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true

    $proc = [System.Diagnostics.Process]::Start($psi)
    $stdout = $proc.StandardOutput.ReadToEnd()
    $stderr = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit()

    if ($proc.ExitCode -ne 0) {
        throw ("Script {0} failed with exit code {1}: {2}" -f $ScriptPath, $proc.ExitCode, $stderr)
    }
    return $stdout
}

function Test-GitWorktreeAvailable {
    param(
        [ValidateSet('worktree', 'local')]
        [string]$Mode = 'worktree'
    )
    $gitTopLevel = git rev-parse --show-toplevel 2>$null
    if (-not $gitTopLevel) {
        return [pscustomobject]@{ available = $false; reason = 'not a git repository' }
    }
    if ($Mode -eq 'worktree') {
        $worktreeSupported = git worktree 2>$null
        if ($LASTEXITCODE -ne 0) {
            return [pscustomobject]@{ available = $false; reason = 'git worktree not supported' }
        }
        return [pscustomobject]@{ available = $true; reason = 'worktree mode available' }
    }
    return [pscustomobject]@{ available = $true; reason = 'local mode available' }
}

function Escape-YamlScalar {
    param([AllowNull()][string]$Value)
    if (-not $Value) { return '' }
    $result = $Value.Replace('\', '\\').Replace('"', '\"').Replace("`n", '\n').Replace('`r', '\r').Replace('`t', '\t')
    if ($result -match '[:\\n\\r\\t"''\\-\\.{\\[\\]&,#*\\?_\\s]' ) {
        return '"' + $result + '"'
    }
    return $result
}

function Format-YamlStringArray {
    param([string[]]$Values)
    if (-not $Values -or $Values.Count -eq 0) { return '@()' }
    $lines = ($Values | ForEach-Object { '    - ' + (Escape-YamlScalar $_) }) -join "`n"
    return $lines
}

function New-RoleHandoffContract {
    param(
        [Parameter(Mandatory=$true)]
        [ValidateSet('research', 'coding', 'verification')]
        [string]$Role,
        [Parameter(Mandatory=$true)]$Task,
        [string]$ResearchReportPath,
        [string]$ContextPacketPath
    )
    $contract = [ordered]@{
        task_id = [string]$Task.task_id
        objective = [string]$Task.objective
        role = $Role
        task_type = [string]$Task.type
        priority = [string]$Task.priority
        agent = "$Role-agent"
        context_packet = [string]$ContextPacketPath
        research_report = [string]$ResearchReportPath
        file_scope = if ($Task.PSObject.Properties.Name -contains 'file_scope') { @($Task.file_scope) } else { @() }
        constraints = @('Stay within file_scope.', 'Respect context packet and success criteria.', 'Do not claim completion without verification.')
        success_criteria = @('Implementation matches objective.', 'Verification phase passes.')
        output_format = 'markdown'
        version = '1.0'
    }
    return [pscustomobject]$contract
}

function Get-TaskPropertySafe {
    param(
        [Parameter(Mandatory=$true)]$Task,
        [Parameter(Mandatory=$true)][string]$Name,
        [string]$Fallback = ''
    )
    if ($null -eq $Task -or -not ($Task.PSObject.Properties.Name -contains $Name) -or $null -eq $Task.$Name) {
        return $Fallback
    }
    return [string]$Task.$Name
}

function Get-TaskScopeValues {
    param([Parameter(Mandatory=$true)]$Task)
    $scopeValue = Get-TaskPropertySafe -Task $Task -Name 'file_scope' -Fallback ''
    if (-not $scopeValue) { return @() }
    if ($scopeValue -is [array]) {
        return @($scopeValue | ForEach-Object { [string]$_ } | Where-Object { $_ })
    }
    return @($scopeValue -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Get-TaskText {
    param(
        [Parameter(Mandatory=$true)]$Task,
        [string]$ResearchReportPath = ''
    )
    $parts = @()
    foreach ($name in @('objective', 'type', 'assigned_agent', 'estimated_complexity', 'priority', 'parallel_group', 'file_scope', 'constraints', 'success_criteria', 'relevant_paths')) {
        if ($Task.PSObject.Properties.Name -contains $name -and $null -ne $Task.$name) {
            $value = $Task.$name
            if ($value -is [array]) { $parts += @($value | ForEach-Object { [string]$_ }) } else { $parts += [string]$value }
        }
    }
    if ($ResearchReportPath -and (Test-Path -LiteralPath $ResearchReportPath)) {
        $parts += Get-Content -LiteralPath $ResearchReportPath -Raw -ErrorAction SilentlyContinue
    }
    return (($parts | Where-Object { $_ -and $_.Trim() } | Select-Object -Unique) -join ' ')
}

function Test-TextMatches {
    param(
        [AllowEmptyString()][string]$Text,
        [Parameter(Mandatory=$true)][string[]]$Patterns
    )
    if (-not $Text) { return $false }
    $lower = $Text.ToLowerInvariant()
    foreach ($pattern in $Patterns) {
        if ($lower -match $pattern) { return $true }
    }
    return $false
}

function New-SanitizedAgentManagerName {
    param(
        [string]$Prefix,
        [string]$Value
    )
    $safe = ($Prefix + '-' + $Value).ToLowerInvariant() -replace '[^a-z0-9\-]+', '-'
    $safe = $safe -replace '^-+|-+$', ''
    if (-not $safe) { return $Prefix }
    return $safe
}

function Resolve-DelegationManifest {
    param(
        [Parameter(Mandatory=$true)]$Task,
        [ValidateSet('low', 'medium', 'high')][string]$Complexity = 'medium',
        [string]$ResearchReportPath = '',
        [switch]$DryRun
    )

    # Conservative role classifier: require either an explicit task/agent signal or
    # a strong combination of complexity + domain signals. This avoids delegating
    # vague memory/admin tasks just because they contain generic verbs like "add".
    $text = Get-TaskText -Task $Task -ResearchReportPath $ResearchReportPath
    $taskType = Get-TaskPropertySafe -Task $Task -Name 'type' -Fallback ''
    $assignedAgent = Get-TaskPropertySafe -Task $Task -Name 'assigned_agent' -Fallback ''
    $hasFileScope = (@(Get-TaskScopeValues -Task $Task)).Count -gt 0
    $hasResearchReport = $ResearchReportPath -and (Test-Path -LiteralPath $ResearchReportPath)

    $researchSignals = Test-TextMatches -Text $text -Patterns @(
        '\bresearch\b', '\binvestigate\b', '\banalyze\b', '\bbest practices?\b',
        '\bbenchmark\b', '\bcompare\b', '\bevaluate\b', '\bunknown\b',
        '\bnew framework\b', '\bexternal\s+api\b', '\bsecurity\b',
        '\barchitecture\b', '\barchitectural\b', '\bsystem\s+design\b',
        '\bframework\b', '\bstandards\b', '\bcompliance\b'
    )
    $architectureSignals = Test-TextMatches -Text $text -Patterns @(
        '\barchitecture\b', '\barchitectural\b', '\bsystem\s+design\b',
        '\bmicroservice\b', '\bservice\s+boundary\b', '\borchestrator\b',
        '\bpipeline\b', '\bexternal\s+api\b', '\bintegration\b'
    )
    $criticalSignals = Test-TextMatches -Text $text -Patterns @(
        '\bsecurity\b', '\bauth\b', '\bauthentication\b', '\bauthorization\b',
        '\bjwt\b', '\boauth\b', '\bencryption\b', '\bcryptography\b',
        '\bpayment\b', '\bprivacy\b', '\bcompliance\b', '\bproduction\b',
        '\bcritical\b', '\bp0\b'
    )
    $codingSignals = Test-TextMatches -Text $text -Patterns @(
        '\bimplement\b', '\bmodify\b', '\bchange\b', '\bupdate\b',
        '\brefactor\b', '\bfix\b', '\bmigrate\b', '\bscript\b',
        '\bcode\b', '\bendpoint\b', '\broute\b', '\bcontroller\b',
        '\bservice\b', '\bmodule\b', '\bcomponent\b', '\bdatabase\b',
        '\bschema\b', '\b(unit\s+tests?|integration\s+tests?|e2e\s+tests?|automated\s+tests?|tests)\b'
    )

    $requiresResearch = $false
    $researchReason = ''
    if ($taskType -eq 'research' -or $assignedAgent -eq 'research-agent') {
        $requiresResearch = $true
        $researchReason = 'task type/assigned agent explicitly requires research'
    }
    elseif ($researchSignals -and $Complexity -in @('medium', 'high')) {
        $requiresResearch = $true
        $researchReason = 'research-domain signals with medium/high complexity'
    }
    elseif ($architectureSignals -and $Complexity -eq 'high') {
        $requiresResearch = $true
        $researchReason = 'high-complexity architecture/design signal'
    }
    elseif ($criticalSignals -and $Complexity -eq 'high') {
        $requiresResearch = $true
        $researchReason = 'high-complexity security/production signal'
    }

    $requiresCoding = $false
    $codingReason = ''
    if ($taskType -eq 'coding' -or $assignedAgent -eq 'coding-agent' -or $hasFileScope) {
        $requiresCoding = $true
        $codingReason = 'task type/assigned agent/file_scope explicitly requires coding'
    }
    elseif ($codingSignals -and $Complexity -in @('medium', 'high')) {
        $requiresCoding = $true
        $codingReason = 'coding verbs with medium/high complexity'
    }

    $requiresVerification = $false
    $verificationReason = ''
    if ($taskType -eq 'verification' -or $assignedAgent -eq 'verification-agent') {
        $requiresVerification = $true
        $verificationReason = 'task type/assigned agent explicitly requires verification'
    }
    elseif ($criticalSignals -and $Complexity -eq 'high') {
        $requiresVerification = $true
        $verificationReason = 'high criticality requires independent verification'
    }
    elseif ($hasResearchReport -and $requiresCoding) {
        $requiresVerification = $true
        $verificationReason = 'research findings must be checked before coding completion'
    }

    $roles = @()
    $reasons = @()
    if ($requiresResearch) {
        $roles += 'research'
        $reasons += "research: $researchReason"
    }
    if ($requiresCoding) {
        $roles += 'coding'
        $reasons += "coding: $codingReason"
    }
    if ($requiresVerification) {
        $roles += 'verification'
        $reasons += "verification: $verificationReason"
    }

    $score = @($roles).Count
    if ($taskType -in @('research', 'coding', 'verification') -or $assignedAgent -match '-agent') { $score++ }
    if ($hasResearchReport) { $score++ }
    $confidence = if ($score -ge 3) { 'high' } elseif ($score -ge 2) { 'medium' } else { 'low' }

    $strategy = 'sequential'
    if (@($roles).Count -eq 1) { $strategy = "$($roles[0])-agent" }
    elseif (@($roles).Count -gt 1) { $strategy = 'agent_manager_roles' }

    if (@($roles).Count -eq 0) {
        $reasons += 'fallback: no conservative delegation threshold was met'
    }

    return [pscustomobject]@{
        RequiredRoles = @($roles)
        Strategy = $strategy
        Reason = $reasons -join '; '
        Confidence = $confidence
        ResearchRequired = [bool]$requiresResearch
        CodingRequired = [bool]$requiresCoding
        VerificationRequired = [bool]$requiresVerification
        DryRun = [bool]$DryRun
    }
}

function Get-ChildTaskCount {
    param([Parameter(Mandatory=$true)][string]$ParentTaskId)
    if (-not (Test-Path -LiteralPath $tasksPath)) { return 0 }
    return @((Read-JsonlSafe -Path $tasksPath) | Where-Object { $_.parent_id -eq $ParentTaskId }).Count
}

function ShouldAutoEnableParallel {
    param(
        [Parameter(Mandatory=$true)]$Task,
        [bool]$EnableParallelAuto = $true
    )
    if (-not $EnableParallelAuto) {
        return [pscustomobject]@{ Eligible = $false; CandidateCount = 0; Reason = 'auto-parallel disabled' }
    }

    $childCount = Get-ChildTaskCount -ParentTaskId ([string]$Task.task_id)
    $parallelGroup = Get-TaskPropertySafe -Task $Task -Name 'parallel_group' -Fallback ''
    $objective = Get-TaskPropertySafe -Task $Task -Name 'objective' -Fallback ''
    $independentParts = Test-TextMatches -Text $objective -Patterns @(
        '\bfrontend\s+and\s+backend\b', '\bclient\s+and\s+server\b',
        '\bui\s+and\s+api\b', '\bapi\s+and\s+ui\b',
        '\bscript\s+and\s+tests?\b', '\bbackend.*frontend\b',
        '\bresearch.*coding.*verification\b'
    )

    if ($parallelGroup -and $childCount -gt 0) {
        return [pscustomobject]@{ Eligible = $true; CandidateCount = $childCount; Reason = "parallel_group has $childCount child task(s)" }
    }
    if ($independentParts -and $childCount -gt 1) {
        return [pscustomobject]@{ Eligible = $true; CandidateCount = $childCount; Reason = 'independent subtask clauses detected with child tasks' }
    }
    if ($independentParts -and $childCount -le 1) {
        return [pscustomobject]@{ Eligible = $false; CandidateCount = $childCount; Reason = 'independent subtasks detected but no child task graph exists; fallback to role agent' }
    }
    return [pscustomobject]@{ Eligible = $false; CandidateCount = 0; Reason = 'no safe parallel delegation signal' }
}

function New-DelegationTaskRecord {
    param(
        [Parameter(Mandatory=$true)][string]$ParentTaskId,
        [Parameter(Mandatory=$true)][string]$Role,
        [string]$Objective,
        [string]$ParallelGroup,
        [string]$Worktree
    )
    return [ordered]@{
        task_id = "task_{0}_{1}_{2}" -f $ParentTaskId, $Role, (Get-Date -Format yyyyMMddHHmmss)
        parent_task_id = $ParentTaskId
        type = $Role
        priority = 'p1'
        status = 'pending'
        objective = $Objective
        assigned_agent = "$Role-agent"
        parallel_group = $ParallelGroup
        worktree = $Worktree
        created_at = (Get-Date).ToString('o')
    }
}

function New-DelegationAgentManagerTask {
    param(
        [Parameter(Mandatory=$true)][string]$ParentTaskId,
        [Parameter(Mandatory=$true)]$ParentTask,
        [Parameter(Mandatory=$true)][string]$Role,
        [string]$Objective,
        [string]$ParallelGroup,
        [string]$Worktree,
        [string]$ContextPacketPath,
        [string]$ResearchReportPath = ''
    )
    $taskRecord = New-DelegationTaskRecord -ParentTaskId $ParentTaskId -Role $Role -Objective $Objective -ParallelGroup $ParallelGroup -Worktree $Worktree
    $contract = New-RoleHandoffContract -Role $Role -Task $ParentTask -ResearchReportPath $ResearchReportPath -ContextPacketPath $ContextPacketPath

    $context = ''
    if ($ContextPacketPath -and (Test-Path -LiteralPath $ContextPacketPath)) {
        $context = Get-Content -LiteralPath $ContextPacketPath -Raw -ErrorAction SilentlyContinue
    }
    elseif ($ContextPacketPath -and $ContextPacketPath -notmatch '^dry-run-') {
        Write-Warning "ContextPacketPath not found for delegation: $ContextPacketPath"
    }

    $contractText = $contract | ConvertTo-Json -Depth 20

    # Build prompt with Context Packet first, then Handoff Contract
    # Per executive-orchestrator.md: "Packet prepended to subagent prompt character-for-character"
    $promptParts = @()
    # Context Packet is the first content (as per handoff contract)
    if ($context) { $promptParts += "Context Packet:`n$context" }
    # Handoff Contract immediately follows
    $promptParts += "handoff_contract_json:`n$contractText"
    # Success criteria for role-based delegation
    $successCriteria = @('Implementation matches objective.', 'Verification phase passes.')
    if ($contract.success_criteria -is [array]) {
        $successCriteria = $contract.success_criteria
    }
    if ($successCriteria.Count -gt 0) {
        $promptParts += ("success_criteria:`n" + (($successCriteria | ForEach-Object { "- $_" }) -join "`n"))
    }
    # Stop conditions tell the subagent when to stop instead of continuing into unsafe work.
    $stopConditions = @('Do not claim completion without evidence.')
    if ($contract.stop_conditions -is [array]) {
        $stopConditions = $contract.stop_conditions
    }
    if ($stopConditions.Count -gt 0) {
        $promptParts += ("stop_conditions:`n" + (($stopConditions | ForEach-Object { "- $_" }) -join "`n"))
    }

    $branchName = New-SanitizedAgentManagerName -Prefix 'delegation' -Value "$ParentTaskId-$Role"
    $name = New-SanitizedAgentManagerName -Prefix 'delegation' -Value "$ParentTaskId-$Role"

    return [ordered]@{
        taskId = if ($taskRecord.task_id) { [string]$taskRecord.task_id } else { '' }
        name = $name
        role = $Role
        agent = "$Role-agent"
        prompt = ($promptParts -join "`n`n")
        branchName = if ($branchName) { $branchName } else { '' }
        file_scope = @(Get-TaskScopeValues -Task $ParentTask)
    }
}

function Invoke-AgentManagerDelegation {
    param(
        [Parameter(Mandatory=$true)][string]$ParentTaskId,
        [Parameter(Mandatory=$true)]$ParentTask,
        [Parameter(Mandatory=$true)][object[]]$Tasks,
        [string]$ResearchReportPath = ''
    )
    $amTasks = @()
    foreach ($t in $Tasks) {
        $amTasks += New-DelegationAgentManagerTask -ParentTaskId $ParentTaskId -ParentTask $ParentTask -Role $t.role -Objective $t.objective -ParallelGroup $t.parallel_group -Worktree $t.worktree -ContextPacketPath $t.context_packet -ResearchReportPath $ResearchReportPath
    }
    return $amTasks
}

function Get-DelegationPolicy {
    param(
        [Parameter(Mandatory=$true)][string]$TaskId,
        [Parameter(Mandatory=$true)][string]$Role,
        [object]$DelegationManifest = $null
    )

    # Check mode config for task delegation permissions
    # Mode permission structure: task: allow/deny (checked via environment variable or state)
    # Default is allow unless explicitly denied.
    $modeConfigPath = Join-Path $PSScriptRoot '..\modes' 'executive-orchestrator.md'
    $policyAllowed = $true
    $policyReason = ''

    # Check environment variable first (runtime override)
    $envPolicy = $env:KILO_DELEGATE_TASK
    if ($envPolicy -eq 'allow') {
        $policyAllowed = $true
        $policyReason = 'environment permission granted'
    } elseif ($envPolicy -eq 'deny') {
        $policyAllowed = $false
        $policyReason = 'environment permission denied'
    } elseif (Test-Path -LiteralPath $modeConfigPath) {
        # Check mode file for explicit permission setting
        # Default is allow; explicit task: deny overrides.
        $modeContent = Get-Content -LiteralPath $modeConfigPath -Raw -ErrorAction SilentlyContinue
        $permissionMatch = [regex]::Match($modeContent, 'task:\s*(allow|deny)')
        if ($permissionMatch.Success) {
            $policyAllowed = ($permissionMatch.Groups[1].Value -eq 'allow')
            $policyReason = "mode config: task:$($permissionMatch.Groups[1].Value)"
        } else {
            # No explicit task: allow or task: deny found. Default to allow.
            $policyAllowed = $true
            $policyReason = 'default_allow'
        }
    } else {
        # No mode config found - default to allow.
        $policyAllowed = $true
        $policyReason = 'default_allow'
    }

    return [pscustomobject]@{
        allowed = [bool]$policyAllowed
        reason = $policyReason
        task_id = $TaskId
        role = $Role
    }
}

# ============================================================================
# REAL DELEGATION OUTPUT - MCP Tool Invocation Support
# ============================================================================
# PowerShell cannot directly invoke MCP tools (task, agent_manager).
# This function outputs JSON in MCP tool format for the calling orchestrator to execute.
# When invoked from a Kilo orchestrator context, the output can be parsed and the
# appropriate MCP tool can be called with the prepared delegation payload.

function Write-RealDelegationPayload {
    param(
        [Parameter(Mandatory=$true)][string]$Tool,
        [Parameter(Mandatory=$true)][object[]]$Tasks,
        [string]$TaskId = '',
        [hashtable]$Metadata = @{}
    )
    # Output delegation payload in MPC tool-compatible format
    # The calling orchestrator should parse this and invoke the actual tool
    $payload = [ordered]@{
        tool = $Tool
        parent_task_id = $TaskId
        tasks = $Tasks
        timestamp = (Get-Date).ToString('o')
        metadata = $Metadata
    }

    # Write to stdout in JSON format for MCP consumption
    # This is the REAL delegation call - the orchestrator reads this and invokes the MCP tool
    ($payload | ConvertTo-Json -Depth 30) | Write-Host
    return $payload
}

# Fallback: Kilo SDK session invocation for real delegation
# This function is called when agent_manager CLI is not available
# PowerShell invokes Node.js script to use @kilocode/sdk for session creation
function Invoke-KiloSdkSessionFallback {
    param(
        [Parameter(Mandatory=$true)][object[]]$AgentManagerTasks,
        [int]$ResolvedMaxRetries = 3
    )
    $sdkDir = Join-Path $PSScriptRoot '..\node_modules\@kilocode\sdk'
    $fallbackScript = Join-Path $PSScriptRoot 'kilo-sdk-delegate.js'

    if (-not (Test-Path -LiteralPath $sdkDir)) {
        return [ordered]@{ invoked = $false; reason = 'kilo_sdk_not_installed'; mode = 'kilo_sdk_fallback'; tasks = $AgentManagerTasks }
    }

    # Write tasks to temp JSON for Node.js consumption
    $tempTasksPath = Join-Path $env:TEMP "kilo_delegation_tasks_$([guid]::NewGuid().ToString('N')).json"
    try {
        $AgentManagerTasks | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $tempTasksPath -Encoding UTF8

        $nodeAvailable = Get-Command node -ErrorAction SilentlyContinue
        if (-not $nodeAvailable) {
            return [ordered]@{ invoked = $false; reason = 'node_not_found_for_sdk'; mode = 'kilo_sdk_fallback'; tasks = $AgentManagerTasks }
        }

        $retryCount = 0
        while ($retryCount -lt $ResolvedMaxRetries) {
            try {
                $psi = New-Object System.Diagnostics.ProcessStartInfo
                $psi.FileName = 'node'
                $psi.Arguments = "`"$fallbackScript`" `"$tempTasksPath`""
                $psi.RedirectStandardOutput = $true
                $psi.RedirectStandardError = $true
                $psi.UseShellExecute = $false
                $psi.CreateNoWindow = $true

                $proc = [System.Diagnostics.Process]::Start($psi)
                $stdout = $proc.StandardOutput.ReadToEnd()
                $stderr = $proc.StandardError.ReadToEnd()
                $proc.WaitForExit()

                if ($proc.ExitCode -eq 0) {
                    return [ordered]@{ invoked = $true; reason = 'ok'; mode = 'kilo_sdk_fallback'; tasks = $AgentManagerTasks; attempts = ($retryCount + 1); output = $stdout }
                }
                else {
                    if ($retryCount -ge ($ResolvedMaxRetries - 1)) {
                        return [ordered]@{ invoked = $false; reason = "sdk_fallback_failed: $($stderr.Trim())"; mode = 'kilo_sdk_fallback'; tasks = $AgentManagerTasks; output = $stdout }
                    }
                }
            } catch {
                if ($retryCount -ge ($ResolvedMaxRetries - 1)) {
                    return [ordered]@{ invoked = $false; reason = "sdk_fallback_failed: $($_.Exception.Message)"; mode = 'kilo_sdk_fallback'; tasks = $AgentManagerTasks }
                }
            }
            $retryCount++
            if ($retryCount -lt $ResolvedMaxRetries) {
                Start-Sleep -Milliseconds (200 * [Math]::Pow(2, $retryCount))
            }
        }
    } finally {
        if (Test-Path -LiteralPath $tempTasksPath) {
            Remove-Item -LiteralPath $tempTasksPath -Force -ErrorAction SilentlyContinue
        }
    }

    return [ordered]@{ invoked = $false; reason = 'max_retries_exceeded'; mode = 'kilo_sdk_fallback'; tasks = $AgentManagerTasks }
}

function Invoke-RealDelegation {
    param(
        [Parameter(Mandatory=$true)][object]$Manifest,
        [Parameter(Mandatory=$true)][string]$TaskId,
        [Parameter(Mandatory=$true)][string]$Objective,
        [Parameter(Mandatory=$true)][string]$ContextPacketPath,
        [Parameter(Mandatory=$true)][array]$RequiredRoles,
        [bool]$Parallel = $false,
        [string]$ParallelGroup = '',
        [int]$MaxAgents = 4,
        [switch]$DryRun
    )

    # Phase 5 Real Delegation Implementation
    # This function implements REAL delegation by calling the appropriate MCP tools:
    # - 'task' tool for single-role delegation (research-agent, coding-agent, verification-agent)
    # - 'parallel-runner.ps1' for parallel delegation (multiple roles)
    # - Skip delegation when task: deny policy is in effect

    Write-Host "Phase 5: Real Delegation - Checking policy and invoking appropriate tools" -ForegroundColor Green

    # Check delegation policy for each role (per executive-orchestrator.md delegation permissions)
    $policyChecks = @{}
    $anyPolicyAllowed = $true

    foreach ($role in $RequiredRoles) {
        $policy = Get-DelegationPolicy -TaskId $TaskId -Role $role
        $policyChecks[$role] = $policy
        if (-not $policy.allowed) {
            $anyPolicyAllowed = $false
            Write-Host ('POLICY DENIED for role {0}: {1}' -f $role, $policy.reason) -ForegroundColor Red
        }
    }

    if (-not $anyPolicyAllowed) {
        # Record policy denial in memory and log decision
        Write-PhaseLine 'P5' 'WARN' ("Delegation denied by policy: $($policyChecks.GetEnumerator() | ForEach-Object { "$($_.Key): $($_.Value.reason)" } -join ', ')")

        $fallbackReason = "delegation_denied:: $(@($policyChecks.GetEnumerator() | ForEach-Object { "$($_.Key): $($_.Value.reason)" }) -join '; ')"

        if (-not $DryRun) {
            Update-SystemState -Key 'last_delegation' -Value ([ordered]@{
                task_id = $TaskId
                roles = $RequiredRoles
                mode = 'policy_denied'
                reason = $fallbackReason
                tasks = @()
                timestamp = (Get-Date).ToString('o')
            })

            Invoke-OrchestratorScript -ScriptPath $recordDecisionScript -Arguments @(
                '-Topic', 'DelegationDecision',
                '-Problem', "Policy check for roles: $($RequiredRoles -join ',')",
                '-Choice', 'DENIED',
                '-Rationale', $fallbackReason,
                '-Task', $TaskId
            ) | Out-Null

            Invoke-OrchestratorScript -ScriptPath $updateTaskScript -Arguments @('-TaskId', $TaskId, '-Status', 'blocked') | Out-Null
        }

        return [ordered]@{ 
            invoked = $false 
            reason = "policy_denied: $fallbackReason" 
            mode = 'policy_denied' 
            tasks = @() 
        }
    }

    Write-Host "POLICY ALLOWS - proceeding with real delegation" -ForegroundColor Yellow

    # Decision: Single role vs parallel delegation
    if (@($RequiredRoles).Count -eq 1 -and -not $Parallel) {
        # SINGLE ROLE DELEGATION - use 'task' tool (as per Phase 5 requirements)

        $role = $RequiredRoles[0]
        $agent = "$role-agent"
        $branchName = New-SanitizedAgentManagerName -Prefix 'delegation' -Value "$TaskId-$role"

        # Build the delegation payload with Context Packet first (per handoff contract)
        $contract = New-RoleHandoffContract -Role $role -Task $task -ResearchReportPath $researchReportPath -ContextPacketPath $contextPacketPath
        $contractText = $contract | ConvertTo-Json -Depth 20

        # Context packet is first content (handoff contract follows)
        $context = ''
        if ($ContextPacketPath -and (Test-Path -LiteralPath $ContextPacketPath)) {
            $context = Get-Content -LiteralPath $ContextPacketPath -Raw
        }

        $promptParts = @()
        if ($context) { $promptParts += "Context Packet:`n$context" }
        $promptParts += "handoff_contract_json:`n$contractText"

        # Add success criteria and stop conditions from the contract
        $successCriteria = @('Implementation matches objective.', 'Verification phase passes.')
        if ($contract.success_criteria -is [array]) { $successCriteria = $contract.success_criteria }
        if ($successCriteria.Count -gt 0) {
            $promptParts += ("success_criteria:`n" + (($successCriteria | ForEach-Object { "- $_" }) -join "`n"))
        }

        $stopConditions = @('Do not claim completion without evidence.')
        if ($contract.stop_conditions -is [array]) { $stopConditions = $contract.stop_conditions }
        if ($stopConditions.Count -gt 0) {
            $promptParts += ("stop_conditions:`n" + (($stopConditions | ForEach-Object { "- $_" }) -join "`n"))
        }

        $finalPrompt = ($promptParts -join "`n`n")

        # Build the task payload for the 'task' tool (per requirements)
        $taskPayload = [ordered]@{
            task_id = "$TaskId-$role-delegation"
            objective = $Objective
            role = $role
            task_type = $role
            priority = 'p1'
            status = 'pending'
            assigned_agent = $agent
            prompt = $finalPrompt
            branchName = $branchName
            context_packet = $contextPacketPath
            research_report = $researchReportPath
            handoff_contract = $contractText
            success_criteria = $successCriteria
            stop_conditions = $stopConditions
            constraints = @(
                "Stay within context packet and success criteria."
                "Do not claim completion without verification."
            )
            file_scope = if ($task.PSObject.Properties.Name -contains 'file_scope') { @($task.file_scope) } else { @() }
            parallel_group = if ($ParallelGroup) { $ParallelGroup } else { '' }
            worktree = ''
            created_at = (Get-Date).ToString('o')
        }

        Write-Host "INVOKING 'task' tool for single role: $role" -ForegroundColor Cyan

        # REAL DELEGATION - call the 'task' tool with the prepared payload (Phase 5 requirement)
        # FIX: replaced Write-Host payload dump with real delegation via Kilo SDK fallback
        try {
            $realInvoked = $false

            # Map payload to the delegation format expected by the SDK fallback
            $agentManagerTasks = @(
                [ordered]@{
                    taskId    = [string]$taskPayload.task_id
                    role      = [string]$taskPayload.role
                    agent     = [string]$taskPayload.assigned_agent
                    name      = ("delegation:{0}" -f $TaskId)
                    prompt    = [string]$taskPayload.prompt
                    branchName = [string]$taskPayload.branchName
                    worktree  = [string]$taskPayload.worktree
                    fileScope = @($taskPayload.file_scope)
                }
            )

              if (-not $DryRun) {
                  if (Get-Command agent_manager -ErrorAction SilentlyContinue) {
                       Write-ExecutionTrace -TaskId $TaskId -Phase 'delegation' -Status 'attempt' -Data @{
                           backend = 'agent_manager'
                           role = $role
                           agent = $agent
                           objective = $Objective
                           file_scope = if ($task.PSObject.Properties.Name -contains 'file_scope') { @($task.file_scope) } else { @() }
                           policy_allowed = $true
                       } -RunId $RunId -CorrelationId $CorrelationId -Event 'delegation.dispatch_attempt' -Actor $Agent | Out-Null

                      # Prefer agent_manager CLI when available
                      $agentManagerCommand = "agent_manager -mode worktree -tasks @($($agentManagerTasks | ConvertTo-Json -Depth 20 | ConvertFrom-Json | ConvertTo-Json -Compress))"
                      Write-Host "  Invoking agent_manager CLI for single role: $role" -ForegroundColor DarkGray
                      & agent_manager -mode worktree -tasks @($agentManagerTasks)
                      $realInvoked = ($LASTEXITCODE -eq 0)
                  } else {
                      # Real delegation path: use Node.js SDK fallback (kilo-sdk-delegate.js)
                      $sdkScript = $null
                      $sdkCandidates = @(
                          (Join-Path $PSScriptRoot 'kilo-sdk-delegate.js'),
                          (Join-Path (Get-BasePath) 'delegation' 'kilo-sdk-delegate.js')
                      )
                      foreach ($candidate in $sdkCandidates) {
                          if (Test-Path -LiteralPath $candidate) { $sdkScript = $candidate; break }
                      }

                      if ((Get-Command node -ErrorAction SilentlyContinue) -and $sdkScript) {
                           $tasksPath = Join-Path $env:TEMP ("kilo-delegation-{0}-{1}.json" -f $TaskId, $role)
                           Write-ExecutionTrace -TaskId $TaskId -Phase 'delegation' -Status 'attempt' -Data @{
                               backend = 'kilo-sdk-delegate'
                               role = $role
                               agent = $agent
                               objective = $Objective
                               file_scope = if ($task.PSObject.Properties.Name -contains 'file_scope') { @($task.file_scope) } else { @() }
                               payload_path = $tasksPath
                               policy_allowed = $true
                           } -RunId $RunId -CorrelationId $CorrelationId -Event 'delegation.dispatch_attempt' -Actor $Agent | Out-Null

                          $agentManagerTasks | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $tasksPath -Encoding UTF8
                          Write-Host "  Invoking Kilo SDK fallback for single role: $role" -ForegroundColor DarkGray
                          $nodeResult = & node $sdkScript $tasksPath 2>&1
                          $realInvoked = $false
                          try {
                              $parsed = $nodeResult | ConvertFrom-Json
                              if ($parsed.invoked) { $realInvoked = $true }
                              if ($parsed.results) { $agentManagerTasks = $parsed.results }
                          } catch {}
                          if (Test-Path -LiteralPath $tasksPath) { Remove-Item -LiteralPath $tasksPath -Force | Out-Null }
                      } else {
                          Write-PhaseLine 'P5' 'WARN' 'No delegation executor available (agent_manager CLI and node SDK both missing); delegation prepared but not invoked.'
                          $realInvoked = $false
                           if (-not $DryRun) {
                               Write-ExecutionTrace -TaskId $TaskId -Phase 'delegation' -Status 'fallback' -Data @{
                                   backend = 'none'
                                   role = $role
                                   agent = $agent
                                   objective = $Objective
                                   file_scope = if ($task.PSObject.Properties.Name -contains 'file_scope') { @($task.file_scope) } else { @() }
                                   reason = 'no_executor_available'
                                   policy_allowed = $true
                               } -RunId $RunId -CorrelationId $CorrelationId -Event 'delegation.dispatch_attempt' -Actor $Agent | Out-Null

                              $pendingDir = Join-Path (Get-MemoryPath) 'delegation' 'pending'
                              if (-not (Test-Path -LiteralPath $pendingDir)) { New-Item -ItemType Directory -Path $pendingDir -Force | Out-Null }
                              $manifestPath = Join-Path $pendingDir "$TaskId-$role-delegation.json"
                              $manifest = [ordered]@{
                                  task_id = $TaskId
                                  role = $role
                                  agent = $agent
                                  objective = $Objective
                                  file_scope = if ($task.PSObject.Properties.Name -contains 'file_scope') { @($task.file_scope) } else { @() }
                                  original_payload = $agentManagerTasks
                                  status = 'pending_manual_invoke'
                                  reason = 'manual_invoke_required'
                                  timestamp = (Get-Date).ToString('o')
                              }
                              $manifest | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
                              Write-Host "  Pending manifest created: $manifestPath" -ForegroundColor DarkGray
                          }
                      }
                  }
              }

            if ($realInvoked) {
                # Record successful delegation attempt
                Invoke-OrchestratorScript -ScriptPath $recordDecisionScript -Arguments @(
                    '-Topic', 'DelegationDecision',
                    '-Problem', "Single role delegation for: $role",
                    '-Choice', "INVOKED task tool",
                    '-Rationale', "Policy allowed, role: $role, agent: $agent",
                    '-Task', $TaskId,
                    '-Artifacts', @($ContextPacketPath, $researchReportPath)
                ) | Out-Null
            } else {
                Write-PhaseLine 'P5' 'WARN' ("Single role delegation invocation did not report success for: {0}" -f $role)
                if (-not $DryRun) {
                    Invoke-OrchestratorScript -ScriptPath $recordDecisionScript -Arguments @(
                        '-Topic', 'DelegationDecision',
                        '-Problem', "Single role delegation fallback for: $role",
                        '-Choice', 'FALLBACK_SEQUENTIAL',
                        '-Rationale', 'Delegation backend unavailable or invocation failed; actual sequential execution not implemented; manual_invoke_required via manifest.',
                        '-Task', $TaskId
                    ) | Out-Null
                }
            }

            $resultBackend = 'none'
            $resultReason = 'unknown'
            if ($realInvoked) {
                $resultBackend = if ((Get-Command agent_manager -ErrorAction SilentlyContinue)) { 'agent_manager' } else { 'kilo-sdk-delegate' }
                $resultReason = 'dispatched'
            } else {
                if ($manifestPath) {
                    $resultBackend = 'kilo-sdk-delegate'
                    $resultReason = 'manual_invoke_required'
                } else {
                    $resultBackend = if ((Get-Command agent_manager -ErrorAction SilentlyContinue)) { 'agent_manager' } else { 'none' }
                    $resultReason = 'execution_failed'
                }
            }
            Write-ExecutionTrace -TaskId $TaskId -Phase 'delegation' -Status 'result' -Data @{
                backend = $resultBackend
                ok = [bool]$realInvoked
                invoked = [bool]$realInvoked
                reason = $resultReason
                manifestPath = if ($manifestPath) { $manifestPath } else { '' }
                fallbackRequired = (-not $realInvoked)
            } -RunId $RunId -CorrelationId $CorrelationId -Event 'delegation.dispatch_result' -Actor $Agent | Out-Null

            return [ordered]@{
                invoked       = [bool]$realInvoked
                reason        = if ($realInvoked) { "single_role_delegated: $role" } else { "single_role_invocation_uncertain: $role" }
                mode          = 'task_tool'
                tasks         = @($taskPayload)
                tool_invoked  = 'task'
                backend       = $resultBackend
                delegationInvoked = [bool]$realInvoked
                workExecuted    = [bool]$realInvoked
                fallback        = if (-not $realInvoked) { if ($manifestPath) { 'manual_invoke_required' } else { 'execution_failed' } } else { '' }
                manifestPath    = if ($manifestPath) { $manifestPath } else { '' }
            }

        } catch {
            $fallbackReason = "task_tool_invocation_failed: $($_.Exception.Message)"
            Write-PhaseLine 'P5' 'WARN' ("Single role delegation not invoked: $fallbackReason")
            if (-not $DryRun) {
                Update-SystemState -Key 'last_delegation' -Value ([ordered]@{
                    task_id = $TaskId
                    roles = $RequiredRoles
                    mode = 'task_tool_failed'
                    reason = $fallbackReason
                    tasks = @($taskPayload)
                    timestamp = (Get-Date).ToString('o')
                })
            }

            Write-ExecutionTrace -TaskId $TaskId -Phase 'delegation' -Status 'result' -Data @{
                backend = 'none'
                ok = $false
                invoked = $false
                reason = $fallbackReason
                manifestPath = ''
                fallbackRequired = $true
            } -RunId $RunId -CorrelationId $CorrelationId -Event 'delegation.dispatch_result' -Actor $Agent | Out-Null

             return [ordered]@{
                 invoked = $false
                 reason = $fallbackReason
                 mode = 'task_tool_failed'
                 tasks = @()
                 backend = 'none'
                 delegationInvoked = $false
                 workExecuted = $false
                 fallback = 'execution_failed'
                 manifestPath = ''
             }
        }

    } elseif (@($RequiredRoles).Count -gt 1 -or $Parallel) {
        # MULTI-ROLE OR PARALLEL DELEGATION - use 'parallel-runner.ps1' (Phase 5 requirement)

        Write-Host "MULTI-ROLE/PARALLEL DELEGATION detected - invoking parallel-runner.ps1" -ForegroundColor Magenta

        try {
            # Prepare parallel delegation arguments
            $parallelArgs = @('-ParentTaskId', $TaskId, '-MaxAgents', $MaxAgents)
            if ($ContextPacketPath) { $parallelArgs += @('-ContextPacketPath', $ContextPacketPath) }
            if ($ParallelGroup) { $parallelArgs += @('-Group', $ParallelGroup) }

            Write-ExecutionTrace -TaskId $TaskId -Phase 'delegation' -Status 'parallel_dispatch_attempt' -Data @{
                mode = if ($EnableParallel) { 'explicit_parallel' } else { 'auto_parallel' }
                max_agents = $MaxAgents
                roles = @($RequiredRoles)
                context_packet = if ($ContextPacketPath) { $ContextPacketPath } else { '' }
                policy_allowed = $true
            } -RunId $RunId -CorrelationId $CorrelationId -Event 'delegation.dispatch_attempt' -Actor $Agent | Out-Null

            # REAL DELEGATION - call parallel-runner.ps1 which internally invokes agent_manager
            $parallelOutput = Invoke-PhaseScript -ScriptPath $parallelScript -Arguments $parallelArgs
            
            $parsedParallelOutput = $null
            try { $parsedParallelOutput = $parallelOutput | ConvertFrom-Json -ErrorAction SilentlyContinue } catch {}
            Write-ExecutionTrace -TaskId $TaskId -Phase 'delegation' -Status 'parallel_dispatch_result' -Data @{
                mode = if ($EnableParallel) { 'explicit_parallel' } else { 'auto_parallel' }
                ok = if ($parsedParallelOutput) { [bool]($parsedParallelOutput.success -or $parsedParallelOutput.invoked) } else { $false }
                invoked = if ($parsedParallelOutput) { [bool]$parsedParallelOutput.invoked } else { $false }
                reason = if ($parsedParallelOutput) { $parsedParallelOutput.reason } else { 'no_output' }
                manifestPath = if ($parsedParallelOutput) { $parsedParallelOutput.manifestPath } else { '' }
                fallbackRequired = if ($parsedParallelOutput) { -not $parsedParallelOutput.invoked } else { $true }
            } -RunId $RunId -CorrelationId $CorrelationId -Event 'delegation.dispatch_result' -Actor $Agent | Out-Null

            # Record parallel delegation
            Invoke-OrchestratorScript -ScriptPath $recordDecisionScript -Arguments @(
                '-Topic', 'DelegationDecision',
                '-Problem', "Parallel delegation for roles: $($RequiredRoles -join ',')",
                '-Choice', 'PARALLEL_INVOKED',
                '-Rationale', "Multiple roles require parallel execution",
                '-Task', $TaskId
            ) | Out-Null

            return [ordered]@{ 
                invoked = $true 
                reason = "parallel_invoked: $($RequiredRoles -join ',')" 
                mode = 'parallel_runner' 
                tasks = @($parallelOutput)
                tool_invoked = 'parallel-runner.ps1'
                backend = 'parallel-runner'
                delegationInvoked = $true
                workExecuted = if ($parsedParallelOutput) { [bool]$parsedParallelOutput.invoked } else { $false }
                fallback = if ($parsedParallelOutput -and -not $parsedParallelOutput.invoked) { 'parallel_incomplete' } else { '' }
                manifestPath = if ($parsedParallelOutput) { $parsedParallelOutput.manifestPath } else { '' }
            }

        } catch {
            $fallbackReason = "parallel_invocation_failed: $($_.Exception.Message)"
            Write-PhaseLine 'P5' 'WARN' ("Parallel delegation not invoked: $fallbackReason")
            if (-not $DryRun) {
                Update-SystemState -Key 'last_delegation' -Value ([ordered]@{
                    task_id = $TaskId
                    roles = $RequiredRoles
                    mode = 'parallel_failed'
                    reason = $fallbackReason
                    tasks = @()
                    timestamp = (Get-Date).ToString('o')
                })
            }

            Write-ExecutionTrace -TaskId $TaskId -Phase 'delegation' -Status 'result' -Data @{
                backend = 'parallel-runner'
                ok = $false
                invoked = $false
                reason = $fallbackReason
                manifestPath = ''
                fallbackRequired = $true
            } -RunId $RunId -CorrelationId $CorrelationId -Event 'delegation.dispatch_result' -Actor $Agent | Out-Null

            return [ordered]@{ 
                invoked = $false 
                reason = $fallbackReason 
                mode = 'parallel_failed' 
                tasks = @()
                backend = 'parallel-runner'
                delegationInvoked = $false
                workExecuted = $false
                fallback = 'execution_failed'
                manifestPath = ''
            }
        }
    }

    # SEQUENTIAL FALLBACK - no delegation, but preparation
    Write-Host "SEQUENTIAL EXECUTION selected - no real delegation will be invoked" -ForegroundColor Yellow

    if (-not $DryRun) {
        Update-SystemState -Key 'last_delegation' -Value ([ordered]@{
            task_id = $TaskId
            roles = $RequiredRoles
            mode = 'sequential'
            reason = 'No delegation policy or roles do not require specialization'
            tasks = @()
            timestamp = (Get-Date).ToString('o')
        })
    }

    return [ordered]@{ 
        invoked = $false 
        reason = "sequential_fallback: $($RequiredRoles -join ',')" 
        mode = 'sequential' 
        tasks = @()
    }
}

function Invoke-AutoDelegation {
    param(
        [Parameter(Mandatory=$true)]$Task,
        [Parameter(Mandatory=$true)][object]$Manifest,
        [string]$ContextPacketPath,
        [string]$ResearchReportPath = ''
    )
    if (-not $Manifest -or -not $Manifest.RequiredRoles -or @($Manifest.RequiredRoles).Count -eq 0) {
        return [ordered]@{ invoked = $false; reason = 'no required roles'; mode = 'sequential'; tasks = @() }
    }

    $tasksToDelegate = @()
    foreach ($role in $Manifest.RequiredRoles) {
        $tasksToDelegate += [ordered]@{
            role = $role
            objective = [string]$Task.objective
            parallel_group = if ($Task.PSObject.Properties.Name -contains 'parallel_group') { [string]$Task.parallel_group } else { '' }
            worktree = ''
            context_packet = $ContextPacketPath
        }
    }

    $agentManagerTasks = Invoke-AgentManagerDelegation -ParentTaskId ([string]$Task.task_id) -ParentTask $Task -Tasks $tasksToDelegate -ResearchReportPath $ResearchReportPath
    return [ordered]@{ invoked = $true; reason = 'agent_manager_payload_ready'; mode = 'agent_manager_worktree'; tasks = $agentManagerTasks }
}

try {
    Write-Host '========================================' -ForegroundColor Cyan
    Write-Host ' EXECUTIVE ORCHESTRATOR - 7 PHASE RUN ' -ForegroundColor Cyan
    Write-Host '========================================' -ForegroundColor Cyan

    $task = Resolve-Task
    if (-not $task) {
        throw 'Unable to resolve task.'
    }
    $TaskId = [string]$task.task_id
    $RunId = "run_$(Get-Date -Format yyyyMMddHHmmss)_$([guid]::NewGuid().ToString('N').Substring(0,8))"
    $CorrelationId = New-TraceCorrelationId -TaskId $TaskId -RunId $RunId
    $env:KILO_RUN_ID = $RunId
    $env:KILO_CORRELATION_ID = $CorrelationId
    $env:KILO_TRACE_ACTOR = $Agent
    if ($DryRun) { $env:KILO_TRACE_WRITE = '0' }
    $verificationStatus = 'pending'

    if (-not $DryRun) {
        Write-ExecutionTrace -TaskId $TaskId -Phase 'run' -Status 'start' -Data @{
            objective = [string]$task.objective
            type = [string]$task.type
            priority = [string]$task.priority
            dry_run = [bool]$DryRun
            parallel = [bool]$EnableParallel
        } -RunId $RunId -CorrelationId $CorrelationId -Event 'run.start' -Actor $Agent | Out-Null
    }
    Write-OrchestratorUiStatus -TaskId $TaskId -RunId $RunId -Phase 'intake' -ParallelGroup ($(if ($task.PSObject.Properties.Name -contains 'parallel_group') { [string]$task.parallel_group } else { '' })) -HealingStatus ($(if ($task.PSObject.Properties.Name -contains 'last_self_heal') { 'applied' } else { 'none' })) -VerificationStatus $verificationStatus -TraceEnabled:(-not $DryRun) -Summary ('objective: {0}' -f [string]$task.objective)

    $phases = [ordered]@{}
    $researchReportPath = ''
    $contextPacketPath = ''
    $handoffContract = $null
    $dryRunStamp = if ($DryRun) { Get-Date -Format 'yyyyMMddHHmmss' } else { $null }

    if ($DryRun) {
        $researchReportPath = "dry-run-report-$dryRunStamp.md"
        $contextPacketPath = "dry-run-packet-$dryRunStamp.md"
    }

    # Phase 1 - Intake
    Write-PhaseLine 'P1' 'DONE' ("Task resolved: {0}" -f $TaskId)
    $phases['P1'] = 'DONE'
    Ensure-TaskInProgress -Id $TaskId
    if (-not $DryRun) {
        Write-ExecutionTrace -TaskId $TaskId -Phase 'run' -Status 'running' -Data @{
            step = 'intake'
        } -RunId $RunId -CorrelationId $CorrelationId -Event 'phase.start' -Actor $Agent | Out-Null
        Sync-SystemStateFromTasks
    }

    # Phase 2 - Research
    $runResearch = (-not $SkipResearch) -and (($EstimatedComplexity -in @('medium', 'high')) -or ($task.type -eq 'research'))
    if ($runResearch -and $DryRun) {
        Write-PhaseLine 'P2' 'SKIP' 'Dry-run only'
        $phases['P2'] = 'SKIP'
    }
    elseif ($runResearch -and (Test-Path -LiteralPath $researchScript)) {
        Write-ExecutionTrace -TaskId $TaskId -Phase 'research' -Status 'start' -Data @{
            complexity = $EstimatedComplexity
        } -RunId $RunId -CorrelationId $CorrelationId -Event 'phase.start' -Actor $Agent | Out-Null
        $researchArgs = @('-TaskId', $TaskId, '-Query', [string]$task.objective, '-Complexity', $EstimatedComplexity)
        $researchOutput = Invoke-PhaseScript -ScriptPath $researchScript -Arguments $researchArgs
        $researchText = ($researchOutput | Out-String)
        if ($researchText -match '(?m)reportPath["\s:]+([^"\r\n]+\.md)') {
            $researchReportPath = $Matches[1]
        }
        if (-not $researchReportPath) {
            $latestReport = Get-ChildItem -Path $reportsPath -Filter '*.md' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($latestReport) { $researchReportPath = $latestReport.FullName }
        }
        Write-PhaseLine 'P2' 'DONE' ("Research complete: {0}" -f ($(if ($researchReportPath) { $researchReportPath } else { 'no path resolved' })))
        $phases['P2'] = 'DONE'
        Write-ExecutionTrace -TaskId $TaskId -Phase 'research' -Status 'done' -Data @{
            report = $researchReportPath
        } -RunId $RunId -CorrelationId $CorrelationId -Event 'phase.done' -Actor $Agent | Out-Null
    } else {
        Write-PhaseLine 'P2' 'SKIP' 'Research not required'
        $phases['P2'] = 'SKIP'
        Write-ExecutionTrace -TaskId $TaskId -Phase 'research' -Status 'skip' -Data @{
            reason = 'not required'
        } -RunId $RunId -CorrelationId $CorrelationId -Event 'phase.skip' -Actor $Agent | Out-Null
    }

    # Phase 2a - Intake decision log
    if (-not $DryRun) {
        Invoke-OrchestratorScript -ScriptPath $recordDecisionScript -Arguments @(
            '-Topic', 'Intake',
            '-Problem', [string]$task.objective,
            '-Choice', 'Task accepted',
            '-Rationale', ("complexity={0}; run={1}" -f $EstimatedComplexity, $(if ($runResearch) { 'research' } else { 'direct' })),
            '-Task', $TaskId
        ) | Out-Null
        Write-PhaseLine 'P2a' 'DONE' 'Intake decision recorded'
        $phases['P2a'] = 'DONE'
        Write-ExecutionTrace -TaskId $TaskId -Phase 'intake' -Status 'done' -Data @{
            decision = 'Task accepted'
        } -RunId $RunId -CorrelationId $CorrelationId -Event 'phase.done' -Actor $Agent | Out-Null
    } else {
        Write-PhaseLine 'P2a' 'SKIP' 'Dry-run only'
        $phases['P2a'] = 'SKIP'
    }

# Phase 3 - Planning metadata, delegation manifest, and handoff contract
     $handoffContract = New-HandoffContract -Task $task -ResearchReportPath $researchReportPath -ContextPacketPath $contextPacketPath
     $contractCheck = Test-HandoffContract -Contract $handoffContract
     if (-not $contractCheck.valid) {
         throw ("Invalid handoff contract: {0}" -f ($contractCheck.missing -join ', '))
     }
     if ($task.type -eq 'coding' -and @($handoffContract.file_scope).Count -eq 0) {
         throw 'Invalid handoff contract: file_scope is required for coding tasks.'
     }

     # Phase 3 delegation manifest: compute required specialist roles from task
     # signals only. The classifier is intentionally conservative and falls back
     # to sequential execution if the objective is ambiguous.
     $delegationManifest = $null
     try {
         $delegationManifest = Resolve-DelegationManifest -Task $task -Complexity $EstimatedComplexity -ResearchReportPath $researchReportPath -DryRun:$DryRun
     }
     catch {
         $delegationManifest = [pscustomobject]@{
             RequiredRoles = @()
             Strategy = 'sequential'
             Reason = "fallback: delegation heuristic failed: $($_.Exception.Message)"
             Confidence = 'low'
             ResearchRequired = $false
             CodingRequired = $false
             VerificationRequired = $false
             DryRun = [bool]$DryRun
         }
         Write-PhaseLine 'P3' 'WARN' $delegationManifest.Reason
     }
     if (-not $delegationManifest) {
         $delegationManifest = [pscustomobject]@{
             RequiredRoles = @()
             Strategy = 'sequential'
             Reason = 'fallback: delegation manifest was not produced'
             Confidence = 'low'
             ResearchRequired = $false
             CodingRequired = $false
             VerificationRequired = $false
             DryRun = [bool]$DryRun
         }
     }

     if (@($delegationManifest.RequiredRoles).Count -gt 0) {
         if (-not $DryRun) {
             Invoke-OrchestratorScript -ScriptPath $recordDecisionScript -Arguments @(
                 '-Topic', 'AutoDelegation',
                 '-Problem', 'Determine if task needs specialist delegation',
                 '-Choice', ('roles={0}; strategy={1}; confidence={2}' -f (@($delegationManifest.RequiredRoles) -join ','), $delegationManifest.Strategy, $delegationManifest.Confidence),
                 '-Rationale', $delegationManifest.Reason,
                 '-Task', $TaskId
             ) | Out-Null
         }
         Write-PhaseLine 'P3' 'DONE' ("Auto-delegation planned: {0} ({1})" -f (@($delegationManifest.RequiredRoles) -join ', '), $delegationManifest.Reason)
     }
     else {
         Write-PhaseLine 'P3' 'DONE' ("Sequential execution selected: {0}" -f $delegationManifest.Reason)
     }

     if (-not $DryRun) {
         Update-SystemState -Key 'handoff_contract' -Value $handoffContract
     }
     $phases['P3'] = 'DONE'
     Write-ExecutionTrace -TaskId $TaskId -Phase 'planning' -Status 'done' -Data @{
         contract_valid = $true
         delegation_roles = @($delegationManifest.RequiredRoles)
         delegation_strategy = $delegationManifest.Strategy
         delegation_confidence = $delegationManifest.Confidence
         parallel_group = if ($task.PSObject.Properties.Name -contains 'parallel_group') { [string]$task.parallel_group } else { '' }
     } -RunId $RunId -CorrelationId $CorrelationId -Event 'phase.done' -Actor $Agent | Out-Null

    # Phase 4 - Context enrichment
    if ($DryRun) {
        Write-PhaseLine 'P4' 'SKIP' 'Dry-run only'
        $phases['P4'] = 'SKIP'
    }
    elseif (Test-Path -LiteralPath $contextScript) {
        Write-ExecutionTrace -TaskId $TaskId -Phase 'context' -Status 'start' -Data @{
            max_context_size = $MaxContextSize
        } -RunId $RunId -CorrelationId $CorrelationId -Event 'phase.start' -Actor $Agent | Out-Null
        $enrichArgs = @('-TaskId', $TaskId, '-MaxContextSize', $MaxContextSize, '-Force')
        if ($IncludeResearch -or ($runResearch -and -not $SkipResearchInclude)) {
            $enrichArgs += '-IncludeResearch'
        }
        $enrichArgs += @('-IncludeRecentDecisions', '5')
        if ($Role) { $enrichArgs += @('-Role', $Role) }
        $enrichOutput = Invoke-PhaseScript -ScriptPath $contextScript -Arguments $enrichArgs
        $enrichText = ($enrichOutput | Out-String)
        if ($enrichText -match '(?m)^(.*\.md)$') {
            $candidate = $Matches[1].Trim()
            if (Test-Path -LiteralPath $candidate) {
                $contextPacketPath = $candidate
            }
        }
if (-not $contextPacketPath) {
             $contextPacketPath = Join-Path $contextPacketsPath "$TaskId.md"
         }
         $handoffContract.context_packet = $contextPacketPath
         $contractCheck = Test-HandoffContract -Contract $handoffContract
         if (-not $contractCheck.valid) {
             throw ("Invalid handoff contract after context enrichment: {0}" -f ($contractCheck.missing -join ', '))
         }
         if (-not $DryRun) {
             Update-SystemState -Key 'handoff_contract' -Value $handoffContract
         }
         Write-PhaseLine 'P4' 'DONE' ("Context packet: {0}" -f $contextPacketPath)
         $phases['P4'] = 'DONE'
         Write-ExecutionTrace -TaskId $TaskId -Phase 'context' -Status 'done' -Data @{
             packet = $contextPacketPath
         } -RunId $RunId -CorrelationId $CorrelationId -Event 'phase.done' -Actor $Agent | Out-Null
     } else {
         Write-PhaseLine 'P4' 'SKIP' 'Context enrichment script missing'
         $phases['P4'] = 'SKIP'
         Write-ExecutionTrace -TaskId $TaskId -Phase 'context' -Status 'skip' -Data @{
             reason = 'script missing'
         } -RunId $RunId -CorrelationId $CorrelationId -Event 'phase.skip' -Actor $Agent | Out-Null
     }

    # Phase 5 - Delegation orchestration
      $autoParallelDecision = $null
      $autoDelegationInvoked = $false
      $delegationPolicyDenied = $false
      $fallbackReason = ''

      if (-not $DryRun -and $EnableParallelAuto) {
          $autoParallelDecision = ShouldAutoEnableParallel -Task $task -EnableParallelAuto $true
          if ($autoParallelDecision.Eligible) {
              Write-PhaseLine 'P5-AUTO' 'INFO' ("Auto-parallel detected: {0}" -f $autoParallelDecision.Reason)
              Write-ExecutionTrace -TaskId $TaskId -Phase 'delegation' -Status 'auto_detect' -Data @{
                  candidate_count = $autoParallelDecision.CandidateCount
                  reason = $autoParallelDecision.Reason
              } -RunId $RunId -CorrelationId $CorrelationId -Event 'parallel.auto_detect' -Actor $Agent | Out-Null
          }
      }

      $useParallel = ($EnableParallel -or ($autoParallelDecision -and $autoParallelDecision.Eligible)) -and (Test-Path -LiteralPath $parallelScript)

      if ($DryRun) {
          if ($delegationManifest -and @($delegationManifest.RequiredRoles).Count -gt 0) {
              $dryRunTasksToDelegate = @()
              foreach ($role in @($delegationManifest.RequiredRoles)) {
                  $dryRunTasksToDelegate += [ordered]@{
                      role = $role
                      objective = [string]$task.objective
                      parallel_group = if ($task.PSObject.Properties.Name -contains 'parallel_group') { [string]$task.parallel_group } else { '' }
                      worktree = ''
                      context_packet = $contextPacketPath
                  }
              }
              $dryRunAgentTasks = Invoke-AgentManagerDelegation -ParentTaskId $TaskId -ParentTask $task -Tasks $dryRunTasksToDelegate
              Write-Host ($dryRunAgentTasks | ConvertTo-Json -Depth 30)
          }
          Write-PhaseLine 'P5' 'SKIP' ("Dry-run delegation plan: {0}" -f $(if ($delegationManifest -and @($delegationManifest.RequiredRoles).Count -gt 0) { @($delegationManifest.RequiredRoles) -join ', ' } else { 'none' }))
          $phases['P5'] = 'SKIP'
          Write-ExecutionTrace -TaskId $TaskId -Phase 'delegation' -Status 'skip' -Data @{
              reason = 'dry_run'
          } -RunId $RunId -CorrelationId $CorrelationId -Event 'phase.skip' -Actor $Agent | Out-Null
      }
      elseif ($delegationManifest -and @($delegationManifest.RequiredRoles).Count -gt 0) {
          # Phase 5: Enhanced Delegation with improved observability
          # REAL DELEGATION: Calls 'task' tool for single-role, 'parallel-runner.ps1' for multi-role
          # ENHANCED OBSERVABILITY: Structured trace events with run_id and correlation_id
          # FAILURE MODE TRACKING: Comprehensive failure tracking and analysis

          $policyChecks = @($delegationManifest.RequiredRoles | ForEach-Object {
              Get-DelegationPolicy -Role $_ -DelegationManifest $delegationManifest
          })
          $anyPolicyAllowed = @($policyChecks | Where-Object { $_.Allowed }).Count -gt 0

          if (-not $anyPolicyAllowed) {
              $deniedFor = @($policyChecks | Where-Object { -not $_.Allowed }).DeniedFor -join '; '
              $fallbackReason = "policy_denied_for:$deniedFor"

              $delegationPolicyDenied = $true
              Write-PhaseLine 'P5' 'WARN' ("Delegation denied by policy: {0}" -f $fallbackReason)
              Write-ExecutionTrace -TaskId $TaskId -Phase 'delegation' -Status 'policy_denied' -Data @{
                  policy_checks = $policyChecks
                  fallback_reason = $fallbackReason
              } -RunId $RunId -CorrelationId $CorrelationId -Event 'delegation.policy_denied' -Actor $Agent | Out-Null
              if (-not $DryRun) {
                  Update-SystemState -Key 'last_delegation' -Value ([ordered]@{
                      task_id = $TaskId
                      roles = @($delegationManifest.RequiredRoles)
                      mode = 'policy_denied'
                      reason = $fallbackReason
                      tasks = @()
                      timestamp = (Get-Date).ToString('o')
                  })
              }
          } else {
              # Policy allowed - proceed with real delegation
              $delegationResult = Invoke-RealDelegation -Manifest $delegationManifest -TaskId $TaskId -Objective [string]$task.objective -ContextPacketPath $contextPacketPath -RequiredRoles @($delegationManifest.RequiredRoles) -Parallel $useParallel -ParallelGroup $(if ($task.PSObject.Properties.Name -contains 'parallel_group') { [string]$task.parallel_group } else { '' }) -MaxAgents $MaxAgents -DryRun:$DryRun -ResearchReportPath $researchReportPath

              if ($delegationResult.invoked) {
                  Write-PhaseLine 'P5' 'DONE' ("Real delegation invoked for roles: {0}" -f $delegationResult.reason)
                  Write-OrchestratorUiStatus -TaskId $TaskId -RunId $RunId -Phase 'delegation' -ParallelGroup ($(if ($task.PSObject.Properties.Name -contains 'parallel_group') { [string]$task.parallel_group } else { '' })) -HealingStatus ($(if ($task.PSObject.Properties.Name -contains 'last_self_heal') { 'applied' } else { 'none' })) -VerificationStatus $verificationStatus -TraceEnabled:(-not $DryRun) -Summary ("delegated to: {0}" -f $($delegationResult.reason -replace "^.*: ", ''))

                  if (-not $DryRun) {
                      Update-SystemState -Key 'last_delegation' -Value ([ordered]@{
                          task_id = $TaskId
                          roles = @($delegationManifest.RequiredRoles)
                          mode = $delegationResult.mode
                          reason = $delegationResult.reason
                          tasks = $delegationResult.tasks
                          timestamp = (Get-Date).ToString('o')
                      })
                  }
              } else {
                  $fallbackReason = "delegation_not_invoked: $($delegationResult.reason)"

                  if (-not $DryRun) {
                      Update-SystemState -Key 'last_delegation' -Value ([ordered]@{
                          task_id = $TaskId
                          roles = @($delegationManifest.RequiredRoles)
                          mode = $delegationResult.mode
                          reason = $fallbackReason
                          tasks = @()
                          timestamp = (Get-Date).ToString('o')
                      })
                  }

                  Write-PhaseLine 'P5' 'WARN' ("Real delegation not invoked: {0}" -f $delegationResult.reason)
              }

              if (-not $delegationResult.invoked -and $delegationResult.reason -match 'policy_denied|denied_by_policy') {
                  $delegationPolicyDenied = $true
                  $fallbackReason = "delegation_denied:: $fallbackReason"
                  Write-PhaseLine 'P5' 'FAIL' ('Delegation blocked by policy: {0}' -f $fallbackReason)
                  Write-ExecutionTrace -TaskId $TaskId -Phase 'delegation' -Status 'failed' -Data @{
                      reason = $fallbackReason
                      mode = 'policy_denied'
                  } -RunId $RunId -CorrelationId $CorrelationId -Event 'phase.failed' -FailureMode 'delegation_policy_denied' -Actor $Agent | Out-Null
              }

              $autoDelegationInvoked = $delegationResult.invoked
              $phases['P5'] = 'DONE'
              Write-ExecutionTrace -TaskId $TaskId -Phase 'delegation' -Status 'done' -Data @{
                  auto_delegated_roles = if ($autoDelegationInvoked) { @($delegationManifest.RequiredRoles) } else { @() }
                  delegation_mode = $delegationResult.mode
                  delegation_reason = $delegationResult.reason
                  policy_denied = [bool]$delegationPolicyDenied
                  fallback_reason = $fallbackReason
              } -RunId $RunId -CorrelationId $CorrelationId -Event 'phase.done' -Actor $Agent | Out-Null
          }
      }
      elseif ($useParallel -and -not $delegationPolicyDenied) {
          # Parallel delegation via parallel-runner (which already invokes agent_manager internally)
          Write-ExecutionTrace -TaskId $TaskId -Phase 'delegation' -Status 'parallel_dispatch_attempt' -Data @{
              mode = if ($EnableParallel) { 'explicit_parallel' } else { 'auto_parallel' }
              max_agents = $MaxAgents
              auto_detected = [bool]($autoParallelDecision -and $autoParallelDecision.Eligible -and -not $EnableParallel)
              policy_allowed = -not $delegationPolicyDenied
          } -RunId $RunId -CorrelationId $CorrelationId -Event 'delegation.dispatch_attempt' -Actor $Agent | Out-Null
          $parallelArgs = @('-ParentTaskId', $TaskId, '-MaxAgents', $MaxAgents)
          if ($contextPacketPath) { $parallelArgs += @('-ContextPacketPath', $contextPacketPath) }
          $parallelOutput = Invoke-PhaseScript -ScriptPath $parallelScript -Arguments $parallelArgs
          Write-PhaseLine 'P5' 'DONE' 'Parallel delegation prepared'
          if ($parallelOutput) {
              Write-Host $parallelOutput
          }
          Write-OrchestratorUiStatus -TaskId $TaskId -RunId $RunId -Phase 'parallel' -ParallelGroup ($(if ($task.PSObject.Properties.Name -contains 'parallel_group') { [string]$task.parallel_group } else { '' })) -HealingStatus ($(if ($task.PSObject.Properties.Name -contains 'last_self_heal') { 'applied' } else { 'none' })) -VerificationStatus $verificationStatus -TraceEnabled:(-not $DryRun) -Summary 'parallel delegation prepared'
          $phases['P5'] = 'DONE'
          Write-ExecutionTrace -TaskId $TaskId -Phase 'delegation' -Status 'done' -Data @{
              mode = if ($EnableParallel) { 'explicit_parallel' } else { 'auto_parallel' }
          } -RunId $RunId -CorrelationId $CorrelationId -Event 'phase.done' -Actor $Agent | Out-Null
      }
      elseif (-not $delegationPolicyDenied) {
          Write-PhaseLine 'P5' 'DONE' 'Sequential delegation prepared'
          Write-OrchestratorUiStatus -TaskId $TaskId -RunId $RunId -Phase 'delegation' -ParallelGroup ($(if ($task.PSObject.Properties.Name -contains 'parallel_group') { [string]$task.parallel_group } else { '' })) -HealingStatus ($(if ($task.PSObject.Properties.Name -contains 'last_self_heal') { 'applied' } else { 'none' })) -VerificationStatus $verificationStatus -TraceEnabled:(-not $DryRun) -Summary 'delegation shim ready'
          $phases['P5'] = 'DONE'
          Write-ExecutionTrace -TaskId $TaskId -Phase 'delegation' -Status 'done' -Data @{
              mode = 'sequential'
          } -RunId $RunId -CorrelationId $CorrelationId -Event 'phase.done' -Actor $Agent | Out-Null
      } else {
          Write-PhaseLine 'P5' 'FAIL' ('Delegation blocked by policy: {0}' -f $fallbackReason)
          $phases['P5'] = 'FAIL'
          Write-ExecutionTrace -TaskId $TaskId -Phase 'delegation' -Status 'failed' -Data @{
              reason = $fallbackReason
              mode = 'policy_denied'
          } -RunId $RunId -CorrelationId $CorrelationId -Event 'phase.failed' -FailureMode 'delegation_policy_denied' -Actor $Agent | Out-Null
      }

    # Phase 6 - Monitoring
    if ($DryRun) {
        Write-PhaseLine 'P6' 'SKIP' 'Dry-run only'
        $phases['P6'] = 'SKIP'
    }
    elseif (Test-Path -LiteralPath $agentStatusScript) {
        Write-ExecutionTrace -TaskId $TaskId -Phase 'monitoring' -Status 'start' -Data @{
            mode = 'snapshot'
        } -RunId $RunId -CorrelationId $CorrelationId -Event 'phase.start' -Actor $Agent | Out-Null
        $agentStatusOutput = Invoke-PhaseScript -ScriptPath $agentStatusScript -Arguments @()
        $agentStatusText = ($agentStatusOutput | Out-String)
        if ($agentStatusText.Trim()) {
            Write-Host $agentStatusText
        }
        Write-PhaseLine 'P6' 'DONE' 'Agent status snapshot captured'
        $phases['P6'] = 'DONE'
        Write-ExecutionTrace -TaskId $TaskId -Phase 'monitoring' -Status 'done' -Data @{
            output = if ($agentStatusText) { $agentStatusText } else { '' }
        } -RunId $RunId -CorrelationId $CorrelationId -Event 'phase.done' -Actor $Agent | Out-Null
    } else {
        Write-PhaseLine 'P6' 'SKIP' 'agent-status script missing'
        $phases['P6'] = 'SKIP'
        Write-ExecutionTrace -TaskId $TaskId -Phase 'monitoring' -Status 'skip' -Data @{
            reason = 'script missing'
        } -RunId $RunId -CorrelationId $CorrelationId -Event 'phase.skip' -Actor $Agent | Out-Null
    }

    # Phase 7 - Verification and closure
    if ($DryRun) {
        Write-PhaseLine 'P7' 'SKIP' 'Dry-run only'
        $phases['P7'] = 'SKIP'
        $verificationStatus = 'SKIP'
    }
    elseif (Test-Path -LiteralPath $healthCheckScript) {
        Write-ExecutionTrace -TaskId $TaskId -Phase 'verification' -Status 'start' -Data @{
            mode = 'health-check'
        } -RunId $RunId -CorrelationId $CorrelationId -Event 'phase.start' -Actor $Agent | Out-Null
        $healthResult = & $healthCheckScript
        $healthOk = ($LASTEXITCODE -eq 0)
        $verificationStatus = if ($healthOk) { 'PASS' } else { 'FAIL' }

        if ($healthOk) {
            $checkpointState = [ordered]@{
                task_id = $TaskId
                objective = [string]$task.objective
                objective_summary = if ($task.objective.Length -gt 120) { $task.objective.Substring(0, 117) + '...' } else { [string]$task.objective }
                handoff_contract = $handoffContract
                context_packet = $contextPacketPath
                research_report = $researchReportPath
                phases = $phases
            }
            Invoke-OrchestratorScript -ScriptPath $checkpointScript -Arguments @(
                '-TaskId', $TaskId,
                '-Checkpoint', (($checkpointState | ConvertTo-Json -Compress -Depth 20))
            ) | Out-Null
            Invoke-OrchestratorScript -ScriptPath $updateTaskScript -Arguments @(
                '-TaskId', $TaskId,
                '-Status', 'completed'
            ) | Out-Null
            Invoke-OrchestratorScript -ScriptPath $recordDecisionScript -Arguments @(
                '-Topic', 'Verification',
                '-Problem', [string]$task.objective,
                '-Choice', 'PASS',
                '-Rationale', 'Health check passed and task closed',
                '-Task', $TaskId,
                '-Artifacts', @($contextPacketPath, $researchReportPath)
            ) | Out-Null
            if (-not $DryRun) {
                Sync-SystemStateFromTasks
            }
            Write-PhaseLine 'P7' 'DONE' 'Verification passed and task closed'
            $phases['P7'] = 'DONE'
            Write-OrchestratorUiStatus -TaskId $TaskId -RunId $RunId -Phase 'verification' -ParallelGroup ($(if ($task.PSObject.Properties.Name -contains 'parallel_group') { [string]$task.parallel_group } else { '' })) -HealingStatus ($(if ($task.PSObject.Properties.Name -contains 'last_self_heal') { 'applied' } else { 'none' })) -VerificationStatus 'pass' -TraceEnabled:(-not $DryRun) -Summary 'health check passed; task closed'
            Write-ExecutionTrace -TaskId $TaskId -Phase 'verification' -Status 'done' -Data @{
                verdict = 'PASS'
            } -RunId $RunId -CorrelationId $CorrelationId -Event 'phase.done' -Actor $Agent | Out-Null
        } else {
            Invoke-OrchestratorScript -ScriptPath $updateTaskScript -Arguments @(
                '-TaskId', $TaskId,
                '-Status', 'blocked'
            ) | Out-Null
            Write-ExecutionTrace -TaskId $TaskId -Phase 'verification' -Status 'failed' -Data @{
                reason = 'health-check failed'
            } -RunId $RunId -CorrelationId $CorrelationId -Event 'phase.failed' -FailureMode 'health_check_failed' -Actor $Agent | Out-Null
            Write-PhaseLine 'P7' 'FAIL' 'Health check failed'
            $phases['P7'] = 'FAIL'
            Write-OrchestratorUiStatus -TaskId $TaskId -RunId $RunId -Phase 'verification' -ParallelGroup ($(if ($task.PSObject.Properties.Name -contains 'parallel_group') { [string]$task.parallel_group } else { '' })) -HealingStatus ($(if ($task.PSObject.Properties.Name -contains 'last_self_heal') { 'applied' } else { 'none' })) -VerificationStatus 'fail' -TraceEnabled:(-not $DryRun) -Summary 'health check FAILED; task blocked'
        }
    } else {
        Write-PhaseLine 'P7' 'SKIP' 'Verification skipped in dry-run or script missing'
        $phases['P7'] = 'SKIP'
        $verificationStatus = 'SKIP'
        Write-ExecutionTrace -TaskId $TaskId -Phase 'verification' -Status 'skip' -Data @{
            reason = 'dry-run or script missing'
        } -RunId $RunId -CorrelationId $CorrelationId -Event 'phase.skip' -Actor $Agent | Out-Null
    }

if (-not $DryRun) {
         Update-SystemState -Key 'last_run' -Value ([ordered]@{
             task_id = $TaskId
             run_id = $RunId
             correlation_id = $CorrelationId
             verification = $verificationStatus
             context_packet = $contextPacketPath
             research_report = $researchReportPath
             parallel = [bool]$EnableParallel
             auto_parallel = [bool]($autoParallelDecision -and $autoParallelDecision.Eligible)
             auto_delegated = [bool]$autoDelegationInvoked
             delegation_roles = if ($delegationManifest) { @($delegationManifest.RequiredRoles) } else { @() }
             updated_at = (Get-Date).ToString('o')
         })

         Write-ExecutionTrace -TaskId $TaskId -Phase 'run' -Status 'done' -Data @{
             run_id = $RunId
             correlation_id = $CorrelationId
             verification = $verificationStatus
             context_packet = $contextPacketPath
             research_report = $researchReportPath
         } -RunId $RunId -CorrelationId $CorrelationId -Event 'run.done' -Actor $Agent | Out-Null
     }

     $finalVerifyLabel = ($verificationStatus.ToLower())
     Write-OrchestratorUiStatus -TaskId $TaskId -RunId $RunId -Phase 'complete' -ParallelGroup ($(if ($task.PSObject.Properties.Name -contains 'parallel_group') { [string]$task.parallel_group } else { '' })) -HealingStatus ($(if ($task.PSObject.Properties.Name -contains 'last_self_heal') { 'applied' } else { 'none' })) -VerificationStatus $finalVerifyLabel -TraceEnabled:(-not $DryRun) -Summary ("run complete · context:{0}" -f $(if ($contextPacketPath) { 'ready' } else { 'n/a' }))

     Write-Host ''
     Write-Host 'RUN SUMMARY' -ForegroundColor Magenta
     Write-Host ("  TaskId          : {0}" -f $TaskId)
     Write-Host ("  Verification    : {0}" -f $verificationStatus)
     Write-Host ("  Context Packet  : {0}" -f $(if ($contextPacketPath) { $contextPacketPath } else { 'n/a' }))
     Write-Host ("  Research Report : {0}" -f $(if ($researchReportPath) { $researchReportPath } else { 'n/a' }))
     Write-Host ("  Delegation Roles: {0}" -f $(if ($delegationManifest -and @($delegationManifest.RequiredRoles).Count -gt 0) { @($delegationManifest.RequiredRoles) -join ', ' } else { 'none' }))
     Write-Host ("  Trace file      : {0}" -f (Join-Path $tracesPath ("trace_{0}.jsonl" -f $TaskId)))

    exit 0
}
catch {
    if (-not $DryRun) {
        Write-ExecutionTrace -TaskId ($(if ($TaskId) { $TaskId } else { 'unknown' })) -Phase 'run' -Status 'failed' -Data @{
            error = $_.Exception.Message
        } -RunId $RunId -CorrelationId $CorrelationId -Event 'run.failed' -FailureMode 'orchestrator_failure' -Actor $Agent | Out-Null
    }
    Write-OrchestratorUiStatus -TaskId ($(if ($TaskId) { $TaskId } else { 'unknown' })) -RunId ($(if ($RunId) { $RunId } else { '' })) -Phase 'error' -ParallelGroup '' -HealingStatus 'none' -VerificationStatus 'fail' -TraceEnabled:(-not $DryRun) -Summary $_.Exception.Message
    Write-Host ''
    Write-Host 'PHASE RUNNER FAILED' -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}
