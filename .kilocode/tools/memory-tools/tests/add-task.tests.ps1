<#
.SYNOPSIS
Pester tests for add-task.ps1
#>

$script:TestRoot = "C:\Temp\kilo-pester"
if (-not (Test-Path $script:TestRoot)) { New-Item -ItemType Directory -Path $script:TestRoot -Force | Out-Null }

$script:KiloRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$script:RealTasksPath = Join-Path $script:KiloRoot "memory\tasks.jsonl"
$script:OriginalTasksContent = ""

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
        [string]$FixtureDir,
        [string]$DependsOn = "",
        [string]$ParentId = ""
    )
    Push-Location $FixtureDir
    try {
        $scriptPath = Join-Path $script:KiloRoot 'tools\memory-tools\scripts\add-task.ps1'
        $ErrorActionPreference = 'Continue'
        $splat = @{ Type = $Type; Priority = $Priority; Objective = $Objective; Agent = $Agent }
        if ($DependsOn) { $splat.DependsOn = $DependsOn }
        if ($ParentId)  { $splat.ParentId = $ParentId }
        $out = & $scriptPath @splat 2>&1
        return $out
    } finally {
        Pop-Location
    }
}

Describe "Add-Task.ps1" {
    BeforeEach {
        if (-not $script:OriginalTasksContentSet) {
            if (Test-Path $script:RealTasksPath) {
                $script:OriginalTasksContent = Get-Content $script:RealTasksPath -Raw
                $script:OriginalTasksContentSet = $true
            }
        }
        "" | Set-Content $script:RealTasksPath -Encoding UTF8
        $script:Fixture = New-TestFixture -Name "add-task-$(New-Guid)"
    }

    AfterEach {
        if (Test-Path $script:Fixture) { Remove-Item $script:Fixture -Recurse -Force -ErrorAction SilentlyContinue }
        if ($script:OriginalTasksContentSet) {
            Set-Content $script:RealTasksPath $script:OriginalTasksContent -Encoding UTF8
        }
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
        Invoke-AddTask -FixtureDir $script:Fixture | Out-Null
        Test-Path $script:RealTasksPath | Should Be $true
        $content = Get-Content $script:RealTasksPath -Raw
        $content | Should Match '"task_id"'
        $content | Should Match '"status"'
    }

    It "Parses comma-separated DependsOn" {
        Invoke-AddTask -FixtureDir $script:Fixture -DependsOn "task_a,task_b" | Out-Null
        $line = Get-Content $script:RealTasksPath | Where-Object { $_.Trim() } | Select-Object -Last 1
        $line | Should Match '"depends_on":\s*\[[^\]]*"task_a"[^\]]*\]'
        $line | Should Match '"depends_on":\s*\[[^\]]*"task_b"[^\]]*\]'
    }

    It "Parses JSON array DependsOn" {
        Invoke-AddTask -FixtureDir $script:Fixture -DependsOn '["task_x","task_y"]' | Out-Null
        $line = Get-Content $script:RealTasksPath | Where-Object { $_.Trim() } | Select-Object -Last 1
        $line | Should Match '"depends_on":\s*\[[^\]]*"task_x"[^\]]*\]'
        $line | Should Match '"depends_on":\s*\[[^\]]*"task_y"[^\]]*\]'
    }

    It "Sets type and priority correctly" {
        Invoke-AddTask -FixtureDir $script:Fixture -Type "research" -Priority "p0" | Out-Null
        $line = Get-Content $script:RealTasksPath | Where-Object { $_.Trim() } | Select-Object -Last 1 | ConvertFrom-Json
        $line.type | Should Be "research"
        $line.priority | Should Be "p0"
    }

    It "Generates unique task IDs from timestamp" {
        Start-Sleep -Seconds 1
        Invoke-AddTask -FixtureDir $script:Fixture | Out-Null
        Start-Sleep -Seconds 1
        Invoke-AddTask -FixtureDir $script:Fixture | Out-Null
        $lines = Get-Content $script:RealTasksPath | Where-Object { $_.Trim() } | ForEach-Object { ConvertFrom-Json $_ }
        ($lines | Select-Object -ExpandProperty task_id -Unique).Count | Should Be 2
    }
}
