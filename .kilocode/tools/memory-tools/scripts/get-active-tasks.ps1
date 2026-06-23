<#
.SYNOPSIS
Get active tasks (pending or in_progress) formatted as table
.EXAMPLE
.\get-active-tasks.ps1
.\get-active-tasks.ps1 -Filter research
.\get-active-tasks.ps1 -Priority p0
#>

param(
    [string]$Filter,
    [string]$Priority
)

. "$PSScriptRoot\common.ps1"
$tasksPath = Get-TasksPath

# Read tasks from JSONL
$tasksRaw = Get-Content $tasksPath | Where-Object { $_ -and $_.Trim() }
$tasks = @()
foreach ($line in $tasksRaw) {
    $tasks += $line.Trim() | ConvertFrom-Json
}

$activeTasks = $tasks | Where-Object { $_.status -in @("pending", "in_progress") }

if ($Filter) {
    $activeTasks = $activeTasks | Where-Object { $_.type -eq $Filter }
}

if ($Priority) {
    $activeTasks = $activeTasks | Where-Object { $_.priority -eq $Priority }
}

if ($activeTasks.Count -eq 0) {
    Write-Host "No active tasks found" -ForegroundColor Yellow
    return
}

$activeTasks | Format-Table task_id, type, priority, @{label="objective";expression={($_.objective).Substring(0, [Math]::Min(40, $_.objective.Length)) + "..."}}, status -AutoSize

exit 0