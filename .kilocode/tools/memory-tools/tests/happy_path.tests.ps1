$script:KiloRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path

$script:TestRoot = "C:\Temp\kilo-pester-happy"
if (-not (Test-Path $script:TestRoot)) { New-Item -ItemType Directory -Path $script:TestRoot -Force | Out-Null }

function New-TestFixture {
    param([string]$Name)
    $dir = Join-Path $script:TestRoot $Name
    if (Test-Path $dir) { Remove-Item $dir -Recurse -Force }
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $dir "memory\delegation\pending") -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $dir "memory\bus") -Force | Out-Null
    return $dir
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

        $stdoutPath = Join-Path $script:Fixture 'stub_stdout.txt'
        $stderrPath = Join-Path $script:Fixture 'stub_stderr.txt'
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $sdkScript = Join-Path $script:KiloRoot 'delegation\kilo-sdk-delegate.js'
        $psi.Arguments = "`"$sdkScript`" `"$payloadPath`""
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $proc = [System.Diagnostics.Process]::Start($psi)
        $stdout = $proc.StandardOutput.ReadToEnd()
        $stderr = $proc.StandardError.ReadToEnd()
        $proc.WaitForExit()
        $stdout | Set-Content -LiteralPath $stdoutPath -Encoding UTF8
        $stderr | Set-Content -LiteralPath $stderrPath -Encoding UTF8

        $parsed = $stdout.Trim() | ConvertFrom-Json
        $parsed.ok | Should Be $false
        $parsed.invoked | Should Be $false
        $parsed.reason | Should Be 'manual_invoke_required'
        $parsed.manifestPath | Should Not BeNullOrEmpty
    }

    It "Creates manifest with correct task_id and file_scope" {
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

        $stdoutPath = Join-Path $script:Fixture 'stub_stdout2.txt'
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = 'node'
        $sdkScript = Join-Path $script:KiloRoot 'delegation\kilo-sdk-delegate.js'
        $psi.Arguments = "`"$sdkScript`" `"$payloadPath`""
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $proc = [System.Diagnostics.Process]::Start($psi)
        $stdout = $proc.StandardOutput.ReadToEnd()
        $proc.WaitForExit()
        $stdout | Set-Content -LiteralPath $stdoutPath -Encoding UTF8
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
