<#
.SYNOPSIS
Pester tests for batch-memory.ps1
#>

$script:KiloRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path

$script:TestRoot = "C:\Temp\kilo-pester-batch"
if (-not (Test-Path $script:TestRoot)) { New-Item -ItemType Directory -Path $script:TestRoot -Force | Out-Null }

$script:TasksPath = Join-Path $script:KiloRoot "memory\tasks.jsonl"
$script:DecisionsMdPath = Join-Path $script:KiloRoot "memory\decisions.md"
$script:DecisionsJsonlPath = Join-Path $script:KiloRoot "memory\decisions.jsonl"

$script:OriginalTasksContent = ""
$script:OriginalDecisionsMdContent = ""
$script:OriginalDecisionsJsonlContent = ""

function Invoke-Batch {
    param(
        [string]$InputJson = "",
        [string]$InputFile = "",
        [switch]$Quiet,
        [switch]$Json,
        [switch]$ContinueOnError
    )
    $scriptPath = Join-Path $script:KiloRoot 'tools\memory-tools\scripts\batch-memory.ps1'
    $ErrorActionPreference = 'Continue'
    $splat = @{}
    if ($InputJson) { $splat.InputJson = $InputJson }
    if ($InputFile) { $splat.InputFile = $InputFile }
    if ($Quiet) { $splat.Quiet = $true }
    if ($Json) { $splat.Json = $true }
    if ($ContinueOnError) { $splat.ContinueOnError = $true }
    $raw = & $scriptPath @splat 2>&1
    $output = $raw | Out-String
    return $output
}

function Invoke-MemoryToolsBatch {
    param(
        [string]$InputJson = "",
        [string]$InputFile = "",
        [switch]$Quiet,
        [switch]$Json,
        [switch]$ContinueOnError
    )
    $scriptPath = Join-Path $script:KiloRoot 'tools\memory-tools\scripts\memory-tools.ps1'
    $ErrorActionPreference = 'Continue'
    $args = @("batch")
    if ($InputJson) { $args += @("-InputJson", $InputJson) }
    if ($InputFile) { $args += @("-InputFile", $InputFile) }
    if ($Quiet) { $args += "-Quiet" }
    if ($Json) { $args += "-Json" }
    if ($ContinueOnError) { $args += "-ContinueOnError" }
    $raw = & $scriptPath @args 2>&1
    $output = $raw | Out-String
    return $output
}

Describe "batch-memory.ps1" {
    BeforeAll {
        if (-not $script:OriginalTasksContentSet) {
            if (Test-Path $script:TasksPath) {
                $script:OriginalTasksContent = Get-Content $script:TasksPath -Raw
            }
            if (Test-Path $script:DecisionsMdPath) {
                $script:OriginalDecisionsMdContent = Get-Content $script:DecisionsMdPath -Raw
            }
            if (Test-Path $script:DecisionsJsonlPath) {
                $script:OriginalDecisionsJsonlContent = Get-Content $script:DecisionsJsonlPath -Raw
            }
            $script:OriginalTasksContentSet = $true
        }
        "" | Set-Content $script:TasksPath -Encoding UTF8
        if (Test-Path $script:DecisionsMdPath) {
            "" | Set-Content $script:DecisionsMdPath -Encoding UTF8
        }
        if (Test-Path $script:DecisionsJsonlPath) {
            "" | Set-Content $script:DecisionsJsonlPath -Encoding UTF8
        }
    }

    AfterAll {
        if ($script:OriginalTasksContentSet) {
            if ($script:OriginalTasksContent) {
                Set-Content $script:TasksPath $script:OriginalTasksContent -Encoding UTF8
            } else {
                Remove-Item $script:TasksPath -Force -ErrorAction SilentlyContinue
            }
            if ($script:OriginalDecisionsMdContent) {
                Set-Content $script:DecisionsMdPath $script:OriginalDecisionsMdContent -Encoding UTF8
            } else {
                Remove-Item $script:DecisionsMdPath -Force -ErrorAction SilentlyContinue
            }
            if ($script:OriginalDecisionsJsonlContent) {
                Set-Content $script:DecisionsJsonlPath $script:OriginalDecisionsJsonlContent -Encoding UTF8
            } else {
                Remove-Item $script:DecisionsJsonlPath -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "Outputs valid one-line JSON for add-task + record-decision" {
        $ops = @(
            @{ op = "add-task"; type = "coding"; priority = "p1"; objective = "Batch validation task"; agent = "coding-agent" },
            @{ op = "record-decision"; topic = "batch-validation"; problem = "noise"; choice = "batch-memory"; rationale = "reduce shell calls" }
        ) | ConvertTo-Json -Depth 10 -Compress
        $output = Invoke-Batch -InputJson $ops -Quiet -Json
        $parsed = $output | ConvertFrom-Json
        $parsed.ok | Should Be $true
        $parsed.operation | Should Be "batch"
        $parsed.total | Should Be 2
        $parsed.succeeded | Should Be 2
        $parsed.failed | Should Be 0
        $parsed.results.Count | Should Be 2
        $parsed.results[0].op | Should Be "add-task"
        $parsed.results[0].ok | Should Be $true
        $parsed.results[0].task_id | Should Match "^task_"
        $parsed.results[1].op | Should Be "record-decision"
        $parsed.results[1].ok | Should Be $true
        $parsed.results[1].id | Should Not BeNullOrEmpty
    }

    It "Does NOT contain human-readable progress text in quiet-json mode" {
        $ops = @(
            @{ op = "add-task"; type = "coding"; priority = "p1"; objective = "Quiet batch test"; agent = "coding-agent" }
        ) | ConvertTo-Json -Depth 10 -Compress
        $output = Invoke-Batch -InputJson $ops -Quiet -Json
        $output | Should Not Match "added successfully"
        $output | Should Not Match "Decision recorded"
    }

    It "Updates task status via add-task then update-task-status batch" {
        Start-Sleep -Seconds 1
        $ops = @(
            @{ op = "add-task"; type = "coding"; priority = "p1"; objective = "Status batch test"; agent = "coding-agent" },
            @{ op = "update-task-status"; task_id = "last"; status = "in_progress" }
        ) | ConvertTo-Json -Depth 10 -Compress
        $output = Invoke-Batch -InputJson $ops -Quiet -Json
        $parsed = $output | ConvertFrom-Json
        $parsed.ok | Should Be $true
        $parsed.results[1].status | Should Be "in_progress"
        $taskId = $parsed.results[0].task_id
        $taskId | Should Not BeNullOrEmpty
        $lines = Get-Content $script:TasksPath | Where-Object { $_.Trim() }
        $found = $false
        foreach ($line in $lines) {
            $obj = $line | ConvertFrom-Json
            if ($obj.task_id -eq $taskId) {
                $obj.status | Should Be "in_progress"
                $found = $true
                break
            }
        }
        $found | Should Be $true
    }

    It "Stops on first failure by default with stopped_at" {
        $ops = @(
            @{ op = "add-task"; type = "coding"; priority = "p1"; objective = "Stop test"; agent = "coding-agent" },
            @{ op = "update-task-status"; task_id = "task_nonexistent"; status = "completed" }
        ) | ConvertTo-Json -Depth 10 -Compress
        $output = Invoke-Batch -InputJson $ops -Quiet -Json
        $parsed = $output | ConvertFrom-Json
        $parsed.ok | Should Be $false
        $parsed.results.Count | Should Be 2
        $parsed.results[0].ok | Should Be $true
        $parsed.results[1].ok | Should Be $false
        $parsed.results[1].error | Should Match "task_not_found"
        $parsed.stopped_at | Should Be 1
    }

    It "Continues on error when -ContinueOnError is passed" {
        $ops = @(
            @{ op = "add-task"; type = "coding"; priority = "p1"; objective = "Continue test 1"; agent = "coding-agent" },
            @{ op = "update-task-status"; task_id = "task_nonexistent"; status = "completed" },
            @{ op = "record-decision"; topic = "continue"; choice = "yes"; problem = "test"; rationale = "testing" }
        ) | ConvertTo-Json -Depth 10 -Compress
        $output = Invoke-Batch -InputJson $ops -Quiet -Json -ContinueOnError
        $parsed = $output | ConvertFrom-Json
        $parsed.ok | Should Be $false
        $parsed.results.Count | Should Be 3
        $parsed.results[0].ok | Should Be $true
        $parsed.results[1].ok | Should Be $false
        $parsed.results[2].ok | Should Be $true
    }

    It "Returns structured error when neither InputFile nor InputJson is provided" {
        $output = Invoke-Batch -Quiet -Json
        $parsed = $output | ConvertFrom-Json
        $parsed.ok | Should Be $false
        $parsed.error | Should Match "Either -InputFile or -InputJson"
    }

    It "Reads from InputFile correctly" {
        $ops = @(
            @{ op = "add-task"; type = "coding"; priority = "p1"; objective = "InputFile test"; agent = "coding-agent" }
        ) | ConvertTo-Json -Depth 10 -Compress
        $tmpFile = Join-Path $script:TestRoot ("batch_input_" + (New-Guid) + ".json")
        $ops | Set-Content -LiteralPath $tmpFile -Encoding UTF8
        $output = Invoke-Batch -InputFile $tmpFile -Quiet -Json
        $parsed = $output | ConvertFrom-Json
        $parsed.ok | Should Be $true
        $parsed.results[0].op | Should Be "add-task"
        Remove-Item $tmpFile -Force -ErrorAction SilentlyContinue
    }

    It "memory-tools.ps1 batch passthrough works" {
        $ops = @(
            @{ op = "add-task"; type = "coding"; priority = "p1"; objective = "Passthrough test"; agent = "coding-agent" }
        ) | ConvertTo-Json -Depth 10 -Compress
        $output = Invoke-MemoryToolsBatch -InputJson $ops -Quiet -Json
        $parsed = $output | ConvertFrom-Json
        $parsed.ok | Should Be $true
        $parsed.operation | Should Be "batch"
        $parsed.results[0].ok | Should Be $true
    }
}
