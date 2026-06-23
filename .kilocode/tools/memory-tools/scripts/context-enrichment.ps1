<#
.SYNOPSIS
    Assembles a rich Context Packet for task delegation in the Executive Orchestrator cycle.

.DESCRIPTION
    context-enrichment.ps1 collects data from multiple sources (tasks.jsonl, decisions.jsonl,
    user-profile.jsonl, research-reports, task dependencies) and assembles a structured Context
    Packet according to the template defined in executive-orchestrator.md. The packet is saved
    to .kilocode/memory/context-enrichment/<TaskId>.md and returned for use in subagent prompts.

.PARAMETER TaskId
    The task identifier from tasks.jsonl. Required.

.PARAMETER IncludeResearch
    Switch to include research report data.

.PARAMETER IncludeUserProfile
    Switch to include user profile preferences.

.PARAMETER IncludeRecentDecisions
    Number of recent decisions to include (default 5). Use 0 to skip.

.PARAMETER MaxContextSize
    Maximum character size for the context packet (default 8000).

.PARAMETER Role
    Override the role for the context packet (research | coding | verification | memory | review).
    If not specified, extracted from task.type.

.PARAMETER UserRequest
    Override the user_request field. If not specified, uses task.objective.

.PARAMETER Force
    Overwrite existing context packet file if it already exists.

.EXAMPLE
    & ".\.kilocode\tools\memory-tools\scripts\context-enrichment.ps1" -TaskId task_123

.EXAMPLE
    & ".\.kilocode\tools\memory-tools\scripts\context-enrichment.ps1" -TaskId task_456 -IncludeResearch -IncludeUserProfile -IncludeRecentDecisions 10 -MaxContextSize 12000

.EXAMPLE
    & ".\.kilocode\tools\memory-tools\scripts\context-enrichment.ps1" -TaskId task_789 -Role coding -Force
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$TaskId,

    [switch]$IncludeResearch,

    [switch]$IncludeUserProfile,

    [int]$IncludeRecentDecisions = 5,

    [int]$MaxContextSize = 8000,

    [ValidateSet('research', 'coding', 'verification', 'memory', 'review')]
    [string]$Role,

    [string]$UserRequest,

    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

# Dot source common.ps1 for shared paths and functions
. "$PSScriptRoot\common.ps1"

# ─── Path Resolution ──────────────────────────────────────────────────────────

$tasksPath = Get-TasksPath
$decisionsJsonlPath = Get-DecisionsJsonlPath
$userProfilePath = Get-UserProfilePath
$contextEnrichmentPath = Get-ContextEnrichmentPath
$researchReportsPath = Get-ResearchReportsPath

# Ensure output directory exists
if (-not (Test-Path $contextEnrichmentPath)) {
    New-Item -ItemType Directory -Path $contextEnrichmentPath -Force | Out-Null
}

# Ensure global self-healing directory exists
$globalSelfHealingPath = Get-GlobalSelfHealingPath
if (-not (Test-Path $globalSelfHealingPath)) {
    New-Item -ItemType Directory -Path $globalSelfHealingPath -Force | Out-Null
}

# Tracking for summary report
$script:CollectedSources = New-Object System.Collections.Generic.List[string]
$script:ValidationWarnings = New-Object System.Collections.Generic.List[string]

# ─── Helpers ──────────────────────────────────────────────────────────────────

function Write-Info {
    param([string]$Message)
    Write-Log -Message $Message -Level 'INFO' -Component 'context-enrichment'
    $script:CollectedSources.Add($Message) | Out-Null
}

function Add-UniqueString {
    param(
        [System.Collections.Generic.List[string]]$List,
        [string]$Value
    )
    if (-not $Value) { return }
    $clean = $Value.Trim()
    if ($clean -and -not $List.Contains($clean)) {
        $List.Add($clean) | Out-Null
    }
}

function Format-YamlStringArray {
    param([System.Collections.Generic.List[string]]$Items)
    if ($Items -eq $null -or $Items.Count -eq 0) { return '' }
    $escaped = @()
    foreach ($item in $Items) {
        $escaped += '"' + (Escape-YamlString $item) + '"'
    }
    return ($escaped -join ', ')
}

function Escape-YamlString {
    param([string]$Text)
    if (-not $Text) { return '' }
    $Text = $Text -replace '\\', '\\\\'
    $Text = $Text -replace '"', '\"'
    $Text = $Text -replace [char]13, ''
    $Text = $Text -replace [char]10, ' '
    return $Text
}

# ─── Get-TaskById ─────────────────────────────────────────────────────────────

function Get-TaskById {
    param(
        [string]$Id,
        [string]$Path
    )

    if (-not (Test-Path $Path)) {
        Write-Log "Tasks file not found: $Path" -Level 'WARN' -Component 'context-enrichment'
        return $null
    }

    $tasks = Read-Jsonl -Path $Path
    if ($tasks -is [array]) {
        foreach ($t in $tasks) {
            if ($t.task_id -eq $Id) { return $t }
        }
    }
    return $null
}

# ─── Get-RecentDecisions ──────────────────────────────────────────────────────

function Get-RecentDecisions {
    param(
        [int]$Count,
        [string]$Path
    )

    if (-not (Test-Path $Path) -or $Count -le 0) {
        return @()
    }

    $decisions = Read-Jsonl -Path $Path
    if ($decisions.Count -eq 0) { return @() }

    $sorted = $decisions | Sort-Object { $_.timestamp } -Descending
    return @($sorted | Select-Object -First $Count)
}

# ─── Find-ResearchReports ─────────────────────────────────────────────────────

function Find-ResearchReports {
    param(
        [string]$Id,
        [string]$ReportsPath
    )

    if (-not (Test-Path $ReportsPath)) {
        return @()
    }

    $allReports = Get-ChildItem -Path $ReportsPath -Filter '*.md' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '\d{8}_\d{4}_' } |
        Sort-Object LastWriteTime -Descending

    if ($allReports.Count -eq 0) { return @() }

    # Try to find reports mentioning the task ID
    $taskReports = @()
    foreach ($r in $allReports) {
        $content = Get-Content $r.FullName -Raw -ErrorAction SilentlyContinue
        if ($content -and $content -match [regex]::Escape($Id)) {
            $taskReports += $r
        }
    }

    # Fall back to most recent reports if no task-specific match
    if ($taskReports.Count -eq 0) {
        $taskReports = @($allReports | Select-Object -First 3)
    }

    return $taskReports
}

# ─── Get-ResearchFindings (IMPROVED) ──────────────────────────────────────────

function Get-ResearchFindings {
    param([string]$Content)

    $findings = New-Object System.Collections.Generic.List[string]
    $risks = New-Object System.Collections.Generic.List[string]
    $sources = New-Object System.Collections.Generic.List[string]
    $gaps = New-Object System.Collections.Generic.List[string]

    if (-not $Content) {
        return [pscustomobject]@{
            sources  = $sources
            findings = $findings
            risks    = $risks
            gaps     = $gaps
        }
    }

    # ── Extract sources from ## Sources → ### External Sources ──
    $inSources = $false
    $inExtSources = $false
    $lines = $Content -split "`n"
    foreach ($line in $lines) {
        $trimmed = $line.Trim()
        if ($trimmed -match '^##\s+Sources') {
            $inSources = $true
            $inExtSources = $false
            continue
        }
        if ($inSources -and $trimmed -match '^###\s+External Sources') {
            $inExtSources = $true
            continue
        }
        if ($inSources -and $trimmed -match '^##\s+') {
            $inSources = $false
            $inExtSources = $false
            continue
        }
        if ($inExtSources -and $trimmed -match '^\s*-\s*') {
            $urlMatch = [regex]::Match($trimmed, 'https?://[^\s\)\]]+')
            if ($urlMatch.Success) {
                Add-UniqueString -List $sources -Value ($urlMatch.Value.TrimEnd('/'))
            }
        }
    }

    # Fallback: extract all URLs from content if no structured sources found
    if ($sources.Count -eq 0) {
        $urlMatches = [regex]::Matches($Content, 'https?://[^\s\)\]]+')
        foreach ($match in $urlMatches) {
            if ($sources.Count -ge 10) { break }
            Add-UniqueString -List $sources -Value ($match.Value.TrimEnd('/'))
        }
    }

    # ── Extract findings from ## Key Findings ──
    $sectionContent = Get-MarkdownSection -Content $Content -Heading 'Key Findings'
    if ($sectionContent) {
        $sectionLines = $sectionContent -split "`n"
        foreach ($line in $sectionLines) {
            if ($findings.Count -ge 5) { break }
            $item = $line -replace '^\s*[-*]\s*', ''
            $item = $item -replace '\r', ''
            $item = $item.Trim()
            if ($item) {
                Add-UniqueString -List $findings -Value $item
            }
        }
    }

    # ── Extract risks from ## Risks & Limitations (or ## Risks) ──
    $risksContent = Get-MarkdownSection -Content $Content -Heading 'Risks'
    if ($risksContent) {
        $risksLines = $risksContent -split "`n"
        foreach ($line in $risksLines) {
            if ($risks.Count -ge 3) { break }
            $item = $line -replace '^\s*[-*]\s*', ''
            $item = $item -replace '\r', ''
            $item = $item.Trim()
            if ($item) {
                Add-UniqueString -List $risks -Value $item
            }
        }
    }

    # ── Extract gaps from ## Gaps ──
    $gapsContent = Get-MarkdownSection -Content $Content -Heading 'Gaps'
    if ($gapsContent) {
        $gapsLines = $gapsContent -split "`n"
        foreach ($line in $gapsLines) {
            if ($gaps.Count -ge 3) { break }
            $item = $line -replace '^\s*[-*]\s*', ''
            $item = $item -replace '\r', ''
            $item = $item.Trim()
            if ($item) {
                Add-UniqueString -List $gaps -Value $item
            }
        }
    }

    return [pscustomobject]@{
        sources  = $sources
        findings = $findings
        risks    = $risks
        gaps     = $gaps
    }
}

function Get-MarkdownSection {
    param(
        [string]$Content,
        [string]$Heading
    )

    $lines = $Content -split "`n"
    $inSection = $false
    $sectionLines = @()

    foreach ($line in $lines) {
        $trimmed = $line.Trim()

        # Check if this is our target heading
        if ($trimmed -match ('^##\s+' + [regex]::Escape($Heading))) {
            $inSection = $true
            continue
        }

        # Check if this is the next ## heading (end of our section)
        if ($inSection -and $trimmed -match '^##\s+') {
            break
        }

        if ($inSection) {
            $sectionLines += $line
        }
    }

    if ($sectionLines.Count -eq 0) { return $null }
    return ($sectionLines -join "`n")
}

# ─── Get-TaskDependencies (NEW) ───────────────────────────────────────────────

function Get-TaskDependencies {
    param(
        [string]$Id,
        [string]$Path
    )

    $result = [pscustomobject]@{
        depends_on    = @()
        dependents    = @()
        ready_status  = 'unknown'
        blocked_by    = @()
    }

    if (-not (Test-Path $Path)) {
        Write-Log "Tasks file not found for dependency analysis: $Path" -Level 'WARN' -Component 'context-enrichment'
        return $result
    }

    $allTasks = Read-Jsonl -Path $Path
    if ($allTasks.Count -eq 0) { return $result }

    # Find the target task
    $targetTask = $null
    foreach ($t in $allTasks) {
        if ($t.task_id -eq $Id) {
            $targetTask = $t
            break
        }
    }

    if (-not $targetTask) {
        Write-Log "Task $Id not found for dependency analysis" -Level 'WARN' -Component 'context-enrichment'
        return $result
    }

    # Direct dependencies (depends_on) — normalize to array
    if ($targetTask.PSObject.Properties['depends_on']) {
        $rawDeps = $targetTask.depends_on
        if ($rawDeps -is [string]) {
            $rawDeps = $rawDeps -split ',' | ForEach-Object { $_.Trim() }
        }
        $deps = @($rawDeps | ForEach-Object { [string]$_ } | Where-Object { $_ -and $_ -notin @('True','False','None','null','true','false','none') })
        $result.depends_on = $deps
    }

    # Reverse dependencies (tasks that depend on this task)
    $reverseDeps = @()
    foreach ($t in $allTasks) {
        if ($t.task_id -eq $Id) { continue }
        if ($t.PSObject.Properties['depends_on']) {
            $rawDeps = $t.depends_on
            if ($rawDeps -is [string]) {
                $rawDeps = $rawDeps -split ',' | ForEach-Object { $_.Trim() }
            }
            $tDeps = @($rawDeps | ForEach-Object { [string]$_ } | Where-Object { $_ -and $_ -notin @('True','False','None','null','true','false','none') })
            if ($tDeps -contains $Id) {
                $reverseDeps += $t.task_id
            }
        }
    }
    $result.dependents = $reverseDeps

    # Determine ready status
    if ($result.depends_on.Count -eq 0) {
        $result.ready_status = 'ready (no dependencies)'
    } else {
        $allTaskIds = @($allTasks | ForEach-Object { $_.task_id })
        $pendingDeps = @()
        foreach ($depId in $result.depends_on) {
            $depTask = $null
            foreach ($t in $allTasks) {
                if ($t.task_id -eq $depId) {
                    $depTask = $t
                    break
                }
            }
            if (-not $depTask) {
                $pendingDeps += "$depId(MISSING)"
            } elseif ($depTask.status -ne 'completed') {
                $pendingDeps += "$depId($($depTask.status))"
            }
        }
        $result.blocked_by = $pendingDeps
        if ($pendingDeps.Count -eq 0) {
            $result.ready_status = 'ready (all deps completed)'
        } else {
            $result.ready_status = "blocked ($($pendingDeps.Count) pending)"
        }
    }

    return $result
}

# ─── New-ContextPacketYaml (REWRITTEN) ────────────────────────────────────────

function New-ContextPacketYaml {
    param(
        [string]$PktTaskId,
        [string]$PktRole,
        [string]$PktObjective,
        [string]$PktUserRequest,
        [object]$ResearchData,
        [array]$RecentDecisions,
        [object]$UserProfile,
        [object]$TaskDependencies,
        [System.Collections.Generic.List[string]]$RelevantPaths,
        [string]$ReadyStatus,
        [string[]]$Constraints,
        [string[]]$SuccessCriteria,
        [string]$OutputFormat,
        [System.Collections.Generic.List[string]]$SelfHealHints
    )

    # ── Top-level keys ──
    $yaml = 'context_packet:' + [Environment]::NewLine

    # task_id
    $yaml += '  task_id: "' + (Escape-YamlString $PktTaskId) + '"' + [Environment]::NewLine

    # role
    $yaml += '  role: "' + (Escape-YamlString $PktRole) + '"' + [Environment]::NewLine

    # objective
    $yaml += '  objective: "' + (Escape-YamlString $PktObjective) + '"' + [Environment]::NewLine

    # user_request
    $yaml += '  user_request: "' + (Escape-YamlString $PktUserRequest) + '"' + [Environment]::NewLine

    # ── research section ──
    $hasResearch = ($ResearchData.sources.Count -gt 0) -or ($ResearchData.findings.Count -gt 0)
    $requiredBool = if ($hasResearch) { 'true' } else { 'false' }
    $yaml += '  research:' + [Environment]::NewLine
    $yaml += '    required: ' + $requiredBool + [Environment]::NewLine
    $yaml += '    sources: [' + (Format-YamlStringArray $ResearchData.sources) + ']' + [Environment]::NewLine
    $yaml += '    findings: [' + (Format-YamlStringArray $ResearchData.findings) + ']' + [Environment]::NewLine
    $yaml += '    risks: [' + (Format-YamlStringArray $ResearchData.risks) + ']' + [Environment]::NewLine
    $yaml += '    gaps: [' + (Format-YamlStringArray $ResearchData.gaps) + ']' + [Environment]::NewLine

    # ── project_context section ──
    $yaml += '  project_context:' + [Environment]::NewLine
    $yaml += '    relevant_paths: [' + (Format-YamlStringArray $RelevantPaths) + ']' + [Environment]::NewLine

    # recent_decisions
    $decisionStrings = New-Object System.Collections.Generic.List[string]
    if ($RecentDecisions) {
        foreach ($dec in @($RecentDecisions)) {
            $topic = if ($dec.topic) { $dec.topic } else { 'unknown' }
            $choice = if ($dec.choice) { $dec.choice } else { 'unknown' }
            $summary = (Escape-YamlString $topic) + ': ' + (Escape-YamlString $choice)
            $decisionStrings.Add($summary) | Out-Null
        }
    }
    $yaml += '    recent_decisions: [' + (Format-YamlStringArray $decisionStrings) + ']' + [Environment]::NewLine

    # user_preferences
    $prefStrings = New-Object System.Collections.Generic.List[string]
    if ($UserProfile) {
        if ($UserProfile.preferences) {
            if ($UserProfile.preferences.coding_style) {
                $prefStrings.Add('coding_style=' + (Escape-YamlString $UserProfile.preferences.coding_style)) | Out-Null
            }
            if ($UserProfile.preferences.models -and $UserProfile.preferences.models.Count -gt 0) {
                $modelsStr = ($UserProfile.preferences.models -join ', ')
                $prefStrings.Add('models=' + (Escape-YamlString $modelsStr)) | Out-Null
            }
        }
        if ($UserProfile.project_context) {
            $pc = $UserProfile.project_context
            if ($pc.workspace) {
                $prefStrings.Add('workspace=' + (Escape-YamlString $pc.workspace)) | Out-Null
            }
            if ($pc.language) {
                $prefStrings.Add('language=' + (Escape-YamlString $pc.language)) | Out-Null
            }
            if ($pc.framework) {
                $prefStrings.Add('framework=' + (Escape-YamlString $pc.framework)) | Out-Null
            }
        }
    }
    $yaml += '    user_preferences: [' + (Format-YamlStringArray $prefStrings) + ']' + [Environment]::NewLine

    # ── constraints ──
    $constraintStrings = New-Object System.Collections.Generic.List[string]
    if ($Constraints) {
        foreach ($c in @($Constraints)) {
            if ($c) { $constraintStrings.Add((Escape-YamlString $c)) | Out-Null }
        }
    }
    $yaml += '  constraints: [' + (Format-YamlStringArray $constraintStrings) + ']' + [Environment]::NewLine

    # ── dependencies section ──
    $yaml += '  dependencies:' + [Environment]::NewLine
    $depsList = New-Object System.Collections.Generic.List[string]
    if ($TaskDependencies -and $TaskDependencies.depends_on -and $TaskDependencies.depends_on.Count -gt 0) {
        foreach ($d in @($TaskDependencies.depends_on)) {
            if ($d) { $depsList.Add((Escape-YamlString $d)) | Out-Null }
        }
    }
    if ($depsList.Count -eq 0) {
        $depsList.Add('none') | Out-Null
    }
    $yaml += '    depends_on: [' + (Format-YamlStringArray $depsList) + ']' + [Environment]::NewLine
    $yaml += '    ready_verified_by: "' + (Escape-YamlString $ReadyStatus) + '"' + [Environment]::NewLine

    # ── success_criteria ──
    $yaml += '  success_criteria:' + [Environment]::NewLine
    $criteria = New-Object System.Collections.Generic.List[string]
    if ($SuccessCriteria -and $SuccessCriteria.Count -gt 0) {
        foreach ($sc in @($SuccessCriteria)) {
            if ($sc) { $criteria.Add((Escape-YamlString $sc)) | Out-Null }
        }
    }
    if ($criteria.Count -eq 0) {
        $criteria.Add('Context packet assembled and validated') | Out-Null
        $criteria.Add('All required fields populated') | Out-Null
    }
    foreach ($c in $criteria) {
        $yaml += '    - "' + $c + '"' + [Environment]::NewLine
    }

    # ── self_healing_hints section ──
    $yaml += '  self_healing_hints:' + [Environment]::NewLine
    if ($SelfHealHints -and $SelfHealHints.Count -gt 0) {
        foreach ($hint in $SelfHealHints) {
            $yaml += '    - "' + (Escape-YamlString $hint) + '"' + [Environment]::NewLine
        }
    } else {
        $yaml += '    - "No known error patterns for this agent."' + [Environment]::NewLine
    }

    # ── output_format ──
    $fmt = if ($OutputFormat) { $OutputFormat } else { 'markdown' }
    $yaml += '  output_format: "' + (Escape-YamlString $fmt) + '"' + [Environment]::NewLine

    # ── stop_conditions ──
    $yaml += '  stop_conditions:' + [Environment]::NewLine
    $yaml += '    - "Stop if blocked by missing dependency."' + [Environment]::NewLine
    $yaml += '    - "Stop if required evidence is unavailable."' + [Environment]::NewLine
    $yaml += '    - "Stop if the task scope changes."' + [Environment]::NewLine

    return $yaml
}

# ─── Test-ContextPacket (NEW) ─────────────────────────────────────────────────

function Test-ContextPacket {
    param(
        [string]$PktTaskId,
        [string]$PktObjective,
        [hashtable]$ResearchData,
        [System.Collections.Generic.List[string]]$SuccessCriteria
    )

    $isValid = $true

    # Verify task_id is non-empty
    if (-not $PktTaskId -or -not $PktTaskId.Trim()) {
        $msg = 'Validation failed: task_id is empty'
        Write-Log $msg -Level 'WARN' -Component 'context-enrichment'
        $script:ValidationWarnings.Add($msg) | Out-Null
        $isValid = $false
    }

    # Verify objective is non-empty
    if (-not $PktObjective -or -not $PktObjective.Trim()) {
        $msg = 'Validation failed: objective is empty'
        Write-Log $msg -Level 'WARN' -Component 'context-enrichment'
        $script:ValidationWarnings.Add($msg) | Out-Null
        $isValid = $false
    }

    # Verify success_criteria has at least 1 item
    if ($SuccessCriteria -eq $null -or $SuccessCriteria.Count -eq 0) {
        $msg = 'Validation failed: success_criteria is empty'
        Write-Log $msg -Level 'WARN' -Component 'context-enrichment'
        $script:ValidationWarnings.Add($msg) | Out-Null
        $isValid = $false
    }

    # If research has sources or findings, verify they are present
    if ($ResearchData) {
        $hasResearch = ($ResearchData['sources'] -and $ResearchData['sources'].Count -gt 0) -or
                       ($ResearchData['findings'] -and $ResearchData['findings'].Count -gt 0)
        if (-not $hasResearch) {
            $msg = 'Validation warning: research.required is true but no sources or findings found'
            Write-Log $msg -Level 'WARN' -Component 'context-enrichment'
            $script:ValidationWarnings.Add($msg) | Out-Null
        }
    }

    return $isValid
}

# ─── Truncate-ToSize (IMPROVED: smart truncation) ─────────────────────────────

function Truncate-ToSize {
    param(
        [string]$Text,
        [int]$MaxSize
    )

    if ($Text.Length -le $MaxSize) { return $Text }

    # Smart truncation: try to preserve YAML structure
    # First, try truncating at the last complete stop_conditions entry
    $truncated = $Text.Substring(0, $MaxSize)

    # Find the last complete line
    $lastNewline = $truncated.LastIndexOf("`n")
    if ($lastNewline -gt 0) {
        $truncated = $truncated.Substring(0, $lastNewline)
    }

    # Ensure stop_conditions are always present
    if ($truncated -notmatch 'stop_conditions:') {
        $truncated += [Environment]::NewLine
        $truncated += '  stop_conditions:' + [Environment]::NewLine
        $truncated += '    - "Stop if blocked by missing dependency."' + [Environment]::NewLine
        $truncated += '    - "Stop if required evidence is unavailable."' + [Environment]::NewLine
        $truncated += '    - "Stop if the task scope changes."' + [Environment]::NewLine
    } else {
        # stop_conditions header exists but may be incomplete — ensure all 3 entries
        $scIdx = $truncated.IndexOf('stop_conditions:')
        $afterSc = $truncated.Substring($scIdx)
        $scCount = ([regex]::Matches($afterSc, 'Stop if')).Count
        if ($scCount -lt 3) {
            # Rebuild stop_conditions from the header position
            $beforeSc = $truncated.Substring(0, $scIdx)
            $truncated = $beforeSc + 'stop_conditions:' + [Environment]::NewLine
            $truncated += '    - "Stop if blocked by missing dependency."' + [Environment]::NewLine
            $truncated += '    - "Stop if required evidence is unavailable."' + [Environment]::NewLine
            $truncated += '    - "Stop if the task scope changes."' + [Environment]::NewLine
        }
    }

    return $truncated
}

# ─── Write-SummaryReport (NEW) ────────────────────────────────────────────────

function Write-SummaryReport {
    param(
        [string]$OutputPath,
        [int]$PacketSize,
        [int]$MaxSize,
        [bool]$IsValid,
        [int]$FindingsCount,
        [int]$RisksCount,
        [int]$SourcesCount,
        [int]$GapsCount,
        [int]$DecisionsCount,
        [int]$DepsCount,
        [int]$DependentsCount
    )

    Write-Host ''
    Write-Host '=== CONTEXT ENRICHMENT SUMMARY ===' -ForegroundColor Cyan
    Write-Host ''

    Write-Host '  Collected Sources:' -ForegroundColor Gray
    foreach ($src in $script:CollectedSources) {
        Write-Host ('    - {0}' -f $src) -ForegroundColor DarkGray
    }

    Write-Host ''
    Write-Host '  Research Data:' -ForegroundColor Gray
    Write-Host ('    Findings: {0}' -f $FindingsCount) -ForegroundColor DarkGray
    Write-Host ('    Risks:    {0}' -f $RisksCount) -ForegroundColor DarkGray
    Write-Host ('    Sources:  {0}' -f $SourcesCount) -ForegroundColor DarkGray
    Write-Host ('    Gaps:     {0}' -f $GapsCount) -ForegroundColor DarkGray

    Write-Host ''
    Write-Host '  Context Data:' -ForegroundColor Gray
    Write-Host ('    Recent decisions: {0}' -f $DecisionsCount) -ForegroundColor DarkGray
    Write-Host ('    Dependencies:     {0}' -f $DepsCount) -ForegroundColor DarkGray
    Write-Host ('    Dependents:       {0}' -f $DependentsCount) -ForegroundColor DarkGray

    Write-Host ''
    Write-Host '  Packet Info:' -ForegroundColor Gray
    Write-Host ('    Size: {0} / {1} chars' -f $PacketSize, $MaxSize) -ForegroundColor DarkGray
    $sizeColor = if ($PacketSize -le $MaxSize) { 'Green' } else { 'Yellow' }
    Write-Host ('    Status: {0}' -f $(if ($PacketSize -le $MaxSize) { 'within limit' } else { 'truncated' })) -ForegroundColor $sizeColor

    Write-Host ''
    if ($IsValid) {
        Write-Host '  Validation: PASSED' -ForegroundColor Green
    } else {
        Write-Host '  Validation: WARNINGS' -ForegroundColor Yellow
    }

    if ($script:ValidationWarnings.Count -gt 0) {
        foreach ($warn in $script:ValidationWarnings) {
            Write-Host ('    ! {0}' -f $warn) -ForegroundColor Yellow
        }
    }

    Write-Host ''
    Write-Host ('  Output: {0}' -f $OutputPath) -ForegroundColor Green
    Write-Host ''
}

# ═══════════════════════════════════════════════════════════════════════════════
# MAIN EXECUTION
# ═══════════════════════════════════════════════════════════════════════════════

Write-Info "Starting context enrichment for task $TaskId"

# ── Step 1: Read task from tasks.jsonl ────────────────────────────────────────

$task = Get-TaskById -Id $TaskId -Path $tasksPath
if (-not $task) {
    Write-Log "Task $TaskId not found in tasks.jsonl" -Level 'ERROR' -Component 'context-enrichment'
    Write-Error "Task $TaskId not found in tasks.jsonl"
    exit 1
}
Write-Info "Collected task: $($task.task_id) ($($task.type))"

# ── Step 2: Check if packet already exists ────────────────────────────────────

$outputFile = Join-Path $contextEnrichmentPath "${TaskId}.md"
if ((Test-Path $outputFile) -and -not $Force) {
    Write-Info "Context packet already exists at $outputFile. Use -Force to overwrite."
    Write-Host "Context packet already exists. Use -Force to overwrite: $outputFile" -ForegroundColor Yellow
    Write-Output $outputFile
    exit 0
}

# ── Step 3: Determine role ────────────────────────────────────────────────────

$packetRole = if ($Role) { $Role } elseif ($task.PSObject.Properties['type']) { $task.PSObject.Properties['type'].Value } else { 'memory' }
if (-not $packetRole) { $packetRole = 'memory' }
Write-Info "Role: $packetRole"

# ── Step 4: Get objective and user request ────────────────────────────────────

$objective = if ($task.PSObject.Properties['objective']) { $task.PSObject.Properties['objective'].Value } else { 'No objective specified' }
$userRequestText = if ($UserRequest) { $UserRequest } else { $objective }
Write-Info "Objective: $objective"

# ── Step 5: Collect research data ─────────────────────────────────────────────

$researchData = [pscustomobject]@{
    sources  = New-Object System.Collections.Generic.List[string]
    findings = New-Object System.Collections.Generic.List[string]
    risks    = New-Object System.Collections.Generic.List[string]
    gaps     = New-Object System.Collections.Generic.List[string]
}

if ($IncludeResearch) {
    $reports = Find-ResearchReports -Id $TaskId -ReportsPath $researchReportsPath
    foreach ($report in $reports) {
        Write-Info "Found research report: $($report.Name)"
        $content = Get-Content $report.FullName -Raw -ErrorAction SilentlyContinue
        if ($content) {
            $extracted = Get-ResearchFindings -Content $content
            foreach ($s in $extracted.sources)  { Add-UniqueString -List $researchData.sources -Value $s }
            foreach ($f in $extracted.findings) { Add-UniqueString -List $researchData.findings -Value $f }
            foreach ($r in $extracted.risks)    { Add-UniqueString -List $researchData.risks -Value $r }
            foreach ($g in $extracted.gaps)     { Add-UniqueString -List $researchData.gaps -Value $g }
        }
    }
    Write-Info "Research findings: $($researchData.findings.Count), risks: $($researchData.risks.Count), sources: $($researchData.sources.Count), gaps: $($researchData.gaps.Count)"
} else {
    Write-Info "Research collection skipped (-IncludeResearch not set)"
}

# ── Step 6: Collect recent decisions ──────────────────────────────────────────

$recentDecisions = @()
if ($IncludeRecentDecisions -gt 0) {
    $recentDecisions = Get-RecentDecisions -Count $IncludeRecentDecisions -Path $decisionsJsonlPath
    Write-Info "Collected $($recentDecisions.Count) recent decisions"
} else {
    Write-Info "Recent decisions collection skipped (IncludeRecentDecisions = 0)"
}

# ── Step 7: Collect user profile ──────────────────────────────────────────────

$userProfile = $null
if ($IncludeUserProfile) {
    if (Test-Path "$PSScriptRoot\user-profile.ps1") {
        try {
            $profileJson = & "$PSScriptRoot\user-profile.ps1" -Action read 2>$null
            if ($profileJson) {
                $userProfile = $profileJson | ConvertFrom-Json -ErrorAction SilentlyContinue
                Write-Info "Collected user profile"
            }
        } catch {
            Write-Log "Could not read user profile: $_" -Level 'WARN' -Component 'context-enrichment'
        }
    }
} else {
    Write-Info "User profile collection skipped (-IncludeUserProfile not set)"
}

# ── Step 8: Collect task dependencies (full graph) ────────────────────────────

$taskDeps = Get-TaskDependencies -Id $TaskId -Path $tasksPath
$readyStatus = $taskDeps.ready_status

if ($taskDeps.depends_on.Count -gt 0) {
    Write-Info "Task dependencies: $($taskDeps.depends_on -join ', ')"
} else {
    Write-Info "Task has no dependencies"
}

if ($taskDeps.dependents.Count -gt 0) {
    Write-Info "Reverse dependencies: $($taskDeps.dependents -join ', ')"
}

if ($taskDeps.blocked_by.Count -gt 0) {
    Write-Info "Blocked by: $($taskDeps.blocked_by -join ', ')"
}

Write-Info "Ready status: $readyStatus"

# ── Step 9: Build relevant paths ─────────────────────────────────────────────

$relevantPaths = New-Object System.Collections.Generic.List[string]
$relevantPaths.Add('.kilocode/modes/executive-orchestrator.md') | Out-Null
$relevantPaths.Add('.kilocode/tools/memory-tools/scripts/common.ps1') | Out-Null
$relevantPaths.Add('.kilocode/memory/decisions.jsonl') | Out-Null
$relevantPaths.Add('.kilocode/memory/user-profile.jsonl') | Out-Null
$relevantPaths.Add('.kilocode/memory/tasks.jsonl') | Out-Null

# Add research report paths
$reportsForPaths = Find-ResearchReports -Id $TaskId -ReportsPath $researchReportsPath
foreach ($report in $reportsForPaths) {
    $relPath = $report.FullName.Replace((Get-BasePath), '.').Replace('\', '/')
    if (-not $relPath.StartsWith('.')) {
        $relPath = '.' + $relPath
    }
    Add-UniqueString -List $relevantPaths -Value $relPath
}

# Add task-specific paths from task object
    if ($task.PSObject.Properties['relevant_paths']) {
        foreach ($rp in @($task.PSObject.Properties['relevant_paths'].Value)) {
            if ($rp) { Add-UniqueString -List $relevantPaths -Value $rp }
        }
    }

# ── Step 10: Build constraints from task ──────────────────────────────────────

$constraints = @()
if ($task.PSObject.Properties['constraints']) {
    foreach ($c in @($task.PSObject.Properties['constraints'].Value)) {
        if ($c) { $constraints += [string]$c }
    }
}
if ($taskDeps.blocked_by.Count -gt 0) {
    $constraints += 'Task is blocked by unresolved dependencies'
}

# ── Step 11: Build success criteria from task ─────────────────────────────────

$successCriteria = @()
if ($task.PSObject.Properties['success_criteria']) {
    foreach ($sc in @($task.PSObject.Properties['success_criteria'].Value)) {
        if ($sc) { $successCriteria += [string]$sc }
    }
}
if ($successCriteria.Count -eq 0) {
    $successCriteria += 'Context packet assembled and validated'
    $successCriteria += 'All required fields populated'
}

# ── Step 11.5: Collect self-healing hints ──────────────────────────────────────

$selfHealHints = New-Object System.Collections.Generic.List[string]
$errorPatternsPath = Get-GlobalErrorPatternsPath
if (Test-Path -LiteralPath $errorPatternsPath) {
    try {
        $patternsContent = Get-Content -LiteralPath $errorPatternsPath -Raw -ErrorAction SilentlyContinue
        if ($patternsContent) {
            # Extract agent-specific recommendations
            $agentName = if ($task.assigned_agent) { $task.assigned_agent } else { '' }
            $hintAgent = if ($Role) { $Role } else { $agentName }
            
            # Parse recommendations section
            $recMatch = [regex]::Match($patternsContent, '## Recommendations\s*\n(.*?)(?=\n##|\Z)', 'Singleline')
            if ($recMatch.Success) {
                $recLines = $recMatch.Groups[1].Value -split "`n"
                foreach ($line in $recLines) {
                    $clean = $line.Trim()
                    if ($clean -match '^\s*-\s*(.+)') {
                        $hintText = $matches[1].Trim()
                        # Filter hints relevant to current agent
                        if ($hintText -match $hintAgent -or -not $hintAgent -or $hintAgent -eq '') {
                            $selfHealHints.Add($hintText) | Out-Null
                        }
                    }
                }
            }
            Write-Info "Collected $($selfHealHints.Count) self-healing hints for agent '$hintAgent'"
        }
    } catch {
        Write-Log "Could not read error-patterns.md: $_" -Level 'WARN' -Component 'context-enrichment'
    }
} else {
    Write-Info "No error-patterns.md found at $errorPatternsPath"
}

# ── Step 12: Determine output format ──────────────────────────────────────────

$outputFormat = 'markdown'
if ($task.PSObject.Properties['output_format']) {
    $outputFormat = $task.PSObject.Properties['output_format'].Value
}

# ── Step 13: Build Context Packet YAML ────────────────────────────────────────

$packet = New-ContextPacketYaml `
    -PktTaskId $TaskId `
    -PktRole $packetRole `
    -PktObjective $objective `
    -PktUserRequest $userRequestText `
    -ResearchData $researchData `
    -RecentDecisions $recentDecisions `
    -UserProfile $userProfile `
    -TaskDependencies $taskDeps `
    -RelevantPaths $relevantPaths `
    -ReadyStatus $readyStatus `
    -Constraints $constraints `
    -SuccessCriteria $successCriteria `
    -OutputFormat $outputFormat `
    -SelfHealHints $selfHealHints

# ── Step 14: Validate packet ─────────────────────────────────────────────────

$validationData = @{
    'sources'  = $researchData.sources
    'findings' = $researchData.findings
}
$isValid = Test-ContextPacket `
    -PktTaskId $TaskId `
    -PktObjective $objective `
    -ResearchData $validationData `
    -SuccessCriteria $successCriteria

if ($isValid) {
    Write-Info 'Context packet validation: PASSED'
} else {
    Write-Log 'Context packet validation: WARNINGS (see summary)' -Level 'WARN' -Component 'context-enrichment'
}

# ── Step 15: Truncate if needed ───────────────────────────────────────────────

$originalSize = $packet.Length
$packet = Truncate-ToSize -Text $packet -MaxSize $MaxContextSize
if ($packet.Length -lt $originalSize) {
    Write-Info "Packet truncated from $originalSize to $($packet.Length) chars (max: $MaxContextSize)"
} else {
    Write-Info "Final packet size: $($packet.Length) chars (max: $MaxContextSize)"
}

# ── Step 16: Save to file ────────────────────────────────────────────────────

$generatedTime = Get-Date -Format 'o'
$fullContent = [Environment]::NewLine
$fullContent += '# Context Enrichment Packet' + [Environment]::NewLine + [Environment]::NewLine
$fullContent += '- Generated: ' + $generatedTime + [Environment]::NewLine
$fullContent += '- Target task: ' + $TaskId + [Environment]::NewLine
$assignedAgent = if ($task.PSObject.Properties['assigned_agent']) { $task.PSObject.Properties['assigned_agent'].Value } else { 'unassigned' }
$fullContent += '- Target agent: ' + $assignedAgent + [Environment]::NewLine
$fullContent += '- Role: ' + $packetRole + [Environment]::NewLine
$fullContent += '- Research included: ' + $IncludeResearch.ToString() + [Environment]::NewLine
$fullContent += '- User profile included: ' + $IncludeUserProfile.ToString() + [Environment]::NewLine
$fullContent += '- Self-healing hints: ' + $(if ($selfHealHints.Count -gt 0) { 'included' } else { 'none' }) + [Environment]::NewLine
$fullContent += [Environment]::NewLine
$fullContent += '```yaml' + [Environment]::NewLine
$fullContent += $packet
$fullContent += '```' + [Environment]::NewLine

Set-Content -Path $outputFile -Value $fullContent -Encoding UTF8 -Force

# ── Step 17: Output summary ───────────────────────────────────────────────────

Write-SummaryReport `
    -OutputPath $outputFile `
    -PacketSize $packet.Length `
    -MaxSize $MaxContextSize `
    -IsValid $isValid `
    -FindingsCount $researchData.findings.Count `
    -RisksCount $researchData.risks.Count `
    -SourcesCount $researchData.sources.Count `
    -GapsCount $researchData.gaps.Count `
    -DecisionsCount $recentDecisions.Count `
    -DepsCount $taskDeps.depends_on.Count `
    -DependentsCount $taskDeps.dependents.Count

# Return the file path
Write-Output $outputFile

exit 0
