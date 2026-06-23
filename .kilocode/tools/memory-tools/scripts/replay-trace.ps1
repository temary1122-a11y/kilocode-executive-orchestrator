<#
.SYNOPSIS
Replay execution traces for a task.
.DESCRIPTION
Prints the captured trace stream in chronological order and can optionally
emit the raw JSON lines for tooling.
#>

param(
    [Parameter(Mandatory=$true)][string]$TaskId,
    [string]$Phase,
    [string]$RunId,
    [string]$CorrelationId,
    [string]$FailureMode,
    [switch]$AsJson
)

. "$PSScriptRoot\common.ps1"

$trace = Get-ExecutionTrace -TaskId $TaskId
if (-not $trace -or $trace.Count -eq 0) {
    Write-Host "No trace found for task $TaskId" -ForegroundColor Yellow
    exit 0
}

if ($Phase) {
    $trace = @($trace | Where-Object { $_.phase -eq $Phase })
}
if ($RunId) {
    $trace = @($trace | Where-Object { $_.run_id -eq $RunId })
}
if ($CorrelationId) {
    $trace = @($trace | Where-Object { $_.correlation_id -eq $CorrelationId })
}
if ($FailureMode) {
    $trace = @($trace | Where-Object { $_.failure_mode -eq $FailureMode })
}

if ($AsJson) {
    $trace | ConvertTo-Json -Depth 20
    exit 0
}

Write-Host "=== Trace replay for $TaskId ===" -ForegroundColor Cyan
foreach ($entry in $trace) {
    $line = "[{0}] {1}/{2} => {3} (run={4}, corr={5})" -f $entry.timestamp, $entry.event, $entry.phase, $entry.status, $entry.run_id, $entry.correlation_id
    Write-Host $line -ForegroundColor White
    if ($entry.data) {
        Write-Host (($entry.data | ConvertTo-Json -Depth 20)) -ForegroundColor DarkGray
    }
    if ($entry.failure_mode) {
        Write-Host ("failure_mode: {0}" -f $entry.failure_mode) -ForegroundColor DarkYellow
    }
}

exit 0
