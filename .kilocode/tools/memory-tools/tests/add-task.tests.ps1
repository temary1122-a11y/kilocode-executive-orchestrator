<#
.SYNOPSIS
Pester tests for add-task.ps1
#>

$script:TestsRoot = $PSScriptRoot
$script:MemoryToolsRoot = Split-Path -Parent $script:TestsRoot
$script:ToolsRoot = Split-Path -Parent $script:MemoryToolsRoot

$script:TestRoot = "C:\Temp\kilo-pester"
if (-not (Test-Path $script:TestRoot)) { New-Item -ItemType Directory -Path $script:TestRoot -Force | Out-Null }

function New-TestFixture {
    param([string]$Name)
    $dir = Join-Path $script:TestRoot $Name
    if (Test-Path $dir) { Remove-Item $dir -Recurse -Force }
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $dir "memory\tasks") -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $dir "memory\decisions") -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $dir "memory\checkpoints") -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $dir "memory\execution-traces") -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $dir "memory\context-enrichment") -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $dir "memory\research-reports") -Force | Out-Null
    return $dir
}

function Invoke-AddTask {
    param(
        [string]$Type = "coding",
        [string]$Priority = "p1",
        [string]$Objective = "Test objective",
        [string]$Agent = "coding-agent",
        [string]$FixtureDir
    )
    Push-Location $FixtureDir
    try {
        $scriptPath = Join-Path $script:MemoryToolsRoot 'scripts\add-task.ps1'
        $ErrorActionPreference = 'Continue'
        $out = & $scriptPath -Type $Type -Priority $Priority -Objective $Objective -Agent $Agent 2>&1
        return $out
    } finally {
        Pop-Location
    }
}

Describe "Add-Task.ps1" {
    BeforeEach {
        $script:Fixture = New-TestFixture -Name "add-task-$(New-Guid)"
    }

    AfterEach {
        if (Test-Path $script:Fixture) { Remove-Item $script:Fixture -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "Rejects invalid Type" {
        $output = Invoke-AddTask -FixtureDir $script:Fixture -Type "invalid"
        $output | Should Match "Type must be"
    }

    It "Rejects invalid Priority" {
        $output = Invoke-AddTask -FixtureDir $script:Fixture -Priority "p3"
        $output | Should Match "Priority must be"
    }

    It "Creates task with basic parameters" {
        $output = Invoke-AddTask -FixtureDir $script:Fixture
        $output | Should Match "added successfully"
        $tasksPath = Join-Path $script:Fixture "memory\tasks.jsonl"
        Test-Path $tasksPath | Should Be $true
        $content = Get-Content $tasksPath -Raw
        $content | Should Match '"task_id"'
        $content | Should Match '"status"'
    }

    It "Parses comma-separated DependsOn" {
        $output = Invoke-AddTask -FixtureDir $script:Fixture -DependsOn "task_a,task_b"
        $tasksPath = Join-Path $script:Fixture "memory\tasks.jsonl"
        $line = Get-Content $tasksPath | Select-Object -Last 1 | ConvertFrom-Json
        @($line.depends_on) | Should Contain "task_a"
        @($line.depends_on) | Should Contain "task_b"
    }

    It "Parses JSON array DependsOn" {
        $output = Invoke-AddTask -FixtureDir $script:Fixture -DependsOn '["task_x","task_y"]'
        $tasksPath = Join-Path $script:Fixture "memory\tasks.jsonl"
        $line = Get-Content $tasksPath | Select-Object -Last 1 | ConvertFrom-Json
        @($line.depends_on) | Should Contain "task_x"
        @($line.depends_on) | Should Contain "task_y"
    }

    It "Sets type and priority correctly" {
        Invoke-AddTask -FixtureDir $script:Fixture -Type "research" -Priority "p0" | Out-Null
        $tasksPath = Join-Path $script:Fixture "memory\tasks.jsonl"
        $line = Get-Content $tasksPath | Select-Object -Last 1 | ConvertFrom-Json
        $line.type | Should Be "research"
        $line.priority | Should Be "p0"
    }

    It "Generates unique task IDs from timestamp" {
        Invoke-AddTask -FixtureDir $script:Fixture | Out-Null
        Invoke-AddTask -FixtureDir $script:Fixture | Out-Null
        $tasksPath = Join-Path $script:Fixture "memory\tasks.jsonl"
        $lines = Get-Content $tasksPath | Where-Object { $_.Trim() } | ForEach-Object { ConvertFrom-Json $_ }
        ($lines | Select-Object -ExpandProperty task_id -Unique).Count | Should Be 2
    }
}
