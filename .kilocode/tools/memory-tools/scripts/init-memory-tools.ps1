<#
.SYNOPSIS
Initialize memory tool aliases for this session
.EXAMPLE
.\init-memory-tools.ps1
#>

# Get the scripts path
$scriptsPath = Split-Path -Parent $MyInvocation.MyCommand.Path

# Create aliases
New-Alias -Name add-task -Value "$scriptsPath\add-task.ps1" -Force
New-Alias -Name update-task -Value "$scriptsPath\update-task-status.ps1" -Force
New-Alias -Name log-decision -Value "$scriptsPath\record-decision.ps1" -Force
New-Alias -Name get-tasks -Value "$scriptsPath\get-active-tasks.ps1" -Force
New-Alias -Name get-last-task -Value "$scriptsPath\get-last-task.ps1" -Force
New-Alias -Name get-current-task -Value "$scriptsPath\get-current-task.ps1" -Force
New-Alias -Name replay-trace -Value "$scriptsPath\replay-trace.ps1" -Force
New-Alias -Name task-dependency -Value "$scriptsPath\task-dependency.ps1" -Force
New-Alias -Name research-report -Value "$scriptsPath\research-report.ps1" -Force
New-Alias -Name user-profile -Value "$scriptsPath\user-profile.ps1" -Force

Write-Host "Memory tools initialized:" -ForegroundColor Green
Write-Host "  add-task <params>" -ForegroundColor Cyan
Write-Host "  update-task <params>" -ForegroundColor Cyan
Write-Host "  log-decision <params>" -ForegroundColor Cyan
Write-Host "  get-tasks <params>" -ForegroundColor Cyan
Write-Host "  get-last-task" -ForegroundColor Cyan
Write-Host "  get-current-task" -ForegroundColor Cyan
Write-Host "  replay-trace <params>" -ForegroundColor Cyan
Write-Host "  task-dependency <action>" -ForegroundColor Cyan
Write-Host "  research-report <params>" -ForegroundColor Cyan
Write-Host "  user-profile <action>" -ForegroundColor Cyan
