<#
.SYNOPSIS
Perform a quick health check of the Orchestrator memory layer.
.DESCRIPTION
Verifies that required directories and files exist and that JSONL files are valid.
Outputs a summary and exits with code 0 on success, 1 on failure.
#>

. "$PSScriptRoot\common.ps1"

$memoryPath = Get-MemoryPath
$tasksPath = Get-TasksPath
$statePath = Get-StatePath
$decisionsMdPath = Get-DecisionsMdPath
$checkpointsPath = Get-CheckpointsPath
Ensure-MemoryDirectories

$required = @(
    @{path=$tasksPath; type='file'},
    @{path=$decisionsMdPath; type='file'},
    @{path=$checkpointsPath; type='dir'},
    @{path=$statePath; type='file'}
)

$allOk = $true
$errors = @()

foreach ($item in $required) {
    if ($item.type -eq 'file') {
        if (-not (Test-Path $item.path)) {
            $errors += "$($item.path) missing"
            $allOk = $false
        } else {
            # JSONL validation: each line must be valid JSON
            if ($item.path -match '\.jsonl$') {
                try {
                    $lines = Get-Content $item.path | Where-Object { $_ -and $_.Trim() }
                    foreach ($line in $lines) {
                        $line.Trim() | ConvertFrom-Json | Out-Null
                    }
                } catch {
                    $errors += "$($item.path) invalid JSONL: $($_.Exception.Message)"
                    $allOk = $false
                }
            }
        }
    } elseif ($item.type -eq 'dir') {
        if (-not (Test-Path $item.path)) {
            $errors += "$($item.path) missing"
            $allOk = $false
        }
    }
}

if ($allOk) { 
    try {
        Sync-SystemStateFromTasks
    } catch {
        $errors += "state sync failed: $($_.Exception.Message)"
        $allOk = $false
    }
}

if ($allOk) { 
    Write-Log 'Health check passed - all components healthy' -Level 'INFO'
    Write-ExecutionTrace -TaskId 'system' -Phase 'health-check' -Status 'passed' -Data @{} -Event 'health-check.passed' -Actor 'health-check' | Out-Null
    exit 0 
} else { 
    $errors | ForEach-Object { Write-Log $_ -Level 'ERROR' }
    Write-Log 'Health check failed - resolve errors above' -Level 'ERROR'
    Write-ExecutionTrace -TaskId 'system' -Phase 'health-check' -Status 'failed' -Data @{ errors = $errors } -Event 'health-check.failed' -Actor 'health-check' -FailureMode 'health_check_failure' | Out-Null
    exit 1 
}
