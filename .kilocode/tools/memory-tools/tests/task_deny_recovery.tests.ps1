<#
.SYNOPSIS
Pester tests for delegation policy: default=allow, explicit deny, env override.
#>

$script:TestsRoot = $PSScriptRoot
$script:MemoryToolsRoot = Split-Path -Parent $script:TestsRoot
$script:ToolsRoot = Split-Path -Parent $script:MemoryToolsRoot
$script:KiloRoot = Split-Path -Parent $script:ToolsRoot
$script:ModeFile = Join-Path $script:KiloRoot 'modes\executive-orchestrator.md'

$script:TestRoot = "C:\Temp\kilo-pester-deny"
if (-not (Test-Path $script:TestRoot)) { New-Item -ItemType Directory -Path $script:TestRoot -Force | Out-Null }

function New-TestFixture {
    param([string]$Name)
    $dir = Join-Path $script:TestRoot $Name
    if (Test-Path $dir) { Remove-Item $dir -Recurse -Force }
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    return $dir
}

function Get-PolicyFromModeContent {
    param([string]$Content, [string]$EnvPolicy)
    $policyAllowed = $true
    $policyReason = ''
    if ($EnvPolicy -eq 'allow') {
        $policyAllowed = $true; $policyReason = 'env_allow'
    } elseif ($EnvPolicy -eq 'deny') {
        $policyAllowed = $false; $policyReason = 'env_deny'
    } elseif ($Content -match 'task:\s*(allow|deny)') {
        $policyAllowed = ($Matches[1] -eq 'allow')
        $policyReason = "mode:$($Matches[1])"
    } else {
        $policyAllowed = $true; $policyReason = 'default_allow'
    }
    return [pscustomobject]@{ allowed = $policyAllowed; reason = $policyReason }
}

Describe "Delegation Policy: Default Allow" {
    BeforeEach {
        $script:Fixture = New-TestFixture -Name "deny-$(New-Guid)"
    }

    AfterEach {
        if (Test-Path $script:Fixture) { Remove-Item $script:Fixture -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "Defaults to allow when no explicit policy is present" {
        $content = "Some random content without policy"
        $result = Get-PolicyFromModeContent -Content $content -EnvPolicy ''
        $result.allowed | Should Be $true
        $result.reason | Should Be 'default_allow'
    }

    It "Respects explicit task: allow" {
        $content = "task: allow`nOther settings"
        $result = Get-PolicyFromModeContent -Content $content -EnvPolicy ''
        $result.allowed | Should Be $true
        $result.reason | Should Be 'mode:allow'
    }

    It "Respects explicit task: deny" {
        $content = "task: deny`nOther settings"
        $result = Get-PolicyFromModeContent -Content $content -EnvPolicy ''
        $result.allowed | Should Be $false
        $result.reason | Should Be 'mode:deny'
    }

    It "Env override deny takes precedence over mode allow" {
        $content = "task: allow"
        $result = Get-PolicyFromModeContent -Content $content -EnvPolicy 'deny'
        $result.allowed | Should Be $false
        $result.reason | Should Be 'env_deny'
    }

    It "Env override allow takes precedence over mode deny" {
        $content = "task: deny"
        $result = Get-PolicyFromModeContent -Content $content -EnvPolicy 'allow'
        $result.allowed | Should Be $true
        $result.reason | Should Be 'env_allow'
    }

    It "Executive orchestrator mode file has task: allow as active policy" {
        $content = Get-Content -LiteralPath $script:ModeFile -Raw
        $result = Get-PolicyFromModeContent -Content $content -EnvPolicy ''
        $result.allowed | Should Be $true
        $result.reason | Should Be 'mode:allow'
    }
}
