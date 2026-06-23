<#
.SYNOPSIS
Updates the heartbeat pulse for a running task.
.DESCRIPTION
Writes a pulse file to the heartbeats directory. Monitored by the Orchestrator's circuit breaker to detect stalled tasks.
.PARAMETER TaskId
The ID of the task.
.PARAMETER StatusMessage
Optional short status message.
#>
param(
    [Parameter(Mandatory=$true)][string]$TaskId,
    [string]$StatusMessage = "running"
)

. "$PSScriptRoot\common.ps1"

$heartbeatDir = Join-Path (Get-MemoryPath) "heartbeats"
if (-not (Test-Path -LiteralPath $heartbeatDir)) {
    New-Item -ItemType Directory -Path $heartbeatDir -Force | Out-Null
}

$pulseFile = Join-Path $heartbeatDir "$TaskId.json"

$pulseData = [ordered]@{
    task_id = $TaskId
    last_pulse = (Get-Date).ToString('o')
    status_message = $StatusMessage
}

Write-ExecutionTrace -TaskId $TaskId -Phase 'heartbeat' -Status 'pulse' -Data @{ status_message = $StatusMessage } -Event 'heartbeat.pulse' -Actor 'update-heartbeat' | Out-Null

# Write atomically to avoid read conflicts from orchestrator
$tempFile = "$pulseFile.tmp"
$pulseData | ConvertTo-Json -Compress | Set-Content -LiteralPath $tempFile -Encoding UTF8
Move-Item -Path $tempFile -Destination $pulseFile -Force

Write-Host "Heartbeat updated for $TaskId" -ForegroundColor DarkGray
exit 0
