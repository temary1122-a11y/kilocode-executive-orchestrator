<#
.SYNOPSIS
Wait for a specific event on the orchestrator bus.
.DESCRIPTION
Reads the bus events JSONL file, checks existing lines, then tails new lines via Get-Content -Wait -Tail 0 until an event matching -WaitFor is published. Outputs the first matching event as JSON. If -TimeoutSeconds is reached without a match, outputs { ok: false, error: 'timeout' }.
.PARAMETER WaitFor
Event type to wait for (e.g., task.completed).
.PARAMETER TimeoutSeconds
Optional timeout in seconds. If omitted, waits indefinitely.
.PARAMETER PollInterval
Seconds between polls when draining the job output queue. Defaults to 1.
.EXAMPLE
.\watch-bus.ps1 -WaitFor task.completed -TimeoutSeconds 30
.EXAMPLE
.\watch-bus.ps1 -WaitFor agent.heartbeat -PollInterval 2
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    [string]$WaitFor,

    [Parameter(Mandatory=$false)]
    [ValidateRange(0, [int]::MaxValue)]
    [int]$TimeoutSeconds = 0,

    [Parameter(Mandatory=$false)]
    [ValidateRange(1, 3600)]
    [int]$PollInterval = 1
)

. "$PSScriptRoot\common.ps1"

$ErrorActionPreference = 'SilentlyContinue'

$busDir = Get-BusPath
$busFile = Join-Path $busDir 'events.jsonl'

if (-not (Test-Path -LiteralPath $busFile)) {
    if ($TimeoutSeconds -gt 0) {
        $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
        while ((Get-Date) -lt $deadline) {
            if (Test-Path -LiteralPath $busFile) { break }
            Start-Sleep -Seconds $PollInterval
        }
    }
    if (-not (Test-Path -LiteralPath $busFile)) {
        [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
        if ($TimeoutSeconds -gt 0) {
            (@{ ok = $false; error = 'timeout' } | ConvertTo-Json -Compress)
        } else {
            (@{ ok = $false; error = 'bus_file_missing' } | ConvertTo-Json -Compress)
        }
        exit 1
    }
}

$deadline = $null
if ($TimeoutSeconds -gt 0) {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
}

function Match-EventLine {
    param([string]$Line)
    $trimmed = $Line.Trim()
    if (-not $trimmed) { return $false }
    try {
        $event = $trimmed | ConvertFrom-Json
        return ($event.type -eq $WaitFor)
    } catch {
        return $false
    }
}

$matchedEvent = Get-Content -LiteralPath $busFile -ErrorAction SilentlyContinue | Where-Object { Match-EventLine $_ } | Select-Object -First 1
if ($matchedEvent) {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $matchedEvent | ConvertTo-Json -Compress -Depth 20
    exit 0
}

$readerJob = Start-Job -ScriptBlock {
    param($Path)
    Get-Content -Path $Path -Wait -Tail 0
} -ArgumentList $busFile

$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

try {
    while ($true) {
        if ($deadline -and $stopwatch.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
            break
        }

        $received = Receive-Job -Job $readerJob -Keep -ErrorAction SilentlyContinue
        if ($received) {
            foreach ($line in $received) {
                if (Match-EventLine -Line $line) {
                    $event = $line.Trim() | ConvertFrom-Json
                    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
                    $event | ConvertTo-Json -Compress -Depth 20
                    Remove-Job $readerJob -Force | Out-Null
                    exit 0
                }
            }
        }

        $sleepMs = [Math]::Max(50, $PollInterval * 1000)
        if ($deadline) {
            $remaining = ($deadline - (Get-Date)).TotalMilliseconds
            if ($remaining -le 0) { break }
            $sleepMs = [Math]::Min($sleepMs, [Math]::Ceiling($remaining))
        }
        Start-Sleep -Milliseconds $sleepMs
    }
} finally {
    Remove-Job $readerJob -Force | Out-Null
}

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
(@{ ok = $false; error = 'timeout' } | ConvertTo-Json -Compress)
exit 1
