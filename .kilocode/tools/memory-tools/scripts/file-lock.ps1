<#
.SYNOPSIS
File locking utilities for parallel execution safety.
.DESCRIPTION
Provides atomic file locking mechanism with PID-based locks, stale lock detection,
and exponential backoff retry logic to prevent race conditions in parallel agent scenarios.
#>

[CmdletBinding()]
param()

# Global lock tracking for cleanup
$script:ActiveLocks = @{}

#region Lock Management Functions

function Get-LockFilePath {
    param([Parameter(Mandatory=$true)][string]$Path)
    return "$Path.lock"
}

function Get-MyPid {
    return [System.Diagnostics.Process]::GetCurrentProcess().Id
}

function Get-MyProcessInfo {
    $processId = Get-MyPid
    $proc = Get-Process -Id $processId -ErrorAction SilentlyContinue
    $hostName = if ($proc) { $proc.ProcessName } else { 'unknown' }
    return "pid:$processId;host:$hostName;time:$((Get-Date).ToString('o'))"
}

function Test-ProcessAlive {
    param([int]$ProcessId)
    try {
        $process = Get-Process -Id $ProcessId -ErrorAction Stop
        return $process -ne $null -and -not $process.HasExited
    } catch {
        return $false
    }
}

function Test-StaleLock {
    param([Parameter(Mandatory=$true)][string]$LockPath)
    if (-not (Test-Path -LiteralPath $LockPath)) { return $false }
    try {
        $content = Get-Content -LiteralPath $LockPath -Raw -ErrorAction SilentlyContinue
        if (-not $content) { return $true }
        if ($content -match 'pid:(\d+)') {
            $lockPid = [int]$Matches[1]
            return -not (Test-ProcessAlive -Pid $lockPid)
        }
        return $true
    } catch {
        return $true
    }
}

function Get-LockInfo {
    param([Parameter(Mandatory=$true)][string]$Path)
    $lockPath = Get-LockFilePath -Path $Path
    if (-not (Test-Path -LiteralPath $lockPath)) { return $null }
    try {
        $content = Get-Content -LiteralPath $lockPath -Raw -ErrorAction SilentlyContinue
        if ($content -match 'pid:(\d+)') {
            return @{
                locked = $true
                pid = [int]$Matches[1]
                processInfo = $content.Trim()
                stale = (Test-StaleLock -LockPath $lockPath)
            }
        }
    } catch {
        # Lock file may be corrupted or unreadable
    }
    return $null
}

function Test-FileLocked {
    param([Parameter(Mandatory=$true)][string]$Path)
    $lockPath = Get-LockFilePath -Path $Path
    $lockInfo = Get-LockInfo -Path $Path
    if ($lockInfo -and $lockInfo.locked -and -not $lockInfo.stale) {
        return $true
    }
    # Clean up stale lock if exists
    if ($lockInfo -and $lockInfo.stale) {
        Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
    }
    return $false
}

function Get-FileLock {
    <#
    .SYNOPSIS
    Acquires an exclusive lock on a file.
    .DESCRIPTION
    Creates a lock file with PID info. Returns $true if lock acquired, $false if already locked.
    .PARAMETER Path
    Path to the file to lock.
    .PARAMETER Force
    If set, acquires lock even if exists (cleans stale locks automatically).
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [switch]$Force
    )
    $lockPath = Get-LockFilePath -Path $Path
    $stale = Test-StaleLock -LockPath $lockPath
    
    if (-not $Force -and (Test-Path -LiteralPath $lockPath) -and -not $stale) {
        return $false
    }
    
    # Remove stale lock if exists
    if (Test-Path -LiteralPath $lockPath) {
        Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
    }
    
    $processInfo = Get-MyProcessInfo
    $tempPath = "$lockPath.tmp"
    
    try {
        $processInfo | Set-Content -LiteralPath $tempPath -Encoding UTF8
        Move-Item -Path $tempPath -Destination $lockPath -Force
        $script:ActiveLocks[$Path] = $lockPath
        return $true
    } catch {
        if (Test-Path -LiteralPath $tempPath) {
            Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        }
        return $false
    }
}

function Release-FileLock {
    <#
    .SYNOPSIS
    Releases a lock on a file.
    .DESCRIPTION
    Removes the lock file for the specified path. Only removes if lock belongs to current process.
    #>
    param([Parameter(Mandatory=$true)][string]$Path)
    $lockPath = Get-LockFilePath -Path $Path
    
    if (-not (Test-Path -LiteralPath $lockPath)) {
        $script:ActiveLocks.Remove($Path)
        return $true
    }
    
    try {
        $content = Get-Content -LiteralPath $lockPath -Raw -ErrorAction SilentlyContinue
        if ($content -match 'pid:(\d+)') {
            $lockPid = [int]$Matches[1]
            $myPid = Get-MyPid
            if ($lockPid -eq $myPid) {
                Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
                $script:ActiveLocks.Remove($Path)
                return $true
            }
        }
        return $false
    } catch {
        return $false
    }
}

function Lock-WithRetry {
    <#
    .SYNOPSIS
    Attempts to acquire a lock with exponential backoff retry.
    .PARAMETER Path
    Path to lock.
    .PARAMETER MaxRetries
    Maximum number of retry attempts (default: 5).
    .PARAMETER InitialDelayMs
    Initial delay in milliseconds (default: 100).
    .PARAMETER MaxDelayMs
    Maximum delay cap in milliseconds (default: 5000).
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [int]$MaxRetries = 5,
        [int]$InitialDelayMs = 100,
        [int]$MaxDelayMs = 5000
    )
    
    $attempt = 0
    $delayMs = $InitialDelayMs
    
    while ($attempt -lt $MaxRetries) {
        if (Get-FileLock -Path $Path -Force) {
            return @{ acquired = $true; attempts = ($attempt + 1); path = $Path }
        }
        
        $attempt++
        if ($attempt -lt $MaxRetries) {
            Start-Sleep -Milliseconds ([Math]::Min($delayMs, $MaxDelayMs))
            $delayMs = $delayMs * 2
        }
    }
    
    return @{ acquired = $false; attempts = $MaxRetries; path = $Path }
}

function Use-FileLock {
    <#
    .SYNOPSIS
    Executes a script block with file lock held.
    .DESCRIPTION
    Acquires lock, executes script, releases lock on completion or error.
    .PARAMETER Path
    Path to lock.
    .PARAMETER ScriptBlock
    Script to execute while holding lock.
    .PARAMETER MaxRetries
    Maximum retry attempts.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][scriptblock]$ScriptBlock,
        [int]$MaxRetries = 5
    )
    
    $result = Lock-WithRetry -Path $Path -MaxRetries $MaxRetries
    if (-not $result.acquired) {
        throw "Failed to acquire lock on $Path after $MaxRetries attempts"
    }
    
    try {
        return & $ScriptBlock
    } finally {
        Release-FileLock -Path $Path | Out-Null
    }
}

# Cleanup function for script/module exit
$script:CleanupHandler = {
    foreach ($path in $script:ActiveLocks.Keys) {
        Release-FileLock -Path $path | Out-Null
    }
}
# Note: Functions are exported via dot-sourcing in common.ps1