<#
.SYNOPSIS
Structured agent error logger with pattern analysis support.
.DESCRIPTION
Writes structured error entries to JSONL (global path by default) for post-hoc pattern analysis and convergence scoring.
.PARAMETER Global
Switch to use global path (~/.kilocode/global/self-healing/agent-errors.jsonl). Default is true.
#>

param(
    [Parameter(Mandatory=$true)][string]$Agent,
    [Parameter(Mandatory=$true)][string]$TaskId,
    [Parameter(Mandatory=$true)][ValidateSet('yaml_format_violation','file_scope_violation','missing_field','test_failure','timeout','permission_denied','contract_violation','unknown')][string]$ErrorType,
    [Parameter(Mandatory=$true)][ValidateSet('low','medium','high')][string]$Severity,
    [string]$Context,
    [string]$Resolution,
    [switch]$DryRun,
    [switch]$Help,
    [bool]$Global = $true
)

. "$PSScriptRoot\common.ps1"

# Resolve path: global takes priority if $Global is true and path exists (or in DryRun mode)
$script:AgentErrorsPath = if ($Global) { 
    Get-GlobalErrorLogPath 
} else { 
    Join-Path (Get-MemoryPath) 'agent-errors.jsonl' 
}

function Show-HelpMessage {
    Write-Host ''
    Write-Host 'AGENT ERROR LOGGER (Global Self-Healing)' -ForegroundColor Cyan
    Write-Host ''
    Write-Host 'Parameters:' -ForegroundColor White
    Write-Host '  -Agent <name>                    Agent name (required)' -ForegroundColor Gray
    Write-Host '  -TaskId <id>                     Task ID (required)' -ForegroundColor Gray
    Write-Host '  -ErrorType <type>                Error type enum (required)' -ForegroundColor Gray
    Write-Host '  -Severity <level>                low | medium | high (required)' -ForegroundColor Gray
    Write-Host '  -Context <text>                  Error context details' -ForegroundColor Gray
    Write-Host '  -Resolution <text>               How error was resolved' -ForegroundColor Gray
    Write-Host '  -Global <bool>                   Use global path (default: true)' -ForegroundColor Gray
    Write-Host '  -DryRun                          Print JSON without writing' -ForegroundColor Gray
    Write-Host '  -Help                            Show this help' -ForegroundColor Gray
    Write-Host ''
    Write-Host "Output (global): $(Get-GlobalErrorLogPath)" -ForegroundColor DarkGray
    Write-Host "Output (project): $(Join-Path (Get-MemoryPath) 'agent-errors.jsonl')" -ForegroundColor DarkGray
    Write-Host ''
}

if ($Help) {
    Show-HelpMessage
    exit 0
}

function New-ErrorEntry {
    param(
        [string]$Agent,
        [string]$TaskId,
        [string]$ErrorType,
        [string]$Severity,
        [string]$Context,
        [string]$Resolution
    )
    $sessionId = $env:KILO_SESSION_ID
    if (-not $sessionId) {
        $sessionId = [guid]::NewGuid().ToString()
    }
    return [ordered]@{
        timestamp     = (Get-Date -Format 'o')
        agent         = $Agent
        task_id       = $TaskId
        error_type    = $ErrorType
        severity      = $Severity
        context       = $Context
        resolution    = $Resolution
        session_id    = $sessionId
    }
}

function Write-ErrorEntry {
    param([hashtable]$Entry)
    $dir = Split-Path $script:AgentErrorsPath -Parent
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $json = $Entry | ConvertTo-Json -Compress -Depth 10
    $line = "${json}`n"
    # Concurrent-safe append using FileStream with FileShare.ReadWrite
    $fs = $null
    $streamWriter = $null
    try {
        $fs = [System.IO.File]::Open(
            $script:AgentErrorsPath,
            [System.IO.FileMode]::Append,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::ReadWrite
        )
        $streamWriter = New-Object System.IO.StreamWriter($fs, [System.Text.Encoding]::UTF8)
        $streamWriter.Write($line)
        $streamWriter.Flush()
    }
    catch {
        throw
    }
    finally {
        if ($streamWriter) { $streamWriter.Close() }
        if ($fs) { $fs.Close() }
    }
}

try {
    $entry = New-ErrorEntry -Agent $Agent -TaskId $TaskId -ErrorType $ErrorType -Severity $Severity -Context $Context -Resolution $Resolution

    if ($DryRun) {
        Write-Host "[$(Get-Date -Format 'o')] [DRYRUN] $($entry | ConvertTo-Json -Compress)" -ForegroundColor Yellow
        exit 0
    }

    Write-ErrorEntry -Entry $entry
    $ts = [datetime]$entry.timestamp
    Write-Host "[$($ts.ToString('o'))] [INFO] Error logged to $script:AgentErrorsPath" -ForegroundColor Green
    Write-Output $script:AgentErrorsPath
    exit 0
} catch {
    Write-Host "[$(Get-Date -Format 'o')] [ERROR] Failed to log error: $_" -ForegroundColor Red
    exit 1
}
