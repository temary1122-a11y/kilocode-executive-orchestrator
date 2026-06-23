<#
.SYNOPSIS
Pester tests for Quiet/Json/NoProgress support in memory-tools
#>

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
    New-Item -ItemType Directory -Path (Join-Path $dir "memory\heartbeats") -Force | Out-Null
    return $dir
}

$script:KiloRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path

Describe "Test-QuietMode" {
    BeforeAll {
        . (Join-Path $script:KiloRoot 'tools\memory-tools\scripts\common.ps1')
    }
    It "Returns true when -Quiet is passed" {
        (Test-QuietMode -Quiet) | Should Be $true
    }
    It "Returns false when no flags and no env var" {
        (Test-QuietMode) | Should Be $false
    }
    It "Returns true when KILO_QUIET=1" {
        $env:KILO_QUIET = '1'
        try { (Test-QuietMode) | Should Be $true } finally { $env:KILO_QUIET = '' }
    }
    It "Returns true when KILO_QUIET=true" {
        $env:KILO_QUIET = 'true'
        try { (Test-QuietMode) | Should Be $true } finally { $env:KILO_QUIET = '' }
    }
}

Describe "Write-QuietAwareHost" {
    BeforeAll {
        . (Join-Path $script:KiloRoot 'tools\memory-tools\scripts\common.ps1')
    }
    It "Suppresses output in quiet mode" {
        $output = & {
            Write-QuietAwareHost -Message "HELLO_QUIET_TEST" -Quiet
        }
        $output | Should Be $null
    }
    It "Write-QuietAwareHost function is defined and callable" {
        $func = Get-Command Write-QuietAwareHost -ErrorAction SilentlyContinue
        $func | Should Not Be $null
    }
}

Describe "add-task.ps1 -Quiet -Json" {
    BeforeEach {
        $script:Fixture = New-TestFixture -Name ("add-task-json-" + (New-Guid))
    }
    AfterEach {
        if (Test-Path $script:Fixture) { Remove-Item $script:Fixture -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It "Outputs valid JSON without progress text" {
        Push-Location $script:Fixture
        try {
            $scriptPath = Join-Path $script:KiloRoot 'tools\memory-tools\scripts\add-task.ps1'
            $ErrorActionPreference = 'Continue'
            $raw = & $scriptPath -Type coding -Priority p1 -Objective "Quiet test" -Agent coding-agent -Quiet -Json 2>&1
            $output = $raw | Out-String
            # Should be valid JSON
            $parsed = $output | ConvertFrom-Json
            $parsed.ok | Should Be $true
            $parsed.operation | Should Be "add-task"
            $parsed.task_id | Should Match "^task_"
        } finally {
            Pop-Location
        }
    }
    It "Does NOT contain human-readable progress text" {
        Push-Location $script:Fixture
        try {
            $scriptPath = Join-Path $script:KiloRoot 'tools\memory-tools\scripts\add-task.ps1'
            $ErrorActionPreference = 'Continue'
            $raw = & $scriptPath -Type coding -Priority p1 -Objective "Quiet test" -Agent coding-agent -Quiet -Json 2>&1
            $output = $raw | Out-String
            $output | Should Not Match "added successfully"
        } finally {
            Pop-Location
        }
    }
}

Describe "record-decision.ps1 -Quiet -Json" {
    BeforeEach {
        $script:Fixture = New-TestFixture -Name ("record-decision-json-" + (New-Guid))
    }
    AfterEach {
        if (Test-Path $script:Fixture) { Remove-Item $script:Fixture -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It "Outputs valid JSON without progress text" {
        Push-Location $script:Fixture
        try {
            $scriptPath = Join-Path $script:KiloRoot 'tools\memory-tools\scripts\record-decision.ps1'
            $ErrorActionPreference = 'Continue'
            $raw = & $scriptPath -Topic "Test" -Problem "P" -Choice "C" -Rationale "R" -Quiet -Json 2>&1
            $output = $raw | Out-String
            $parsed = $output | ConvertFrom-Json
            $parsed.ok | Should Be $true
            $parsed.operation | Should Be "record-decision"
            $parsed.id | Should Not BeNullOrEmpty
        } finally {
            Pop-Location
        }
    }
    It "Does NOT contain human-readable progress text" {
        Push-Location $script:Fixture
        try {
            $scriptPath = Join-Path $script:KiloRoot 'tools\memory-tools\scripts\record-decision.ps1'
            $ErrorActionPreference = 'Continue'
            $raw = & $scriptPath -Topic "Test" -Problem "P" -Choice "C" -Rationale "R" -Quiet -Json 2>&1
            $output = $raw | Out-String
            $output | Should Not Match "Decision recorded to"
        } finally {
            Pop-Location
        }
    }
}
