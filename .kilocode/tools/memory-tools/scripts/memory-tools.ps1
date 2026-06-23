<#
.SYNOPSIS
Memory Tools Launcher - Orchestrator MVP
.USAGE
.\memory-tools.ps1 <command> [-Arguments]
#>

param(
    [Parameter(Mandatory=$true)][string]$Command,
    [Parameter(ValueFromRemainingArguments=$true)][string[]]$Arguments
)

$scriptsPath = Split-Path -Parent $MyInvocation.MyCommand.Path

$scriptMap = @{
    "add-task" = "add-task.ps1"
    "update-task" = "update-task-status.ps1"
    "get-tasks" = "get-active-tasks.ps1"
    "get-last-task" = "get-last-task.ps1"
    "get-current-task" = "get-current-task.ps1"
    "log-decision" = "record-decision.ps1"
    "agent-status" = "agent-status.ps1"
    "checkpoint-task" = "checkpoint-task.ps1"
    "restore-checkpoint" = "restore-checkpoint.ps1"
    "consolidate-results" = "consolidate-results.ps1"
    "research-report" = "research-report.ps1"
    "health-check" = "health-check.ps1"
    "task-dependency" = "task-dependency.ps1"
    "user-profile" = "user-profile.ps1"
    "context-enrichment" = "context-enrichment.ps1"
    "parallel-runner" = "parallel-runner.ps1"
    "self-heal" = "self-heal.ps1"
    "replay-trace" = "replay-trace.ps1"
    "batch" = "batch-memory.ps1"
}

if ($scriptMap.ContainsKey($Command)) {
    $scriptPath = Join-Path $scriptsPath $scriptMap[$Command]
    if (Test-Path $scriptPath) {
        # Parse arguments into a hashtable for splatting
        $paramHash = @{}
        $i = 0
        while ($i -lt $Arguments.Count) {
            $arg = $Arguments[$i]
            # Check if this is a switch parameter (starts with - or --)
            if ($arg -match '^-') {
                $paramName = $arg.TrimStart('-')
                # Check if next argument is a value (not another switch)
                if ($i + 1 -lt $Arguments.Count -and $Arguments[$i + 1] -notmatch '^-') {
                    $paramValue = $Arguments[$i + 1]
                    # Try to convert numeric values
                    if ($paramValue -match '^\d+$') {
                        $paramHash[$paramName] = [int]$paramValue
                    } else {
                        $paramHash[$paramName] = $paramValue
                    }
                    $i += 2
                } else {
                    # It's a boolean switch (no value)
                    $paramHash[$paramName] = $true
                    $i += 1
                }
            } else {
                $i += 1
            }
        }
        & $scriptPath @paramHash
    } else {
        Write-Error "Script not found: $scriptPath"
        exit 1
    }
} else {
    Write-Error "Unknown command: $Command"
    Write-Host "Available: $($scriptMap.Keys -join ', ')"
    exit 1
}
