<#
.SYNOPSIS
Self-healing script for automatic error pattern corrections and handoff contract adjustments.
.DESCRIPTION
Reads error-patterns.md and generates concrete corrections for the next handoff contract:
- yaml_format_violation  -> adds "ONLY clean YAML" requirement to next prompt
- file_scope_violation   -> adds file_scope constraint to handoff contract
- missing_field          -> adds missing field validation to template
- test_failure           -> adds tests_run requirement
- contract_violation     -> adds constraints/success_criteria validation
- timeout                -> adds operation timeout handling
- permission_denied      -> adds permission escalation path
.PARAMETER Agent
Target agent name (required). Corrections are generated only for patterns matching this agent.
.PARAMETER TaskId
Task ID (optional). Used to tag adjustments for traceability.
.PARAMETER DryRun
Print adjustments without making changes or writing files.
.PARAMETER Apply
Generate adjustments and save them to a state file for phase-runner to consume.
.EXAMPLE
.\self-heal.ps1 -DryRun -Agent "coding-agent"
.\self-heal.ps1 -Agent "verification-agent" -TaskId "task_123" -Apply
.\self-heal.ps1 -Agent "coding-agent"
#>

[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$Apply,
    [string]$Agent,
    [string]$TaskId
)

# Determine which common.ps1 to use
$localCommon = Join-Path $PSScriptRoot 'common.ps1'
$globalCommon = if ($env:KILO_BASE) {
    Join-Path $env:KILO_BASE 'tools\memory-tools\scripts\common.ps1'
} elseif ($env:USERPROFILE) {
    Join-Path $env:USERPROFILE '.config\kilo\tools\memory-tools\scripts\common.ps1'
} else {
    ''
}
$commonPath = if (Test-Path $localCommon) { $localCommon } else { $globalCommon }

. $commonPath
Ensure-MemoryDirectories
$env:KILO_TRACE_WRITE = if ($DryRun) { '0' } else { '1' }

function Get-ErrorPatterns {
    param([string]$Path)
    
    if (-not (Test-Path $Path)) {
        Write-Log "Error patterns file not found: $Path" -Level 'WARN' -Component 'self-heal'
        return @()
    }
    
    $content = Get-Content $Path -Raw -Encoding UTF8
    $patterns = @{}
    
    # Parse Top Error Patterns section - match markdown table rows
    $patternMatches = [regex]::Matches($content, '^\| ([^|]+) \| ([^|]+) \| (\d+) \|', 'Multiline')
    foreach ($match in $patternMatches) {
        $agent = $match.Groups[1].Value.Trim()
        $errorType = $match.Groups[2].Value.Trim()
        $count = [int]$match.Groups[3].Value
        
        # Skip header/separator rows
        if ($agent -eq 'Agent' -or $errorType -eq 'Error Type') { continue }
        
        $key = "$agent|$errorType"
        if (-not $patterns.ContainsKey($key)) {
            $patterns[$key] = [ordered]@{
                agent = $agent
                error_type = $errorType
                count = $count
            }
        }
    }
    
    return @($patterns.Values)
}

function Get-PatternRemediation {
    param([string]$ErrorType)
    
    switch ($ErrorType) {
        'yaml_format_violation' {
            return 'add_reminder'
        }
        'file_scope_violation' {
            return 'narrow_scope'
        }
        'missing_field' {
            return 'add_field'
        }
        default {
            return 'no_action'
        }
    }
}

function Get-PreventiveHint {
    param([string]$ErrorType, [string]$TargetAgent)
    
    switch ($ErrorType) {
        'yaml_format_violation' {
            "Attention: $TargetAgent previously violated clean YAML output rule. " +
            "Mandatory: specify 'ONLY clean YAML without markdown wrappers' in prompt. " +
            "Start output immediately with `verification_report:` (or appropriate root)."
        }
        'file_scope_violation' {
            "Attention: $TargetAgent previously exceeded file_scope boundaries. " +
            "'Strict adherence to file_scope' is mandatory. If file change needed " +
            "outside scope - request permission from orchestrator."
        }
        'missing_field' {
            "Attention: $TargetAgent previously omitted required fields. " +
            "Before execution check: all required contract fields are filled. " +
            "If field missing - do not start work."
        }
        'test_failure' {
            "Attention: $TargetAgent previously created code with failing tests. " +
            "Mandatory: run tests before completion and specify tests_run: true/false."
        }
        'contract_violation' {
            "Attention: $TargetAgent previously violated handoff contract. " +
            "Thoroughly check all constraints and success_criteria before work."
        }
        default {
            "Note typical errors: check YAML format, file_scope, and required fields."
        }
    }
}

function Get-PromptAdjustmentLine {
    param([string]$ErrorType, [string]$TargetAgent)

    switch ($ErrorType) {
        'yaml_format_violation' {
            "REQUIREMENT: Output must be ONLY clean YAML. No markdown wrappers (no ```yaml), no comments, no preamble before `coding_result:`. Start immediately with root key."
        }
        'file_scope_violation' {
            "CONSTRAINT: Strict file_scope enforcement. Only modify files within the defined file_scope. Request permission from orchestrator before touching any file outside scope."
        }
        'missing_field' {
            "VALIDATION: Before execution, verify all required fields of the handoff contract are populated. Do not start work if any required field is missing - return status: blocked."
        }
        'test_failure' {
            "REQUIREMENT: Run tests before completion. Specify `tests_run: true/false` explicitly in the report. Never mark tests as passed without actually running them."
        }
        'contract_violation' {
            "REQUIREMENT: Thoroughly read and understand all constraints and success_criteria before starting. Cross-check each success_criterion against actual implementation before reporting."
        }
        'timeout' {
            "CONSTRAINT: Operations must complete within expected time limits. If a step takes too long, report it instead of silently skipping."
        }
        'permission_denied' {
            "CONSTRAINT: If a file or resource is inaccessible, report it immediately with details. Do not attempt to bypass access restrictions."
        }
        default {
            "GENERAL: Review YAML format, file_scope boundaries, and all required fields before submitting output."
        }
    }
}

function Get-RemediationAction {
    param(
        [string]$ErrorType,
        [string]$TargetAgent
    )

    switch ($ErrorType) {
        'yaml_format_violation' {
            [ordered]@{
                action_type = 'prompt_patch'
                target = "$TargetAgent prompt"
                severity = 'high'
                change = 'Enforce clean YAML only, no markdown fences, no preamble.'
            }
        }
        'file_scope_violation' {
            [ordered]@{
                action_type = 'contract_patch'
                target = "$TargetAgent handoff contract"
                severity = 'high'
                change = 'Add explicit file_scope boundary check before each edit.'
            }
        }
        'missing_field' {
            [ordered]@{
                action_type = 'contract_validation'
                target = "$TargetAgent preflight"
                severity = 'medium'
                change = 'Require required-field validation before work starts.'
            }
        }
        'test_failure' {
            [ordered]@{
                action_type = 'verification_gate'
                target = "$TargetAgent completion gate"
                severity = 'medium'
                change = 'Require explicit tests_run evidence before completion.'
            }
        }
        'contract_violation' {
            [ordered]@{
                action_type = 'contract_patch'
                target = "$TargetAgent handoff contract"
                severity = 'high'
                change = 'Strengthen constraints and success_criteria checks.'
            }
        }
        'timeout' {
            [ordered]@{
                action_type = 'runtime_guard'
                target = "$TargetAgent execution flow"
                severity = 'medium'
                change = 'Add timeout-aware stop conditions and escalation.'
            }
        }
        'permission_denied' {
            [ordered]@{
                action_type = 'escalation_guard'
                target = "$TargetAgent permission flow"
                severity = 'medium'
                change = 'Require immediate reporting and permission escalation.'
            }
        }
        default {
            [ordered]@{
                action_type = 'observe'
                target = "$TargetAgent general"
                severity = 'low'
                change = 'Record the error and continue observing.'
            }
        }
    }
}

function Get-HandoffContractAdjustment {
    param(
        [array]$Patterns,
        [string]$TargetAgent
    )

    $result = [ordered]@{
        prompt_lines     = @()
        contract_constraints = @()
        template_fields  = @()
        warnings         = @()
    }

    foreach ($pattern in $Patterns) {
        if ($pattern.agent -ne $TargetAgent) { continue }

        $et = $pattern.error_type
        $count = $pattern.count

        switch ($et) {
            'yaml_format_violation' {
                $result.prompt_lines += Get-PromptAdjustmentLine -ErrorType $et -TargetAgent $TargetAgent
                $result.warnings += "yaml_format_violation occurred $count times - strict YAML output required"
            }
            'file_scope_violation' {
                $result.contract_constraints += "Strict file_scope: modify ONLY files listed in file_scope. Request permission for any file outside scope."
                $result.warnings += "file_scope_violation occurred $count times - scope discipline required"
            }
            'missing_field' {
                $result.template_fields += "Verify all required handoff contract fields are populated before starting work (objective, context, constraints, success_criteria, output_format)"
                $result.warnings += "missing_field occurred $count times - field completeness required"
            }
            'test_failure' {
                $result.prompt_lines += Get-PromptAdjustmentLine -ErrorType $et -TargetAgent $TargetAgent
                $result.contract_constraints += "tests_run must be explicitly set to true or false in coding_result. Never claim tests passed without running them."
            }
            'contract_violation' {
                $result.prompt_lines += Get-PromptAdjustmentLine -ErrorType $et -TargetAgent $TargetAgent
                $result.contract_constraints += "Validate all handoff_contract constraints and success_criteria before and after execution."
            }
            'timeout' {
                $result.prompt_lines += Get-PromptAdjustmentLine -ErrorType $et -TargetAgent $TargetAgent
                $result.warnings += "timeout occurred $count times - operation timeout handling required"
            }
            'permission_denied' {
                $result.prompt_lines += Get-PromptAdjustmentLine -ErrorType $et -TargetAgent $TargetAgent
                $result.warnings += "permission_denied occurred $count times - permission escalation path needed"
            }
        }
    }

    # Remove duplicates
    $result.prompt_lines = $result.prompt_lines | Select-Object -Unique
    $result.contract_constraints = $result.contract_constraints | Select-Object -Unique
    $result.template_fields = $result.template_fields | Select-Object -Unique
    $result.warnings = $result.warnings | Select-Object -Unique

    return $result
}

function Format-AdjustmentForPrompt {
    param(
        [hashtable]$Adjustment
    )

    $lines = @()
    $lines += "=== SELF-HEALING ADJUSTMENTS FOR PROMPT ==="
    $lines += ""

    if ($Adjustment.prompt_lines.Count -gt 0) {
        $lines += "## Prompt Requirements (add to agent prompt):"
        $lines += ""
        $i = 1
        foreach ($pl in $Adjustment.prompt_lines) {
            $lines += "  $i. $pl"
            $i++
        }
        $lines += ""
    }

    if ($Adjustment.contract_constraints.Count -gt 0) {
        $lines += "## Handoff Contract Constraints (add to constraints list):"
        $lines += ""
        foreach ($cc in $Adjustment.contract_constraints) {
            $lines += "  - $cc"
        }
        $lines += ""
    }

    if ($Adjustment.template_fields.Count -gt 0) {
        $lines += "## Template Validations (add to pre-execution checks):"
        $lines += ""
        foreach ($tf in $Adjustment.template_fields) {
            $lines += "  - $tf"
        }
        $lines += ""
    }

    if ($Adjustment.warnings.Count -gt 0) {
        $lines += "## Warnings:"
        $lines += ""
        foreach ($w in $Adjustment.warnings) {
            $lines += "  ! $w"
        }
        $lines += ""
    }

    if ($Adjustment.prompt_lines.Count -eq 0 -and $Adjustment.contract_constraints.Count -eq 0 -and $Adjustment.template_fields.Count -eq 0) {
        $lines += "No specific adjustments needed - no repeated error patterns for this agent."
    }

    $lines += "=== END SELF-HEALING ADJUSTMENTS ==="
    return $lines -join "`n"
}

function Format-AdjustmentAsJson {
    param(
        [hashtable]$Adjustment
    )

    $obj = [ordered]@{
        agent             = $Agent
        task_id           = $TaskId
        generated_at      = (Get-Date -Format 'o')
        prompt_lines          = @($Adjustment.prompt_lines | Where-Object { $_ -ne $null })
        contract_constraints  = @($Adjustment.contract_constraints | Where-Object { $_ -ne $null })
        template_fields       = @($Adjustment.template_fields | Where-Object { $_ -ne $null })
        warnings              = @($Adjustment.warnings | Where-Object { $_ -ne $null })
    }
    return $obj | ConvertTo-Json -Depth 5 -Compress
}

function Get-NextPromptAdjustment {
    param([array]$Patterns, [string]$TargetAgent)
    
    $adjustments = @()
    
    foreach ($pattern in $Patterns) {
        if ($pattern.agent -eq $TargetAgent -or -not $TargetAgent) {
            $remediation = Get-PatternRemediation -ErrorType $pattern.error_type
            $adjustment = [ordered]@{
                error_type = $pattern.error_type
                remediation = $remediation
                hint = Get-PreventiveHint -ErrorType $pattern.error_type -TargetAgent $TargetAgent
                count = $pattern.count
            }
            $adjustments += $adjustment
        }
    }
    
    return $adjustments
}

function Build-RemediationPlan {
    param(
        [array]$Patterns,
        [string]$TargetAgent
    )
    $actions = @()
    foreach ($pattern in $Patterns) {
        if ($pattern.agent -ne $TargetAgent -and $TargetAgent) { continue }
        $action = Get-RemediationAction -ErrorType $pattern.error_type -TargetAgent $TargetAgent
        $action.error_type = $pattern.error_type
        $action.count = $pattern.count
        $action.agent = $TargetAgent
        $actions += $action
    }

    $summary = [ordered]@{
        agent = $TargetAgent
        generated_at = (Get-Date).ToString('o')
        pattern_count = $actions.Count
        actions = $actions
        prompt_adjustments = @(Get-NextPromptAdjustment -Patterns $Patterns -TargetAgent $TargetAgent)
    }

    return [pscustomobject]$summary
}

# Main execution
Write-Log "Starting self-heal analysis" -Level 'INFO' -Component 'self-heal'

$errorPatternsPath = Get-GlobalErrorPatternsPath
Write-Log "Error patterns path: $errorPatternsPath" -Level 'DEBUG' -Component 'self-heal'

$patterns = Get-ErrorPatterns -Path $errorPatternsPath
if ($patterns.Count -eq 0) {
    Write-Log "No error patterns found" -Level 'INFO' -Component 'self-heal'
    Write-Host "No error patterns found in $errorPatternsPath" -ForegroundColor Yellow
    exit 0
}

Write-Log "Loaded $($patterns.Count) error patterns" -Level 'INFO' -Component 'self-heal'

if (-not $Agent) {
    Write-Host "Error: -Agent parameter is required for self-healing adjustments." -ForegroundColor Red
    Write-Host "Usage: .\self-heal.ps1 -Agent <agent-name> [-DryRun|-Apply] [-TaskId <id>]" -ForegroundColor Gray
    exit 1
}

$adjustment = Get-HandoffContractAdjustment -Patterns $patterns -TargetAgent $Agent
$remediationPlan = Build-RemediationPlan -Patterns $patterns -TargetAgent $Agent
$selfHealRunId = "selfheal_$(Get-Date -Format yyyyMMddHHmmss)_$([guid]::NewGuid().ToString('N').Substring(0,8))"
$env:KILO_RUN_ID = $selfHealRunId
$env:KILO_TRACE_ACTOR = 'self-heal'

if ($DryRun) {
    Write-Host "=== DRY RUN MODE ===" -ForegroundColor Yellow
    Write-Host ""
    $promptText = Format-AdjustmentForPrompt -Adjustment $adjustment
    Write-Host $promptText
    Write-Host ""
    Write-Host "=== JSON OUTPUT ===" -ForegroundColor DarkGray
    Write-OrchestratorUiStatus -TaskId ($(if ($TaskId) { $TaskId } else { 'self-heal' })) -RunId $selfHealRunId -Phase 'healing' -ParallelGroup '' -HealingStatus 'pending' -VerificationStatus 'pending' -TraceEnabled:$false -Summary ("patterns matched: {0}" -f @($remediationPlan.actions).Count)
    $dryObj = [ordered]@{
        agent = $Agent
        task_id = $TaskId
        generated_at = (Get-Date -Format 'o')
        remediation = $remediationPlan
        prompt_adjustment = $adjustment
    }
    Write-Host ($dryObj | ConvertTo-Json -Depth 10 -Compress)
    Write-ExecutionTrace -TaskId ($(if ($TaskId) { $TaskId } else { 'self-heal' })) -Phase 'self-heal' -Status 'generated' -Data @{
        agent = $Agent
        run_id = $selfHealRunId
        action_count = @($remediationPlan.actions).Count
    } -RunId $selfHealRunId -CorrelationId (New-TraceCorrelationId -TaskId ($(if ($TaskId) { $TaskId } else { 'self-heal' })) -RunId $selfHealRunId) -Event 'self_heal.generated' -Actor 'self-heal' | Out-Null
    exit 0
}

if ($Apply) {
    Write-Host "=== APPLY MODE ===" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Self-healing adjustments for agent: $Agent" -ForegroundColor White
    Write-Host "Task ID: $TaskId" -ForegroundColor Gray
    Write-Host ""
    $promptText = Format-AdjustmentForPrompt -Adjustment $adjustment
    Write-Host $promptText
    Write-Host ""

    # Store remediation plan and prompt adjustments for phase-runner to pick up
    $selfHealDir = Join-Path (Get-GlobalSelfHealingPath) 'remediation-plans'
    if (-not (Test-Path $selfHealDir)) {
        New-Item -ItemType Directory -Path $selfHealDir -Force | Out-Null
    }
    $selfHealStatePath = Join-Path $selfHealDir "self-heal-remediation_$Agent.json"
    $stateObj = [ordered]@{
        agent             = $Agent
        task_id           = $TaskId
        updated_at        = (Get-Date -Format 'o')
        run_id            = $selfHealRunId
        remediation       = $remediationPlan
        prompt_lines      = @($adjustment.prompt_lines)
        contract_constraints = @($adjustment.contract_constraints)
        template_fields   = @($adjustment.template_fields)
        warnings          = @($adjustment.warnings)
        apply_status      = 'ready'
    }
    $stateObj | ConvertTo-Json -Depth 5 | Set-Content -Path $selfHealStatePath -Encoding UTF8
    & "$PSScriptRoot\user-profile.ps1" -Action record-task-completion -TaskId ($TaskId if ($TaskId) { $TaskId } else { 'self-heal' }) -TaskType 'self_heal' -Priority 'medium' -Agent $Agent -Objective 'Self-healing applied' | Out-Null
    Update-SystemState -Key 'last_self_heal' -Value [ordered]@{
        agent = $Agent
        task_id = $TaskId
        run_id = $selfHealRunId
        updated_at = (Get-Date).ToString('o')
        error_patterns = @($patterns.Count)
        state_path = $selfHealStatePath
        remediation = $remediationPlan
    }
    Write-Host "Adjustments saved to: $selfHealStatePath" -ForegroundColor Green
    Write-OrchestratorUiStatus -TaskId ($(if ($TaskId) { $TaskId } else { 'self-heal' })) -RunId $selfHealRunId -Phase 'healing' -ParallelGroup '' -HealingStatus 'applied' -VerificationStatus 'pending' -TraceEnabled:$true -Summary ("remediation plan saved: {0}" -f $selfHealStatePath)
    Write-Log "Self-heal adjustments applied and saved for $Agent" -Level 'INFO' -Component 'self-heal'
    Write-ExecutionTrace -TaskId ($(if ($TaskId) { $TaskId } else { 'self-heal' })) -Phase 'self-heal' -Status 'applied' -Data @{
        agent = $Agent
        run_id = $selfHealRunId
        state_path = $selfHealStatePath
        warnings = @($adjustment.warnings)
        remediation = $remediationPlan
    } -RunId $selfHealRunId -CorrelationId (New-TraceCorrelationId -TaskId ($(if ($TaskId) { $TaskId } else { 'self-heal' })) -RunId $selfHealRunId) -Event 'self_heal.applied' -Actor 'self-heal' | Out-Null
    exit 0
}

# Default: output adjustments as JSON for machine consumption
$jsonOutput = Format-AdjustmentAsJson -Adjustment $adjustment
Write-Output ([ordered]@{
    agent = $Agent
    task_id = $TaskId
    generated_at = (Get-Date -Format 'o')
    remediation = $remediationPlan
    prompt_adjustment = $adjustment
} | ConvertTo-Json -Depth 10 -Compress)

foreach ($adj in $adjustment.warnings) {
    Write-Log "Self-heal: $adj" -Level 'INFO' -Component 'self-heal'
}

Write-ExecutionTrace -TaskId ($(if ($TaskId) { $TaskId } else { 'self-heal' })) -Phase 'self-heal' -Status 'generated' -Data @{
    agent = $Agent
    run_id = $selfHealRunId
    warnings = @($adjustment.warnings)
    remediation = $remediationPlan
} -RunId $selfHealRunId -CorrelationId (New-TraceCorrelationId -TaskId ($(if ($TaskId) { $TaskId } else { 'self-heal' })) -RunId $selfHealRunId) -Event 'self_heal.generated' -Actor 'self-heal' | Out-Null

exit 0
