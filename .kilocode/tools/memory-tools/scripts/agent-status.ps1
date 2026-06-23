<#
.SYNOPSIS
Agent Status Monitor implementation.
.DESCRIPTION
Reads Agent Manager state, evaluates heartbeat health, and supports Kill/Pause/Watch with filters.
#>

param(
    [string]$Kill,
    [string]$Pause,
    [string]$Heartbeat,
    [switch]$Watch,
    [string]$Status,
    [string]$Task,
    [int]$StalledThreshold = 5,
    [int]$HeartbeatAge = 5,
    [switch]$Help
)

. "$PSScriptRoot\common.ps1"

function Resolve-AgentManagerPath {
    $workspaceRoot = Split-Path (Get-BasePath)
    $candidates = @(
        (Join-Path $workspaceRoot '.kilo\agent-manager.json'),
        (Join-Path (Get-BasePath) '.kilo\agent-manager.json'),
        (Join-Path $PWD '.kilo\agent-manager.json')
    )

    foreach ($candidate in $candidates) {
        if (Test-Path $candidate) {
            return (Resolve-Path $candidate).Path
        }
    }

    return (Join-Path $workspaceRoot '.kilo\agent-manager.json')
}

$script:AgentManagerPath = Resolve-AgentManagerPath
$script:LockDir = Join-Path (Get-MemoryPath) 'locks'
$script:PauseDir = Join-Path (Get-MemoryPath) 'pauses'
$script:ControlLogPath = Join-Path (Get-MemoryPath) 'agent-control.log'

function Read-JsonSafe {
    param([string]$Path, [object]$Default)
    if (-not (Test-Path $Path)) { return $Default }
    try {
        $raw = Get-Content $Path -Raw -ErrorAction Stop
        if (-not $raw) { return $Default }
        return $raw | ConvertFrom-Json
    } catch {
        Write-Log "Failed to parse $Path, using default: $_" -Level 'WARN' -Component 'agent-status'
        return $Default
    }
}

function Write-JsonSafe {
    param([Parameter(Mandatory=$true)][string]$Path, [Parameter(Mandatory=$true)][object]$Data)
    $dir = Split-Path $Path -Parent
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $tempPath = "$Path.tmp"
    try {
        $Data | ConvertTo-Json -Depth 20 | Set-Content -Path $tempPath -Encoding UTF8 -ErrorAction Stop
        Move-Item -Path $tempPath -Destination $Path -Force -ErrorAction Stop
    } catch {
        Remove-Item -Path $tempPath -Force -ErrorAction SilentlyContinue
        throw
    }
}

function Acquire-Lock {
    param([string]$Name)
    if (-not (Test-Path $script:LockDir)) {
        New-Item -ItemType Directory -Path $script:LockDir -Force | Out-Null
    }
    $lockPath = Join-Path $script:LockDir "$Name.lock"
    $maxWaitMs = 10000
    $waitedMs = 0
    while ($waitedMs -lt $maxWaitMs) {
        try {
            New-Item -ItemType Directory -Path $lockPath -Force -ErrorAction Stop | Out-Null
            return $true
        } catch {
            Start-Sleep -Milliseconds 200
            $waitedMs += 200
        }
    }
    Write-Log "Could not acquire lock $Name after $($maxWaitMs/1000)s" -Level 'WARN' -Component 'agent-status'
    return $false
}

function Release-Lock {
    param([string]$Name)
    $lockPath = Join-Path $script:LockDir "$Name.lock"
    if (Test-Path $lockPath) {
        Remove-Item $lockPath -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Get-ManagerData {
    Read-JsonSafe -Path $script:AgentManagerPath -Default @{ worktrees = @{}; sessions = @{}; tabOrder = @{ local = @() } }
}

function Read-TasksSafe {
    $tasksPath = Get-TasksPath
    if (-not (Test-Path $tasksPath)) { return @() }
    $tasks = @()
    $lines = Get-Content $tasksPath -ErrorAction SilentlyContinue | Where-Object { $_ -and $_.Trim() }
    foreach ($line in $lines) {
        try {
            $tasks += $line.Trim() | ConvertFrom-Json
        } catch {
            Write-Log "Skipping invalid task JSONL line: $_" -Level 'WARN' -Component 'agent-status'
        }
    }
    return $tasks
}

function Get-SessionMap {
    param([object]$Data = $(Get-ManagerData))
    if (-not $Data.sessions) { return @{} }
    return $Data.sessions
}

function Get-AllSessions {
    param([object]$Data = $(Get-ManagerData))
    $result = @()
    $sessions = Get-SessionMap -Data $Data
    if (-not $sessions) { return $result }

    foreach ($key in $sessions.PSObject.Properties.Name) {
        $value = $sessions.$key
        $record = [ordered]@{ sessionId = $key }
        if ($value -and $value.PSObject.Properties) {
            foreach ($property in $value.PSObject.Properties) {
                $record[$property.Name] = $property.Value
            }
        }
        $result += [pscustomobject]$record
    }

    return $result
}

function Get-SessionById {
    param([string]$SessionId, [object]$Data = $(Get-ManagerData))
    $sessions = Get-SessionMap -Data $Data
    if (-not $sessions -or -not $sessions.PSObject.Properties.Name -contains $SessionId) {
        return $null
    }
    $value = $sessions.$SessionId
    $record = [ordered]@{ sessionId = $SessionId }
    if ($value -and $value.PSObject.Properties) {
        foreach ($property in $value.PSObject.Properties) {
            $record[$property.Name] = $property.Value
        }
    }
    return [pscustomobject]$record
}

function Convert-IsoToDateTime {
    param([object]$Value)
    if (-not $Value) { return $null }
    try {
        return [datetime]::Parse([string]$Value, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal)
    } catch {
        try {
            return [datetime]$Value
        } catch {
            return $null
        }
    }
}

function Get-MinutesSince {
    param([object]$Value)
    $dt = Convert-IsoToDateTime -Value $Value
    if (-not $dt) { return $null }
    return [math]::Round(((Get-Date) - $dt).TotalMinutes, 2)
}

function Get-FirstValue {
    param([object[]]$Values)
    foreach ($value in $Values) {
        if ($null -ne $value -and [string]::IsNullOrWhiteSpace([string]$value)) { continue }
        return $value
    }
    return $null
}

function Test-AgentHealth {
    param([object]$Session, [int]$ThresholdMinutes = $StalledThreshold, [int]$HeartbeatMinutes = $HeartbeatAge)
    $status = if ($Session.status) { [string]$Session.status } else { 'idle' }

    if ($status -in @('paused', 'killed', 'failed', 'blocked', 'idle')) {
        return $status
    }

    $hbDate = Convert-IsoToDateTime -Value $Session.last_heartbeat
    if ($hbDate) {
        $age = [math]::Round(((Get-Date) - $hbDate).TotalMinutes, 2)
        if ($age -gt $HeartbeatMinutes) {
            return 'suspected_stalled'
        }
        return 'healthy'
    }

    $activityDate = Convert-IsoToDateTime -Value $Session.lastActivity
    if ($activityDate) {
        $age = [math]::Round(((Get-Date) - $activityDate).TotalMinutes, 2)
        if ($age -gt $ThresholdMinutes) {
            return 'suspected_stalled'
        }
        return 'healthy'
    }

    return 'no_heartbeat'
}

function Format-TaskObjective {
    param([string]$TaskId, [array]$Tasks = $(Read-TasksSafe))
    if (-not $TaskId) { return 'Unknown' }
    $task = $Tasks | Where-Object { $_.task_id -eq $TaskId -or $_.task_id -eq $TaskId -or $_.task_id -eq $TaskId } | Select-Object -First 1
    if ($task -and $task.objective) { return $task.objective }
    return 'Unknown'
}

function Get-SessionMetrics {
    param([object]$Session)
    $toolCalls = 0
    $errors = 0
    if ($null -ne $Session.tool_calls_count) {
        try { $toolCalls = [int]$Session.tool_calls_count } catch { $toolCalls = 0 }
    }
    if ($null -ne $Session.error_count) {
        try { $errors = [int]$Session.error_count } catch { $errors = 0 }
    }
    $lastHbDate = Convert-IsoToDateTime -Value (Get-FirstValue $Session.last_heartbeat, $Session.lastActivity, $Session.createdAt)
    $lastHb = if ($lastHbDate) { $lastHbDate.ToString('o') } else { '-' }
    return [pscustomobject]@{
        tool_calls_count = $toolCalls
        error_count = $errors
        last_heartbeat = $lastHb
        health_state = Test-AgentHealth -Session $Session
    }
}

function Get-FilteredSessions {
    param([array]$Sessions)
    $filtered = $Sessions
    if ($Status) {
        $filtered = $filtered | Where-Object {
            $currentStatus = if ($_.status) { $_.status } else { 'idle' }
            $currentHealth = Test-AgentHealth -Session $_
            $currentStatus -eq $Status -or $currentHealth -eq $Status
        }
    }
    if ($Task) {
        $filtered = $filtered | Where-Object {
            $taskId = if ($_.taskId) { $_.taskId } else { '' }
            $sessionId = if ($_.sessionId) { $_.sessionId } else { '' }
            $objective = Format-TaskObjective -TaskId $taskId
            $taskId -eq $Task -or $sessionId -eq $Task -or $objective -like "*$Task*"
        }
    }
    return $filtered
}

function Show-HelpMessage {
    Write-Host ''
    Write-Host 'AGENT STATUS MONITOR' -ForegroundColor Cyan
    Write-Host ''
    Write-Host 'Parameters:' -ForegroundColor White
    Write-Host '  -Kill <session_id>              Terminate session PID and update agent-manager.json' -ForegroundColor Gray
    Write-Host '  -Pause <session_id>             Create pause file + bus event, update status to paused' -ForegroundColor Gray
    Write-Host '  -Heartbeat <session_id>         Update last_heartbeat for a session' -ForegroundColor Gray
    Write-Host '  -Watch                          Live monitoring with refresh and filters' -ForegroundColor Gray
    Write-Host '  -Status <status|health>         Filter by status or health_state' -ForegroundColor Gray
    Write-Host '  -Task <task_id|text>            Filter by task id or objective text' -ForegroundColor Gray
    Write-Host '  -StalledThreshold <minutes>     Fallback activity stall threshold (default: 5)' -ForegroundColor Gray
    Write-Host '  -HeartbeatAge <minutes>         Heartbeat stall threshold (default: 5)' -ForegroundColor Gray
    Write-Host '  -Help                           Show this help' -ForegroundColor Gray
    Write-Host ''
    Write-Host 'Output includes: last_heartbeat, health_state, tool_calls_count, error_count.' -ForegroundColor DarkGray
    Write-Host "Agent manager: $script:AgentManagerPath" -ForegroundColor DarkGray
    Write-Host "Control log: $script:ControlLogPath" -ForegroundColor DarkGray
    Write-Host ''
}

function Show-Statistics {
    param([array]$Sessions)
    $statusCounts = @{}
    foreach ($session in $Sessions) {
        $status = if ($session.status) { $session.status } else { 'idle' }
        if (-not $statusCounts.ContainsKey($status)) { $statusCounts[$status] = 0 }
        $statusCounts[$status]++
    }

    $healthCounts = @{}
    foreach ($session in $Sessions) {
        $health = Test-AgentHealth -Session $session
        if (-not $healthCounts.ContainsKey($health)) { $healthCounts[$health] = 0 }
        $healthCounts[$health]++
    }

    Write-Host ''
    Write-Host '=== AGENT STATISTICS ===' -ForegroundColor Cyan
    Write-Host ('  Total: {0}' -f $Sessions.Count) -ForegroundColor Gray
    Write-Host ('  Statuses: {0}' -f (($statusCounts.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', ')) -ForegroundColor Gray
    
    # Color-code health summary
    $healthLine = ($healthCounts.GetEnumerator() | ForEach-Object {
        $hc = switch ($_.Key) {
            'healthy' { 'Green' }
            'suspected_stalled' { 'Red' }
            'no_heartbeat' { 'Yellow' }
            default { 'Gray' }
        }
        "$($_.Key)=$($_.Value)"
    }) -join ', '
    Write-Host ('  Health: {0}' -f $healthLine) -ForegroundColor Gray
    Write-Host ''
}

function Show-SessionList {
    param([array]$Sessions)
    Write-Host '=== SESSION DETAILS ===' -ForegroundColor Cyan
    $rows = foreach ($session in $Sessions) {
        $metrics = Get-SessionMetrics -Session $session
        $taskId = if ($session.taskId) { $session.taskId } else { '-' }
        $processId = if ($session.pid) { $session.pid } else { '-' }
        $lastHb = if ($metrics.last_heartbeat -and [string]$metrics.last_heartbeat -ne '-') {
            $raw = [string]$metrics.last_heartbeat
            if ($raw.Length -gt 19) { $raw.Substring(0, 19) } else { $raw }
        } else { '-' }
        $health = $metrics.health_state
        $healthColor = switch ($health) {
            'healthy' { 'Green' }
            'suspected_stalled' { 'Red' }
            'no_heartbeat' { 'Yellow' }
            default { 'Gray' }
        }
        # current_action inferred from latest bus event for this session
        $currentAction = '-'
        try {
            $busEvents = Get-BusEvents -Types @('agent.heartbeat','agent.updated','agent.killed','agent.paused')
            $recent = $busEvents | Where-Object { $_.data.session_id -eq $session.sessionId } | Sort-Object timestamp -Descending | Select-Object -First 1
            if ($recent) {
                $agoMinutes = [math]::Round(((Get-Date) - [datetime]$recent.timestamp).TotalMinutes, 1)
                $currentAction = "$($recent.type) (${agoMinutes}m ago)"
            }
        } catch { $currentAction = '-' }
        [pscustomobject]@{
            Session = if ($session.sessionId.Length -gt 14) { $session.sessionId.Substring(0, 14) } else { $session.sessionId }
            Status = if ($session.status) { $session.status } else { 'idle' }
            Health = $health
            CurrentAction = if ($currentAction.Length -gt 22) { $currentAction.Substring(0, 19) + '...' } else { $currentAction }
            Task = if ($taskId.Length -gt 18) { $taskId.Substring(0, 18) } else { $taskId }
            Pid = $processId
            LastHb = $lastHb
            ToolCalls = $metrics.tool_calls_count
            Errors = $metrics.error_count
        }
    }

    if ($rows.Count -eq 0) {
        Write-Host 'No sessions match the current filters.' -ForegroundColor Yellow
        return
    }

    $rows | Sort-Object Status, @{ Expression = { $_.Health }; Descending = $true }, Session | Format-Table -AutoSize
    
    # Afterwards print health column with colors (Format-Table strips colors, so re-emit summary)
    Write-Host ''
    foreach ($row in ($rows | Sort-Object Status, Session)) {
        $hc = switch ($row.Health) {
            'healthy' { 'Green' }
            'suspected_stalled' { 'Red' }
            'no_heartbeat' { 'Yellow' }
            default { 'Gray' }
        }
        Write-Host ('  [{0}] {1}  action={2}  task={3}  hb={4}  calls={5}  err={6}' -f 
            (if ($hc -eq 'Green') { 'OK' } elseif ($hc -eq 'Red') { 'STALL' } else { 'WARN' }),
            $row.Session, $row.CurrentAction, $row.Task, $row.LastHb, $row.ToolCalls, $row.Errors) -ForegroundColor $hc
    }
}

function Write-ControlLog {
    param([string]$Message)
    $logDir = Split-Path $script:ControlLogPath -Parent
    if (-not (Test-Path $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }
    $entry = [ordered]@{
        timestamp = (Get-Date -Format 'o')
        level = 'INFO'
        component = 'agent-status'
        message = $Message
    } | ConvertTo-Json -Compress
    Add-Content -Path $script:ControlLogPath -Value $entry -ErrorAction SilentlyContinue
}

function Write-PauseFile {
    param([string]$SessionId)
    if (-not (Test-Path $script:PauseDir)) {
        New-Item -ItemType Directory -Path $script:PauseDir -Force | Out-Null
    }
    $pausePath = Join-Path $script:PauseDir "$SessionId.pause"
    $pauseSign = [ordered]@{
        paused = $true
        timestamp = (Get-Date -Format 'o')
        session_id = $SessionId
        source = 'agent-status.ps1'
        note = 'Agent must poll this file or the memory bus to pause cooperatively.'
    } | ConvertTo-Json -Depth 5
    Set-Content -Path $pausePath -Value $pauseSign -Encoding UTF8
    Write-Host "  -> Pause file created: $pausePath" -ForegroundColor DarkGray
}

function Publish-ControlEvent {
    param([string]$Type, [hashtable]$Data)
    $Data['source'] = 'agent-status.ps1'
    $Data['timestamp'] = (Get-Date -Format 'o')
    Publish-Event -Type $Type -Data $Data
}

function Set-SessionProperty {
    param([object]$Session, [string]$Name, [object]$Value)
    $Session | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
}

function Update-SessionStatus {
    param([string]$SessionId, [string]$NewStatus, [string]$Reason = '')
    if (-not (Acquire-Lock -Name 'agent-manager')) { return $false }
    try {
        $data = Get-ManagerData
        $sessions = Get-SessionMap -Data $data
        if (-not $sessions.PSObject.Properties.Name -contains $SessionId) { return $false }

        $session = $sessions.$SessionId
        Set-SessionProperty -Session $session -Name 'status' -Value $NewStatus
        Set-SessionProperty -Session $session -Name 'lastUpdated' -Value (Get-Date -Format 'o')
        Set-SessionProperty -Session $session -Name 'last_heartbeat' -Value (Get-Date -Format 'o')
        if ($Reason) { Set-SessionProperty -Session $session -Name 'endReason' -Value $Reason }

        Write-JsonSafe -Path $script:AgentManagerPath -Data $data
        Write-ExecutionTrace -TaskId $SessionId -Phase 'agent-status' -Status $NewStatus -Data @{ reason = $Reason } -Event 'agent.status_updated' -Actor 'agent-status' | Out-Null
        return $true
    } catch {
        Write-Log "Failed to update session $SessionId status: $_" -Level 'ERROR' -Component 'agent-status'
        return $false
    } finally {
        Release-Lock -Name 'agent-manager'
    }
}

function Update-SessionHeartbeat {
    param([string]$SessionId)
    if (-not (Acquire-Lock -Name 'agent-manager')) { return $false }
    try {
        $data = Get-ManagerData
        $sessions = Get-SessionMap -Data $data
        if (-not $sessions.PSObject.Properties.Name -contains $SessionId) { return $false }

        $session = $sessions.$SessionId
        Set-SessionProperty -Session $session -Name 'last_heartbeat' -Value (Get-Date -Format 'o')
        if ($null -eq $session.tool_calls_count) { Set-SessionProperty -Session $session -Name 'tool_calls_count' -Value 0 }
        if ($null -eq $session.error_count) { Set-SessionProperty -Session $session -Name 'error_count' -Value 0 }

        Write-JsonSafe -Path $script:AgentManagerPath -Data $data
        return $true
    } catch {
        Write-Log "Failed to update heartbeat for ${SessionId}: $_" -Level 'ERROR' -Component 'agent-status'
        return $false
    } finally {
        Release-Lock -Name 'agent-manager'
    }
}

function Invoke-HeartbeatSession {
    param([string]$SessionId)
    $session = Get-SessionById -SessionId $SessionId
    if (-not $session) {
        Write-Host "Session $SessionId not found" -ForegroundColor Yellow
        return
    }
    $ok = Update-SessionHeartbeat -SessionId $SessionId
    if ($ok) {
        Write-Host "Heartbeat updated for $SessionId" -ForegroundColor Green
        Write-ControlLog "Heartbeat session=$SessionId"
        Publish-ControlEvent -Type 'agent.heartbeat' -Data @{ session_id = $SessionId }
        Write-ExecutionTrace -TaskId $SessionId -Phase 'agent-status' -Status 'heartbeat' -Data @{ session_id = $SessionId } -Event 'agent.heartbeat' -Actor 'agent-status' | Out-Null
    } else {
        Write-Host "Failed to update heartbeat for $SessionId" -ForegroundColor Red
    }
}

function Invoke-KillSession {
    param([string]$SessionId)
    $session = Get-SessionById -SessionId $SessionId
    if (-not $session) {
        Write-Host "Session $SessionId not found" -ForegroundColor Yellow
        return
    }

    $processTerminated = $false
    $pidText = if ($session.pid) { [string]$session.pid } else { 'none' }

    if ($session.pid) {
        $proc = Get-Process -Id $session.pid -ErrorAction SilentlyContinue
        if ($proc) {
            try {
                Stop-Process -Id $session.pid -Force -ErrorAction Stop
                Start-Sleep -Milliseconds 750
                if (-not (Get-Process -Id $session.pid -ErrorAction SilentlyContinue)) {
                    $processTerminated = $true
                } else {
                    cmd.exe /c taskkill /PID $session.pid /F | Out-Null
                    Start-Sleep -Milliseconds 500
                    if (-not (Get-Process -Id $session.pid -ErrorAction SilentlyContinue)) {
                        $processTerminated = $true
                    }
                }
                Write-Host "Killed session $SessionId (PID $pidText, terminated=$processTerminated)" -ForegroundColor Green
            } catch {
                Write-Host "Failed to kill PID $pidText : $_" -ForegroundColor Red
            }
        } else {
            Write-Host "Process $pidText is not running" -ForegroundColor Yellow
            $processTerminated = $true
        }
    } else {
        Write-Host "No PID recorded for session $SessionId" -ForegroundColor Yellow
    }

    $finalStatus = if ($processTerminated -or -not $session.pid) { 'killed' } else { 'failed' }
    $finalReason = if ($finalStatus -eq 'killed') { 'User terminated via agent-status.ps1' } else { 'Kill failed; process still running after stop attempts' }

    $ok = Update-SessionStatus -SessionId $SessionId -NewStatus $finalStatus -Reason $finalReason
    $pausePath = Join-Path $script:PauseDir "$SessionId.pause"
    if (Test-Path $pausePath) { Remove-Item $pausePath -Force -ErrorAction SilentlyContinue }
    Write-ControlLog "Kill session=$SessionId pid=$pidText processTerminated=$processTerminated status=$finalStatus"
    Publish-ControlEvent -Type 'agent.killed' -Data @{ session_id = $SessionId; pid = $pidText; processTerminated = $processTerminated; status = $finalStatus }
    Write-ExecutionTrace -TaskId $SessionId -Phase 'agent-status' -Status 'killed' -Data @{
        pid = $pidText
        final_status = $finalStatus
    } | Out-Null
    if ($ok) {
        Write-Host "Status updated in agent-manager.json: $finalStatus" -ForegroundColor Green
    } else {
        Write-Host "Failed to update agent-manager.json for $SessionId" -ForegroundColor Red
    }
}

function Invoke-PauseSession {
    param([string]$SessionId)
    $session = Get-SessionById -SessionId $SessionId
    if (-not $session) {
        Write-Host "Session $SessionId not found" -ForegroundColor Yellow
        return
    }

    Write-PauseFile -SessionId $SessionId
    $ok = Update-SessionStatus -SessionId $SessionId -NewStatus 'paused' -Reason 'User pause requested via agent-status.ps1'
    Write-ControlLog "Pause session=$SessionId via pause_file"
    Publish-ControlEvent -Type 'agent.paused' -Data @{ session_id = $SessionId }
    Write-ExecutionTrace -TaskId $SessionId -Phase 'agent-status' -Status 'paused' -Data @{
        pause_path = (Join-Path $script:PauseDir "$SessionId.pause")
    } | Out-Null
    if ($ok) {
        Write-Host "Paused session $SessionId (agent must poll pause file or bus)" -ForegroundColor Green
    } else {
        Write-Host "Failed to update session status for $SessionId" -ForegroundColor Red
    }
}

function Invoke-Display {
    $data = Get-ManagerData
    if (-not (Test-Path $script:AgentManagerPath)) {
        Write-Host "No Agent Manager state found at $script:AgentManagerPath" -ForegroundColor Yellow
        return
    }

    $allSessions = Get-AllSessions -Data $data
    $filteredSessions = Get-FilteredSessions -Sessions $allSessions

    Show-Statistics -Sessions $allSessions
    Show-SessionList -Sessions $filteredSessions

    Write-Host ''
    Write-Host ("Agent manager: {0}" -f $script:AgentManagerPath) -ForegroundColor DarkGray
    Write-Host ("Control log: {0}" -f $script:ControlLogPath) -ForegroundColor DarkGray
    Write-Host ("Filters: Status='{0}' Task='{1}' StalledThreshold={2}min HeartbeatAge={3}min" -f $Status, $Task, $StalledThreshold, $HeartbeatAge) -ForegroundColor DarkGray
    Write-Host 'Use: -Kill <session_id> | -Pause <session_id> | -Heartbeat <session_id> | -Watch | -Status <...> | -Task <...>' -ForegroundColor DarkGray
}

if ($Help -or $Kill -eq 'Help' -or $Kill -eq '-Help' -or $Pause -eq 'Help' -or $Pause -eq '-Help' -or $Status -eq 'Help' -or $Status -eq '-Help' -or $Task -eq 'Help' -or $Task -eq '-Help') {
    Show-HelpMessage
    exit 0
}

if ($Heartbeat) {
    Invoke-HeartbeatSession -SessionId $Heartbeat
    exit 0
}

if ($Kill) {
    Invoke-KillSession -SessionId $Kill
    exit 0
}

if ($Pause) {
    Invoke-PauseSession -SessionId $Pause
    exit 0
}

if ($Watch) {
    while ($true) {
        try {
            Clear-Host
            Invoke-Display
            Write-Host ''
            Write-Host 'Watch mode: press Ctrl+C to exit.' -ForegroundColor DarkGray
            Start-Sleep -Seconds 2
        } catch {
            Write-Host "Watch error: $_" -ForegroundColor Red
            Start-Sleep -Seconds 3
        }
    }
}

Invoke-Display
exit 0
