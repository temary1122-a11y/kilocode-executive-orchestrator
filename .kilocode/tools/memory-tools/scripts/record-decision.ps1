<#
.SYNOPSIS
Record decision to decisions.md with clear structure
.EXAMPLE
.\record-decision.ps1 -Topic "Memory Tools" -Problem "Agents couldn't track tasks" -Choice "PowerShell scripts" -Rationale "Simple and executable" -Task task_001
#>

param(
    [Parameter(Mandatory=$true)][string]$Topic,
    [Parameter(Mandatory=$true)][string]$Problem,
    [Parameter(Mandatory=$true)][string]$Choice,
    [Parameter(Mandatory=$true)][string]$Rationale,
    [string]$Task,
    [string[]]$Artifacts
)

. "$PSScriptRoot\common.ps1"
$decisionsMdPath = $script:DecisionsMdPath
$decisionsJsonlPath = $script:DecisionsJsonlPath

# Ensure directory exists
$decisionsDir = Split-Path $decisionsMdPath
if (-not (Test-Path $decisionsDir)) {
    New-Item -ItemType Directory -Path $decisionsDir -Force | Out-Null
}

# Ensure decisions.md exists
if (-not (Test-Path $decisionsMdPath)) {
    "# Decisions Log" | Set-Content $decisionsMdPath
}

# Ensure decisions.jsonl exists
if (-not (Test-Path $decisionsJsonlPath)) {
    "" | Set-Content $decisionsJsonlPath
}

$date = Get-Date -Format 'yyyy-MM-dd'
$lineSeparator = [Environment]::NewLine

$sections = @(
    "### $date $Topic",
    '',
    '**Problem:**',
    $Problem,
    '',
    '**Solution:**',
    "- Chosen: $Choice",
    "- Rationale: $Rationale"
)

if ($Task) {
    $sections += '', "**Task:** $Task"
}

if ($Artifacts) {
    $sections += '', '**Artifacts:**'
    foreach ($artifact in $Artifacts) {
        $sections += "- $artifact"
    }
}

$decision = ("`n" + ($sections -join $lineSeparator)) + $lineSeparator

Add-Content -Path $decisionsMdPath -Value $decision
Write-Host 'Decision recorded to decisions.md' -ForegroundColor Green

# Append to JSONL
$record = [ordered]@{
    id          = [System.Guid]::NewGuid().ToString("N").Substring(0,8)
    timestamp   = (Get-Date -Format "o")
    topic       = $Topic
    problem     = $Problem
    choice      = $Choice
    rationale   = $Rationale
    task        = $Task
    artifacts   = $Artifacts
}
$record | ConvertTo-Json -Compress | Add-Content -Path $decisionsJsonlPath
Write-Host 'Decision recorded to decisions.jsonl' -ForegroundColor Cyan

Sync-SystemStateFromTasks

if ($Task) {
    Write-ExecutionTrace -TaskId $Task -Phase 'decision' -Status 'recorded' -Data @{
        topic = $Topic
        choice = $Choice
    } | Out-Null
}

exit 0
