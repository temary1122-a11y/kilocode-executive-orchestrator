<#
.SYNOPSIS
Enhanced self-healing script with stall detection and auto-retry capabilities.
.DESCRIPTION
Wraps self-heal.ps1 and checks for stalled tasks on the event bus.
#>
param(
    [Parameter(Mandatory=$true)][string]$Agent,
    [string]$TaskId = '',
    [switch]$StallCheck,
    [switch]$DryRun,
    [switch]$Apply
)

$commonScript = Join-Path $PSScriptRoot 'common.ps1'
if (Test-Path $commonScript) { . $commonScript }

$originalScript = Join-Path $PSScriptRoot 'self-heal.ps1'
if (-not (Test-Path $originalScript)) {
    Write-Error "Original self-heal.ps1 not found at $originalScript"
    exit 1
}

if ($StallCheck) {
    # Check bus for recent stalled events
    $events = Get-BusEvents -Types @('task.stalled','agent.heartbeat')
    $stalledCount = @($events | Where-Object { $_.data.agent -eq $Agent -and $_.type -eq 'task.stalled' }).Count
    if ($stalledCount -ge 2) {
        Write-Log "Stall detected ($stalledCount checks) for agent $Agent" -Level WARN -Component self-heal
    }
}

# Delegate to original self-heal.ps1
$params = @{ Agent = $Agent }
if ($TaskId) { $params['TaskId'] = $TaskId }
if ($DryRun) { $params['DryRun'] = $true }
if ($Apply) { $params['Apply'] = $true }

& $originalScript @params

