<#
.SYNOPSIS
Validates that requested file scopes do not overlap with any currently active tasks.
.DESCRIPTION
Prevents race conditions by ensuring no two running tasks can modify the same files.
.PARAMETER TaskId
The ID of the task requesting execution.
.PARAMETER FileScopes
Array of file or directory paths the task intends to modify.
#>
param(
    [Parameter(Mandatory=$true)][string]$TaskId,
    [Parameter(Mandatory=$true)][string[]]$FileScopes
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\common.ps1"

function Normalize-PathValue {
    param([string]$Value)
    if (-not $Value) { return '' }
    $normalized = $Value.Trim().Replace('\', '/')
    $normalized = $normalized -replace '/{2,}', '/'
    return $normalized.TrimEnd('/').ToLowerInvariant()
}

function Test-PathOverlap {
    param([string]$Left, [string]$Right)
    $left = Normalize-PathValue $Left
    $right = Normalize-PathValue $Right
    if (-not $left -or -not $right) { return $false }
    if ($left -eq $right) { return $true }
    if ($left.StartsWith("$right/") -or $right.StartsWith("$left/")) { return $true }
    return $false
}

$tasksPath = Get-TasksPath
if (-not (Test-Path -LiteralPath $tasksPath)) {
    Write-Output "OK"
    exit 0
}

$activeTasks = Read-JsonlSafe -Path $tasksPath | Where-Object {
    $_.status -eq 'in_progress' -and $_.task_id -ne $TaskId
}

$overlaps = @()
foreach ($scope in $FileScopes) {
    foreach ($activeTask in $activeTasks) {
        $activeScopes = @()
        if ($activeTask.PSObject.Properties.Name -contains 'file_scope') {
            $val = $activeTask.file_scope
            if ($val -is [string]) {
                if ($val.Trim() -match '^\[') {
                    try { $activeScopes = $val | ConvertFrom-Json } catch { $activeScopes = $val -split ',' }
                } else {
                    $activeScopes = $val -split ','
                }
            } elseif ($val -is [array]) {
                $activeScopes = $val
            }
        }
        
        foreach ($activeScope in $activeScopes) {
            $cleanActiveScope = [string]$activeScope | ForEach-Object { $_.Trim() } | Where-Object { $_ }
            if ($cleanActiveScope -and (Test-PathOverlap -Left $scope -Right $cleanActiveScope)) {
                $overlaps += "Conflict with active task $($activeTask.task_id): requested '$scope', active owns '$cleanActiveScope'"
            }
        }
    }
}

if ($overlaps.Count -gt 0) {
    Write-Error "File scope guard failed. Overlaps detected:`n$($overlaps -join "`n")"
    Write-ExecutionTrace -TaskId $TaskId -Phase 'scope-guard' -Status 'failed' -Data @{ overlaps = $overlaps } -Event 'scope_guard.failed' -Actor 'file-scope-guard' -FailureMode 'file_scope_conflict' | Out-Null
    exit 1
}

Write-ExecutionTrace -TaskId $TaskId -Phase 'scope-guard' -Status 'passed' -Data @{} -Event 'scope_guard.passed' -Actor 'file-scope-guard' | Out-Null

Write-Output "OK"
exit 0
