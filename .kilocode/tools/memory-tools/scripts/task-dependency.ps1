<#
.SYNOPSIS
Manage task dependencies in tasks.jsonl.
.EXAMPLE
.\task-dependency.ps1 -Action add -TaskId task_123 -DependsOn "task_456,task_789"
.\task-dependency.ps1 -Action set -TaskId task_123 -DependsOn '["task_456"]'
.\task-dependency.ps1 -Action read -TaskId task_123
.\task-dependency.ps1 -Action graph -Format table
#>

param(
    [Parameter(Mandatory=$true)][ValidateSet('add', 'set', 'read', 'graph', 'validate', 'ready', 'blocked', 'unblock')][string]$Action,
    [string]$TaskId,
    [string]$DependsOn,
    [ValidateSet('table', 'json')][string]$Format = 'table'
)

. "$PSScriptRoot\common.ps1"
$tasksPath = Get-TasksPath

function Read-TasksSafe {
    param([string]$Path)
    $tasks = @()
    if (-not (Test-Path $Path)) { return $tasks }
    $lines = Get-Content $Path -ErrorAction SilentlyContinue | Where-Object { $_ -and $_.Trim() }
    foreach ($line in $lines) {
        try {
            $tasks += $line.Trim() | ConvertFrom-Json
        } catch {
            Write-Log "Skipping invalid JSONL line: $_" -Level 'WARN' -Component 'task-dependency'
        }
    }
    return $tasks
}

function Write-TasksSafe {
    param([array]$Tasks)
    $dir = Split-Path $tasksPath -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $tempPath = "$tasksPath.tmp"
    try {
        $Tasks | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 20 } | Set-Content $tempPath -Encoding UTF8
        Move-Item -Path $tempPath -Destination $tasksPath -Force
        Publish-Event -Type 'task.graph.updated' -Data @{ path = $tasksPath; count = $Tasks.Count }
    } catch {
        Remove-Item -Path $tempPath -Force -ErrorAction SilentlyContinue
        throw
    }
}

function Parse-DependsOn {
    param([string]$Value)
    if (-not $Value) { return @() }
    $trimmed = $Value.Trim()
    if ($trimmed -match '^\[') {
        try {
            $parsed = $trimmed | ConvertFrom-Json
            if ($parsed -is [array]) { return @($parsed | ForEach-Object { [string]$_ } | Where-Object { $_ }) }
            return @([string]$parsed)
        } catch {
            throw "Invalid JSON array format for DependsOn"
        }
    }
    return @($trimmed -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Get-TaskIndex {
    param([array]$Tasks, [string]$Id)
    for ($i = 0; $i -lt $Tasks.Count; $i++) {
        if ($Tasks[$i].task_id -eq $Id) { return $i }
    }
    return -1
}

function Show-GraphTable {
    param([array]$Tasks)
    $graph = $Tasks | Select-Object task_id, depends_on, parallel_group, priority, estimated_complexity, status
    $graph | Format-Table task_id, parallel_group, priority, estimated_complexity, status, @{
        label = 'depends_on'
        expression = {
            if ($_.depends_on -and @($_.depends_on).Count -gt 0) {
                $joined = ($_.depends_on -join ', ')
                if ($joined.Length -gt 36) { $joined.Substring(0, 33) + '...' } else { $joined }
            } else { '' }
        }
    } -AutoSize
}

switch ($Action) {
    'add' {
        if (-not $TaskId) { Write-Error 'TaskId is required for add action'; exit 1 }
        if (-not $DependsOn) { Write-Error 'DependsOn is required for add action'; exit 1 }

        $tasks = Read-TasksSafe -Path $tasksPath
        $index = Get-TaskIndex -Tasks $tasks -Id $TaskId
        if ($index -lt 0) { Write-Error "Task $TaskId not found"; exit 1 }

        try { $newDeps = Parse-DependsOn -Value $DependsOn } catch { Write-Error $_; exit 1 }
        $existing = @()
        if ($tasks[$index].depends_on) { $existing = @($tasks[$index].depends_on | ForEach-Object { [string]$_ }) }

        $merged = @()
        foreach ($dep in @($existing + $newDeps)) {
            if ($dep -and $merged -notcontains $dep) { $merged += $dep }
        }
        $tasks[$index].depends_on = $merged
        Write-TasksSafe -Tasks $tasks
        Write-Host "Dependencies added to task $TaskId" -ForegroundColor Green
    }

    'set' {
        if (-not $TaskId) { Write-Error 'TaskId is required for set action'; exit 1 }
        if ($null -eq $DependsOn) { Write-Error 'DependsOn is required for set action'; exit 1 }

        $tasks = Read-TasksSafe -Path $tasksPath
        $index = Get-TaskIndex -Tasks $tasks -Id $TaskId
        if ($index -lt 0) { Write-Error "Task $TaskId not found"; exit 1 }

        try { $tasks[$index].depends_on = Parse-DependsOn -Value $DependsOn } catch { Write-Error $_; exit 1 }
        Write-TasksSafe -Tasks $tasks
        Write-Host "Dependencies set for task $TaskId" -ForegroundColor Green
    }

    'read' {
        if (-not $TaskId) { Write-Error 'TaskId is required for read action'; exit 1 }
        $tasks = Read-TasksSafe -Path $tasksPath
        $task = $tasks | Where-Object { $_.task_id -eq $TaskId } | Select-Object -First 1
        if (-not $task) { Write-Error "Task $TaskId not found"; exit 1 }
        if ($Format -eq 'json') {
            $task | ConvertTo-Json -Depth 20
        } else {
            Write-Host "Task: $($task.task_id)" -ForegroundColor Cyan
            Write-Host "Depends on: $(@($task.depends_on) -join ', ')"
        }
    }

    'graph' {
        $tasks = Read-TasksSafe -Path $tasksPath
        if ($Format -eq 'json') {
            $tasks | Select-Object task_id, depends_on, parallel_group, priority, estimated_complexity, status | ConvertTo-Json -Depth 20
        } else {
            Show-GraphTable -Tasks $tasks
        }
    }

    'validate' {
        $tasks = Read-TasksSafe -Path $tasksPath
        $ids = @($tasks | ForEach-Object { $_.task_id })
        $errors = @()
        foreach ($task in $tasks) {
        foreach ($dep in @($task.depends_on)) {
            if (-not $dep) { continue }
            if ($ids -notcontains [string]$dep) {
                $errors += "Task $($task.task_id) depends on missing task $dep"
            }
        }
        }
        if ($errors.Count -gt 0) {
            $errors | ForEach-Object { Write-Warning $_ }
            exit 1
        }
        Write-Host 'Task graph dependencies are valid' -ForegroundColor Green
    }

    'ready' {
        if (-not $TaskId) { Write-Error 'TaskId is required for ready action'; exit 1 }
        $tasks = Read-TasksSafe -Path $tasksPath
        $task = $tasks | Where-Object { $_.task_id -eq $TaskId } | Select-Object -First 1
        if (-not $task) { Write-Error "Task $TaskId not found"; exit 1 }
        if (-not $task.depends_on -or ($task.depends_on | Measure-Object).Count -eq 0) {
            Write-Host "Task ${TaskId} has no dependencies - READY" -ForegroundColor Green
            Write-Output "ready=true missing_deps=0"
            exit 0
        }
        $allIds = @($tasks | ForEach-Object { $_.task_id })
        $allIds += @($tasks | ForEach-Object { $_.task_id })
        $allTaskIds = @($tasks | ForEach-Object { $_.task_id })
        $pendingDeps = @()
        foreach ($dep in @($task.depends_on)) {
            $depTask = $tasks | Where-Object { $_.task_id -eq $dep } | Select-Object -First 1
            if (-not $depTask) {
                $pendingDeps += "$dep(MISSING)"
            } elseif ($depTask.status -ne 'completed') {
                $pendingDeps += "$dep($($depTask.status))"
            }
        }
        if ($pendingDeps.Count -eq 0) {
            Write-Host "Task ${TaskId}: ALL dependencies satisfied - READY" -ForegroundColor Green
            Write-Output "ready=true missing_deps=0"
        } else {
            Write-Host "Task ${TaskId}: BLOCKED by $($pendingDeps.Count) dependencies:" -ForegroundColor Yellow
            $pendingDeps | ForEach-Object { Write-Host ('  - {0}' -f $_) }
            Write-Output "ready=false missing_deps=$($pendingDeps.Count) blocked_by=$($pendingDeps -join ',')"
            exit 1
        }
    }

    'blocked' {
        $tasks = Read-TasksSafe -Path $tasksPath
        $allTaskIds = @($tasks | ForEach-Object { $_.task_id })
        $blocked = @()
        foreach ($task in $tasks) {
            if ($task.status -eq 'completed') { continue }
            if (-not $task.depends_on -or ($task.depends_on | Measure-Object).Count -eq 0) { continue }
            $isBlocked = $false
            $blockingDeps = @()
            foreach ($dep in @($task.depends_on)) {
                $depTask = $tasks | Where-Object { $_.task_id -eq $dep } | Select-Object -First 1
                if (-not $depTask -or $depTask.status -ne 'completed') {
                    $isBlocked = $true
                    $blockingDeps += if ($depTask) { "$dep($($depTask.status))" } else { "$dep(MISSING)" }
                }
            }
            if ($isBlocked) {
                $blocked += [pscustomobject]@{ task_id = $task.task_id; blocking = $blockingDeps }
            }
        }
        if ($blocked.Count -eq 0) {
            Write-Host 'No blocked tasks found' -ForegroundColor Green
        } else {
            Write-Host ('=== BLOCKED TASKS ({0}) ===' -f $blocked.Count) -ForegroundColor Yellow
            $blocked | ForEach-Object {
                Write-Host ('  {0}  blocked_by: {1}' -f $_.task_id, ($_.blocking -join ', ')) -ForegroundColor Yellow
            }
        }
    }

    'unblock' {
        if (-not $TaskId) { Write-Error 'TaskId is required for unblock action'; exit 1 }
        if (-not $DependsOn) { Write-Error 'DependsOn required (comma-separated task IDs to remove) for unblock action'; exit 1 }
        $tasks = Read-TasksSafe -Path $tasksPath
        $index = Get-TaskIndex -Tasks $tasks -Id $TaskId
        if ($index -lt 0) { Write-Error "Task $TaskId not found"; exit 1 }
        $removeIds = @($DependsOn -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        $current = @($tasks[$index].depends_on | ForEach-Object { [string]$_ })
        $newDeps = @($current | Where-Object { $_ -and $removeIds -notcontains $_ })
        $countRemoved = ($current | Measure-Object).Count - ($newDeps | Measure-Object).Count
        $tasks[$index].depends_on = $newDeps
        Write-TasksSafe -Tasks $tasks
        Write-Host "Unblocked ${TaskId}: removed $countRemoved dependency(ies)" -ForegroundColor Green
    }
}

exit 0
