<#
.SYNOPSIS
Analyzes agent error patterns from JSONL log and generates a markdown report.
.DESCRIPTION
Reads ~/.kilocode/global/self-healing/agent-errors.jsonl by default (or project-level), identifies repeated errors by agent,
error type frequency, task-specific patterns, and generates error-patterns.md in the same location.
.PARAMETER Global
Switch to use global path. Default is true.
#>

param(
    [Parameter(Mandatory=$false)][int]$MinCount = 2,
    [switch]$DryRun,
    [switch]$Help,
    [bool]$Global = $true
)

. "$PSScriptRoot\common.ps1"

# Resolve paths: global takes priority
$script:AgentErrorsPath = if ($Global) { 
    Get-GlobalErrorLogPath 
} else { 
    Join-Path (Get-MemoryPath) 'agent-errors.jsonl' 
}
$script:OutputPath = if ($Global) { 
    Get-GlobalErrorPatternsPath 
} else { 
    Join-Path (Get-MemoryPath) 'error-patterns.md' 
}

function Show-HelpMessage {
    Write-Host ''
    Write-Host 'AGENT ERROR PATTERN ANALYZER (Global Self-Healing)' -ForegroundColor Cyan
    Write-Host ''
    Write-Host 'Parameters:' -ForegroundColor White
    Write-Host '  -MinCount <number>                Minimum occurrence count for pattern inclusion (default: 2)' -ForegroundColor Gray
    Write-Host '  -Global <bool>                    Use global path (default: true)' -ForegroundColor Gray
    Write-Host '  -DryRun                          Print report to console without writing file' -ForegroundColor Gray
    Write-Host '  -Help                            Show this help' -ForegroundColor Gray
    Write-Host ''
    Write-Host "Input (global):  $(Get-GlobalErrorLogPath)" -ForegroundColor DarkGray
    Write-Host "Input (project): $(Join-Path (Get-MemoryPath) 'agent-errors.jsonl')" -ForegroundColor DarkGray
    Write-Host "Output (global): $(Get-GlobalErrorPatternsPath)" -ForegroundColor DarkGray
    Write-Host "Output (project): $(Join-Path (Get-MemoryPath) 'error-patterns.md')" -ForegroundColor DarkGray
    Write-Host ''
}

if ($Help) {
    Show-HelpMessage
    exit 0
}

function Test-FileAvailable {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        Write-Host "[$(Get-Date -Format 'o')] [WARN] Error log file not found: $Path" -ForegroundColor Yellow
        return $false
    }
    $content = Get-Content $Path -Raw -ErrorAction SilentlyContinue
    if (-not $content -or -not $content.Trim()) {
        Write-Host "[$(Get-Date -Format 'o')] [WARN] Error log file is empty: $Path" -ForegroundColor Yellow
        return $false
    }
    return $true
}

function Get-ErrorEntries {
    param([string]$Path)
    $entries = @()
    $lines = Get-Content $Path -Encoding UTF8
    foreach ($line in $lines) {
        if (-not $line -or -not $line.Trim()) { continue }
        try {
            $entries += $line.Trim() | ConvertFrom-Json
        } catch {
            Write-Host "[$(Get-Date -Format 'o')] [WARN] Skipping invalid JSONL line: $_" -ForegroundColor Yellow
        }
    }
    return $entries
}

function New-EmptyReport {
    return @{
        summary = @{
            total_errors = 0
            unique_agents = 0
            unique_error_types = 0
            unique_tasks = 0
            date_range = 'N/A'
        }
        top_error_patterns = @()
        agent_error_counts = @{}
        error_type_counts = @{}
        repeated_errors = @()
        recommendations = @('No error data available for analysis.')
    }
}

function Build-Report {
    param(
        [array]$Entries,
        [int]$MinCount
    )

    if (-not $Entries -or $Entries.Count -eq 0) {
        return New-EmptyReport
    }

    $timestamps = $Entries | ForEach-Object { [datetime]$_.timestamp } | Where-Object { $_ -ne $null } | Sort-Object
    $dateStart = if ($timestamps.Count -gt 0) { $timestamps[0].ToString('yyyy-MM-dd') } else { 'N/A' }
    $dateEnd = if ($timestamps.Count -gt 0) { $timestamps[-1].ToString('yyyy-MM-dd') } else { 'N/A' }

    $agentCounts = @{}
    $typeCounts = @{}
    $taskCounts = @{}
    $repeatedKeyCounts = @{}

    foreach ($entry in $Entries) {
        $agent = $entry.agent
        $errorType = $entry.error_type
        $taskId = $entry.task_id

        if ($agent) {
            if ($agentCounts.ContainsKey($agent)) { $agentCounts[$agent]++ } else { $agentCounts[$agent] = 1 }
        }
        if ($errorType) {
            if ($typeCounts.ContainsKey($errorType)) { $typeCounts[$errorType]++ } else { $typeCounts[$errorType] = 1 }
        }
        if ($taskId) {
            if ($taskCounts.ContainsKey($taskId)) { $taskCounts[$taskId]++ } else { $taskCounts[$taskId] = 1 }
        }

        $compositeKey = "$agent|$errorType"
        if ($agent -and $errorType) {
            if ($repeatedKeyCounts.ContainsKey($compositeKey)) { $repeatedKeyCounts[$compositeKey]++ } else { $repeatedKeyCounts[$compositeKey] = 1 }
        }
    }

    $totalErrors = $Entries.Count
    $uniqueAgents = ($agentCounts.Keys | Measure-Object).Count
    $uniqueTypes = ($typeCounts.Keys | Measure-Object).Count
    $uniqueTasks = ($taskCounts.Keys | Measure-Object).Count

    $topTypes = $typeCounts.GetEnumerator() | Sort-Object Value -Descending | Where-Object { $_.Value -ge $MinCount }
    $topAgents = $agentCounts.GetEnumerator() | Sort-Object Value -Descending | Where-Object { $_.Value -ge $MinCount }
    $topTasks = $taskCounts.GetEnumerator() | Sort-Object Value -Descending | Where-Object { $_.Value -ge $MinCount }

    $topPatterns = @()
    foreach ($kv in ($repeatedKeyCounts.GetEnumerator() | Sort-Object Value -Descending)) {
        if ($kv.Value -lt $MinCount) { continue }
        $parts = $kv.Key -split '\|'
        $topPatterns += [ordered]@{
            agent = $parts[0]
            error_type = $parts[1]
            count = $kv.Value
        }
    }

    $recommendations = @()
    if ($topPatterns.Count -gt 0) {
        foreach ($pattern in ($topPatterns | Select-Object -First 5)) {
            $recommendations += "Address repeated errors for agent '$($pattern.agent)' with error type '$($pattern.error_type)' (count: $($pattern.count)). Consider updating agent prompt or instructions."
        }
    }

    $highFreqTypes = $topTypes | Where-Object { $_.Value -gt ($totalErrors * 0.2) }
    foreach ($t in $highFreqTypes) {
        $recommendations += "Error type '$($t.Key)' accounts for $($t.Value) errors. Review system-wide handling of this error type."
    }

    if ($uniqueAgents -gt 1 -and $agentCounts.Count -gt 0) {
        $maxAgent = $agentCounts.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 1
        $minAgent = $agentCounts.GetEnumerator() | Sort-Object Value | Select-Object -First 1
        if ($maxAgent.Value -gt ($minAgent.Value * 2)) {
            $recommendations += "Error distribution across agents is skewed. Investigate why '$($maxAgent.Key)' has significantly more errors ($($maxAgent.Value)) than '$($minAgent.Key)' ($($minAgent.Value))."
        }
    }

    if ($recommendations.Count -eq 0) {
        $recommendations += 'No significant patterns detected requiring immediate action.'
    }

    $report = [ordered]@{
        summary = [ordered]@{
            total_errors = $totalErrors
            unique_agents = $uniqueAgents
            unique_error_types = $uniqueTypes
            unique_tasks = $uniqueTasks
            date_range = "$dateStart to $dateEnd"
        }
        top_error_patterns = $topPatterns
        agent_error_counts = [ordered]@{}
        error_type_counts = [ordered]@{}
        repeated_errors = $topPatterns
        recommendations = $recommendations
    }

    foreach ($kv in ($agentCounts.GetEnumerator() | Sort-Object Value -Descending)) {
        if ($kv.Value -ge $MinCount) {
            $report.agent_error_counts[$kv.Key] = $kv.Value
        }
    }
    foreach ($kv in ($typeCounts.GetEnumerator() | Sort-Object Value -Descending)) {
        if ($kv.Value -ge $MinCount) {
            $report.error_type_counts[$kv.Key] = $kv.Value
        }
    }

    return $report
}

function Convert-ToMarkdown {
    param([hashtable]$Report)

    $md = @()
    $md += '# Error Pattern Analysis Report'
    $md += ''
    $md += "**Generated:** $(Get-Date -Format 'o')"
    $md += ''
    $md += '## Summary Statistics'
    $md += ''
    $md += "| Metric | Value |"
    $md += "|--------|-------|"
    $md += "| Total Errors | $($Report.summary.total_errors) |"
    $md += "| Unique Agents | $($Report.summary.unique_agents) |"
    $md += "| Unique Error Types | $($Report.summary.unique_error_types) |"
    $md += "| Unique Tasks | $($Report.summary.unique_tasks) |"
    $md += "| Date Range | $($Report.summary.date_range) |"
    $md += ''

    $md += '## Agent Error Counts'
    $md += ''
    if ($Report.agent_error_counts.Count -gt 0) {
        $md += '| Agent | Count |'
        $md += '|-------|-------|'
        foreach ($kv in $Report.agent_error_counts.GetEnumerator()) {
            $md += "| $($kv.Key) | $($kv.Value) |"
        }
    } else {
        $md += '_No agent errors meeting MinCount threshold._'
    }
    $md += ''

    $md += '## Error Type Counts'
    $md += ''
    if ($Report.error_type_counts.Count -gt 0) {
        $md += '| Error Type | Count |'
        $md += '|------------|-------|'
        foreach ($kv in $Report.error_type_counts.GetEnumerator()) {
            $md += "| $($kv.Key) | $($kv.Value) |"
        }
    } else {
        $md += '_No error types meeting MinCount threshold._'
    }
    $md += ''

    $md += '## Top Error Patterns (Agent + Error Type)'
    $md += ''
    if ($Report.top_error_patterns.Count -gt 0) {
        $md += '| Agent | Error Type | Count |'
        $md += '|-------|------------|-------|'
        foreach ($p in $Report.top_error_patterns) {
            $md += "| $($p.agent) | $($p.error_type) | $($p.count) |"
        }
    } else {
        $md += '_No repeated error patterns meeting MinCount threshold._'
    }
    $md += ''

    $md += '## Recommendations'
    $md += ''
    foreach ($rec in $Report.recommendations) {
        $md += "- $rec"
    }
    $md += ''
    $md += '_End of report._'
    $md += ''

    return $md -join "`n"
}

try {
    if (-not (Test-FileAvailable -Path $script:AgentErrorsPath)) {
        $report = New-EmptyReport
        $markdown = Convert-ToMarkdown -Report $report
        if ($DryRun) {
            Write-Host $markdown
            exit 0
        }
        $dir = Split-Path $script:OutputPath -Parent
        if (-not (Test-Path $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        $markdown | Set-Content -Path $script:OutputPath -Encoding UTF8
        Write-Host "[$(Get-Date -Format 'o')] [INFO] No errors found. Empty report written to $script:OutputPath" -ForegroundColor Green
        Write-Output $script:OutputPath
        exit 0
    }

    $entries = Get-ErrorEntries -Path $script:AgentErrorsPath
    Write-Host "[$(Get-Date -Format 'o')] [INFO] Loaded $($entries.Count) error entries from $script:AgentErrorsPath" -ForegroundColor Green

    $report = Build-Report -Entries $entries -MinCount $MinCount
    $markdown = Convert-ToMarkdown -Report $report

    if ($DryRun) {
        Write-Host $markdown
        exit 0
    }

    $dir = Split-Path $script:OutputPath -Parent
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $markdown | Set-Content -Path $script:OutputPath -Encoding UTF8
    Write-Host "[$(Get-Date -Format 'o')] [INFO] Pattern analysis report written to $script:OutputPath" -ForegroundColor Green
    Write-Output $script:OutputPath
    exit 0
} catch {
    Write-Host "[$(Get-Date -Format 'o')] [ERROR] Failed to analyze error patterns: $_" -ForegroundColor Red
    exit 1
}
