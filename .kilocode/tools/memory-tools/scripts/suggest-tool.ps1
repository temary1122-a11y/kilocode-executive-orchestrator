<#
.SYNOPSIS
Self-Diagnostic Tool - analyzes workflow gaps and suggests improvements
.DESCRIPTION
Records situations where tools are missing or errors occurred, and suggests solutions.
.USAGE
.\suggest-tool.ps1 -Problem "Need to parse JSON schema" -Context "Validation step failed" -Suggestion "Install ajv or use jq"
.PARAMETER Problem
What was missing or what error occurred
.PARAMETER Context
The context/task where it happened
.PARAMETER Suggestion
What tool/skill could help
.PARAMETER Task
Current task_id for correlation
#>

param(
    [Parameter(Mandatory=$true)][string]$Problem,
    [Parameter(Mandatory=$true)][string]$Context,
    [Parameter(Mandatory=$true)][string]$Suggestion,
    [string]$Task = ""
)

. "$PSScriptRoot\common.ps1"

$topicsPath = Join-Path (Get-MemoryPath) "topics.md"
$decisionsMdPath = Get-DecisionsMdPath
$decisionsJsonlPath = Get-DecisionsJsonlPath

# Ensure topics file exists
if (-not (Test-Path $topicsPath)) {
    "# Orchestrator Topics`n`n" | Set-Content $topicsPath
}

$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
$entry = @"
### $timestamp - Diagnostic: $Problem

**Context:** $Context
**Suggestion:** $Suggestion
**Status:** pending
"@

if ($Task) { $entry += "`n**Task:** $Task" }

Add-Content -Path $topicsPath -Value $entry

Write-Host "Diagnostic recorded. Suggested: $Suggestion" -ForegroundColor Cyan

# Also log to decisions.jsonl
$record = [ordered]@{
    id          = [System.Guid]::NewGuid().ToString("N").Substring(0,8)
    timestamp   = (Get-Date -Format "o")
    topic       = "Tool Needed: $Problem"
    problem     = $Problem
    choice      = $Suggestion
    rationale   = "Identified during workflow - $Context"
    task        = $Task
}
$record | ConvertTo-Json -Compress | Add-Content -Path $decisionsJsonlPath

exit 0