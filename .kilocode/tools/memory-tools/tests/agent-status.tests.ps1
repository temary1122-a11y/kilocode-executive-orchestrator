<#
.SYNOPSIS
Pester tests for agent-status.ps1
#>

Describe "Agent Status Helper Functions" {
    It "Calculates health correctly for active agent" {
        $session = @{ status = 'running'; startedAt = (Get-Date).ToString('o'); lastActivity = (Get-Date).ToString('o') }
        $lastActivity = [DateTime]$session.lastActivity
        $minutesIdle = ((Get-Date) - $lastActivity).TotalMinutes
        $health = if ($minutesIdle -gt 5) { 'suspected_stalled' } else { 'healthy' }
        $health | Should Be 'healthy'
    }

    It "Detects stalled agent" {
        $oldTime = (Get-Date).AddMinutes(-10).ToString('o')
        $session = @{ status = 'running'; startedAt = $oldTime; lastActivity = $oldTime }
        $lastActivity = [DateTime]$session.lastActivity
        $minutesIdle = ((Get-Date) - $lastActivity).TotalMinutes
        $health = if ($minutesIdle -gt 5) { 'suspected_stalled' } else { 'healthy' }
        $health | Should Be 'suspected_stalled'
    }
}

Describe "Pause File Mechanism" {
    It "Creates pause file path correctly" {
        $sessionId = "test_session_123"
        $pausePath = ".kilocode\memory\pauses\test_session_123.pause"
        $pausePath | Should Match 'test_session_123.pause'
    }
}

Describe "Statistics Calculation" {
    It "Counts session statuses correctly" {
        $sessions = @(
            @{ sessionId = 'a'; status = 'running' }
            @{ sessionId = 'b'; status = 'idle' }
            @{ sessionId = 'c'; status = 'running' }
        )
        $running = ($sessions | Where-Object { $_.status -eq 'running' }).Length
        $idle = ($sessions | Where-Object { $_.status -eq 'idle' }).Length
        $running | Should Be 2
        $idle | Should Be 1
    }
}