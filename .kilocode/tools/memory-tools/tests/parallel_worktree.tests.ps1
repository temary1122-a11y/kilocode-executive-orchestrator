<#
.SYNOPSIS
Pester tests for parallel fallback: two roles produce isolated manifests.
#>

$script:TestsRoot = $PSScriptRoot
$script:MemoryToolsRoot = Split-Path -Parent $script:TestsRoot
$script:ToolsRoot = Split-Path -Parent $script:MemoryToolsRoot
$script:KiloRoot = Split-Path -Parent $script:ToolsRoot
$script:DelegateScript = Join-Path $script:KiloRoot 'delegation\kilo-sdk-delegate.js'

$script:TestRoot = "C:\Temp\kilo-pester-parallel"
if (-not (Test-Path $script:TestRoot)) { New-Item -ItemType Directory -Path $script:TestRoot -Force | Out-Null }

function New-TestFixture {
    param([string]$Name)
    $dir = Join-Path $script:TestRoot $Name
    if (Test-Path $dir) { Remove-Item $dir -Recurse -Force }
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $dir "memory\delegation\pending") -Force | Out-Null
    return $dir
}

function Invoke-FallbackStub {
    param([string]$PayloadPath)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'node'
    $psi.Arguments = "`"$script:DelegateScript`" `"$PayloadPath`""
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $proc = [System.Diagnostics.Process]::Start($psi)
    $stdout = $proc.StandardOutput.ReadToEnd()
    $stderr = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit()
    if ($stderr) { Write-Host "STUB_STDERR: $stderr" }
    $stdout.Trim() | ConvertFrom-Json
}

Describe "Parallel Worktree Fallback Isolation" {
    BeforeEach {
        $script:Fixture = New-TestFixture -Name "parallel-$(New-Guid)"
    }

    AfterEach {
        if (Test-Path $script:Fixture) { Remove-Item $script:Fixture -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "Creates separate manifests for two roles without overwriting" {
        $role1Id = "test_parallel_r1_$(New-Guid)"
        $role2Id = "test_parallel_r2_$(New-Guid)"
        $payload1 = [ordered]@{
            taskId = $role1Id
            role = "research"
            agent = "research-agent"
            objective = "Research task"
            fileScope = @("docs/spec.md")
        } | ConvertTo-Json -Depth 5
        $payload2 = [ordered]@{
            taskId = $role2Id
            role = "coding"
            agent = "coding-agent"
            objective = "Coding task"
            fileScope = @("src/app.js")
        } | ConvertTo-Json -Depth 5
        $path1 = Join-Path $script:Fixture 'payload1.json'
        $path2 = Join-Path $script:Fixture 'payload2.json'
        [System.IO.File]::WriteAllText($path1, $payload1, [System.Text.UTF8Encoding]::new($false))
        [System.IO.File]::WriteAllText($path2, $payload2, [System.Text.UTF8Encoding]::new($false))

        $result1 = Invoke-FallbackStub -PayloadPath $path1
        $result2 = Invoke-FallbackStub -PayloadPath $path2

        $result1.invoked | Should Be $false
        $result2.invoked | Should Be $false
        $result1.manifestPath | Should Not Be $result2.manifestPath
        $manifest1 = Get-Content -LiteralPath $result1.manifestPath -Raw | ConvertFrom-Json
        $manifest2 = Get-Content -LiteralPath $result2.manifestPath -Raw | ConvertFrom-Json
        $manifest1.task_id | Should Be $role1Id
        $manifest2.task_id | Should Be $role2Id
        ($manifest1.file_scope -contains 'docs/spec.md') | Should Be $true
        ($manifest2.file_scope -contains 'src/app.js') | Should Be $true
    }

    It "Does not mix file_scope between parallel roles" {
        $id1 = "test_scope_r1_$(New-Guid)"
        $id2 = "test_scope_r2_$(New-Guid)"
        $payload1 = [ordered]@{ taskId=$id1; role="research"; agent="research-agent"; fileScope=@("docs/a.md") } | ConvertTo-Json -Depth 5
        $payload2 = [ordered]@{ taskId=$id2; role="coding"; agent="coding-agent"; fileScope=@("src/b.js") } | ConvertTo-Json -Depth 5
        $path1 = Join-Path $script:Fixture 'p1.json'
        $path2 = Join-Path $script:Fixture 'p2.json'
        [System.IO.File]::WriteAllText($path1, $payload1, [System.Text.UTF8Encoding]::new($false))
        [System.IO.File]::WriteAllText($path2, $payload2, [System.Text.UTF8Encoding]::new($false))
        $r1 = Invoke-FallbackStub -PayloadPath $path1
        $r2 = Invoke-FallbackStub -PayloadPath $path2
        $m1 = Get-Content -LiteralPath $r1.manifestPath -Raw | ConvertFrom-Json
        $m2 = Get-Content -LiteralPath $r2.manifestPath -Raw | ConvertFrom-Json
        $m1.file_scope -notcontains 'src/b.js' | Should Be $true
        $m2.file_scope -notcontains 'docs/a.md' | Should Be $true
    }

    It "Returns distinct manifest paths for distinct task IDs" {
        $baseId = "test_distinct_$(New-Guid)"
        $payloadA = [ordered]@{ taskId="$baseId`_A"; role="research"; agent="research-agent" } | ConvertTo-Json -Depth 5
        $payloadB = [ordered]@{ taskId="$baseId`_B"; role="coding"; agent="coding-agent" } | ConvertTo-Json -Depth 5
        $pathA = Join-Path $script:Fixture 'pa.json'
        $pathB = Join-Path $script:Fixture 'pb.json'
        [System.IO.File]::WriteAllText($pathA, $payloadA, [System.Text.UTF8Encoding]::new($false))
        [System.IO.File]::WriteAllText($pathB, $payloadB, [System.Text.UTF8Encoding]::new($false))
        $rA = Invoke-FallbackStub -PayloadPath $pathA
        $rB = Invoke-FallbackStub -PayloadPath $pathB
        $rA.manifestPath | Should Not Be $rB.manifestPath
    }
}
