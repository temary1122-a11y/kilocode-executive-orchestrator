<#
.SYNOPSIS
Parallel group lock management for Executive Orchestrator.
.DESCRIPTION
Provides utilities for managing parallel execution group locks, preventing
concurrent runs of the same group and cleaning up stale locks.
#>

# Resolve base path
$script:BasePath = $using:BasePath

function Get-ParallelGroupLockPath {
    param([Parameter(Mandatory=$true)][string]$Group)
    return Join-Path (Get-MemoryPath) "locks\parallel-group-$($Group.ToLowerInvariant() -replace '[^a-z0-9]+', '-')"
}

function Test-ParallelGroupLocked {
    param([Parameter(Mandatory=$true)][string]$Group)
    $lockPath = Get-ParallelGroupLockPath -Group $Group
    return Test-FileLocked -Path $lockPath
}

function Get-ParallelGroupLock {
    param([Parameter(Mandatory=$true)][string]$Group)
    $lockPath = Get-ParallelGroupLockPath -Group $Group
    return Get-LockInfo -Path $lockPath
}

function Acquire-ParallelGroupLock {
    param([Parameter(Mandatory=$true)][string]$Group)
    $lockPath = Get-ParallelGroupLockPath -Group $Group
    $lockDir = Split-Path $lockPath -Parent
    if (-not (Test-Path $lockDir)) {
        New-Item -ItemType Directory -Path $lockDir -Force | Out-Null
    }
    return Lock-WithRetry -Path $lockPath -MaxRetries 10
}

function Release-ParallelGroupLock {
    param([Parameter(Mandatory=$true)][string]$Group)
    $lockPath = Get-ParallelGroupLockPath -Group $Group
    return Release-FileLock -Path $lockPath
}

function Invoke-ParallelGroupLocked {
    param(
        [Parameter(Mandatory=$true)][string]$Group,
        [Parameter(Mandatory=$true)][scriptblock]$ScriptBlock
    )
    $lockPath = Get-ParallelGroupLockPath -Group $Group
    try {
        $result = Lock-WithRetry -Path $lockPath -MaxRetries 10
        if (-not $result.acquired) {
            throw "Could not acquire parallel group lock for '$Group'"
        }
        return & $ScriptBlock
    } finally {
        Release-FileLock -Path $lockPath | Out-Null
    }
}

Export-ModuleMember -Function @(
    'Get-ParallelGroupLockPath',
    'Test-ParallelGroupLocked',
    'Get-ParallelGroupLock',
    'Acquire-ParallelGroupLock',
    'Release-ParallelGroupLock',
    'Invoke-ParallelGroupLocked'
)