param(
    [string]$TestRoot = $PSScriptRoot,
    [string[]]$Pattern = @('happy_path.tests.ps1', 'parallel_worktree.tests.ps1', 'task_deny_recovery.tests.ps1', 'context_enrichment_smoke.tests.ps1')
)

$ErrorActionPreference = 'SilentlyContinue'
Import-Module Pester -ErrorAction SilentlyContinue
if (-not (Get-Module Pester)) {
    Write-Host 'Pester module not available. Install it first.'
    exit 1
}

$results = @()
foreach ($file in $Pattern) {
    $path = Join-Path $TestRoot $file
    if (-not (Test-Path $path)) {
        Write-Host "SKIP: $file not found"
        continue
    }
    $r = Invoke-Pester -Script $path -PassThru -EnableExit:$false
    $results += [pscustomobject]@{ File = $file; Passed = $r.PassedCount; Failed = $r.FailedCount; Skipped = $r.SkippedCount; Total = $r.TotalCount }
    Write-Host "$file => Passed:$($r.PassedCount) Failed:$($r.FailedCount) Skipped:$($r.SkippedCount) Total:$($r.TotalCount)"
}

$totalFailed = ($results | Measure-Object -Property Failed -Sum).Sum
Write-Host "`nTotal Failed: $totalFailed"
exit $totalFailed
