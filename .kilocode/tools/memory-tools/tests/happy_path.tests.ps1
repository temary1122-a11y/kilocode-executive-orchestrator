$script:KiloRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path

$script:TestRoot = "C:\Temp\kilo-pester-happy"
if (-not (Test-Path $script:TestRoot)) { New-Item -ItemType Directory -Path $script:TestRoot -Force | Out-Null }

$script:NodePath = $null
try {
    $nodeInfo = Get-Command node -ErrorAction Stop
    $script:NodePath = $nodeInfo.Source
} catch {
    $script:NodePath = $null
}

function New-TestFixture {
    param([string]$Name)
    $dir = Join-Path $script:TestRoot $Name
    if (Test-Path $dir) { Remove-Item $dir -Recurse -Force }
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $dir "memory\delegation\pending") -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $dir "memory\bus") -Force | Out-Null
    return $dir
}

function Invoke-SdkDelegate {
    param([string]$PayloadPath, [string]$FixtureDir)
    if (-not $script:NodePath) {
        Write-Host "SKIP: node not found on PATH, skipping kilo-sdk-delegate.js invocation test"
        return $null
    }
    $stdoutPath = Join-Path $FixtureDir 'stub_stdout.txt'
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $script:NodePath
    $sdkScript = Join-Path $script:KiloRoot 'delegation\kilo-sdk-delegate.js'
    $psi.Arguments = "`"$sdkScript`" `"$PayloadPath`""
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $proc = [System.Diagnostics.Process]::Start($psi)
    $stdout = $proc.StandardOutput.ReadToEnd()
    $stderr = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit()
    $stdout | Set-Content -LiteralPath $stdoutPath -Encoding UTF8
    $stderr | Set-Content -LiteralPath (Join-Path $FixtureDir 'stub_stderr.txt') -Encoding UTF8
    return $stdout
}

Describe "Happy Path: Delegation Fallback" {
    BeforeEach {
        $script:Fixture = New-TestFixture -Name "happy-$(New-Guid)"
    }

    AfterEach {
        if (Test-Path $script:Fixture) { Remove-Item $script:Fixture -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "Loads common.ps1 without errors" {
        { . (Join-Path $script:KiloRoot 'tools\memory-tools\scripts\common.ps1') } | Should Not Throw
    }

    It "Returns default allow policy when no explicit policy is set" {
        . (Join-Path $script:KiloRoot 'tools\memory-tools\scripts\common.ps1')
        $modePath = Join-Path $script:KiloRoot 'modes\executive-orchestrator.md'
        $content = Get-Content $modePath -Raw
        $match = [regex]::Match($content, 'task:\s*(allow|deny)')
        $match.Success | Should Be $true
        $match.Groups[1].Value | Should Be 'allow'
    }

    It "kilo-sdk-delegate.js returns manual_invoke_required" {
        if (-not $script:NodePath) {
            Write-Host "SKIP: node not found — skipping kilo-sdk-delegate.js test"
            return
        }
        $taskId = "test_happy_$(New-Guid)"
        $payload = [ordered]@{
            taskId = $taskId
            role = "coding"
            agent = "coding-agent"
            objective = "Test happy path"
            fileScope = @("src/app.js")
        } | ConvertTo-Json -Depth 5
        $payloadPath = Join-Path $script:Fixture 'payload.json'
        [System.IO.File]::WriteAllText($payloadPath, $payload, [System.Text.UTF8Encoding]::new($false))

        $stdout = Invoke-SdkDelegate -PayloadPath $payloadPath -FixtureDir $script:Fixture
        if (-not $stdout) { return }

        $parsed = $stdout.Trim() | ConvertFrom-Json
        $parsed.ok | Should Be $false
        $parsed.invoked | Should Be $false
        $parsed.reason | Should Be 'manual_invoke_required'
        $parsed.manifestPath | Should Not BeNullOrEmpty
    }

    It "Creates manifest with correct task_id and file_scope" {
        if (-not $script:NodePath) {
            Write-Host "SKIP: node not found — skipping manifest test"
            return
        }
        $taskId = "test_manifest_$(New-Guid)"
        $payload = [ordered]@{
            taskId = $taskId
            role = "coding"
            agent = "coding-agent"
            objective = "Test manifest content"
            fileScope = @("src/app.js", "src/utils.js")
        } | ConvertTo-Json -Depth 5
        $payloadPath = Join-Path $script:Fixture 'payload.json'
        [System.IO.File]::WriteAllText($payloadPath, $payload, [System.Text.UTF8Encoding]::new($false))

        $stdout = Invoke-SdkDelegate -PayloadPath $payloadPath -FixtureDir $script:Fixture
        if (-not $stdout) { return }
        $stdout | Set-Content -LiteralPath (Join-Path $script:Fixture 'stub_stdout2.txt') -Encoding UTF8

        $parsed = $stdout.Trim() | ConvertFrom-Json
        $parsed.ok | Should Be $false
        $parsed.invoked | Should Be $false
        $parsed.reason | Should Be 'manual_invoke_required'
        $parsed.manifestPath | Should Not BeNullOrEmpty

        $manifest = Get-Content -LiteralPath $parsed.manifestPath -Raw | ConvertFrom-Json
        $manifest.task_id | Should Be $taskId
        @('src/app.js', 'src/utils.js') | ForEach-Object {
            ($manifest.file_scope -contains $_) | Should Be $true
        }
        $manifest.status | Should Be 'pending_manual_invoke'
        $manifest.reason | Should Be 'manual_invoke_required'
    }

    It "Publish-Event and Get-BusEvents work end-to-end" {
        . (Join-Path $script:KiloRoot 'tools\memory-tools\scripts\common.ps1')
        Publish-Event -Type 'agent.heartbeat' -Data @{ session_id = 'test_happy_e2e' }
        $events = @(Get-BusEvents)
        $events | Should Not Be $null
        @($events | Where-Object { $_.type -eq 'agent.heartbeat' }).Count | Should BeGreaterThan 0
    }
}
