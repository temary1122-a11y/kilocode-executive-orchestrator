# Aliases for memory scripts
$scriptsPath = "$PSScriptRoot"

Set-Alias -Name add-task -Value "$scriptsPath\add-task.ps1" -Option AllScope
Set-Alias -Name update-task -Value "$scriptsPath\update-task-status.ps1" -Option AllScope
Set-Alias -Name get-tasks -Value "$scriptsPath\get-active-tasks.ps1" -Option AllScope
Set-Alias -Name log-decision -Value "$scriptsPath\record-decision.ps1" -Option AllScope
Set-Alias -Name get-last-task -Value "$scriptsPath\get-last-task.ps1" -Option AllScope
Set-Alias -Name get-current-task -Value "$scriptsPath\get-current-task.ps1" -Option AllScope
Set-Alias -Name task-dependency -Value "$scriptsPath\task-dependency.ps1" -Option AllScope
Set-Alias -Name research-report -Value "$scriptsPath\research-report.ps1" -Option AllScope
Set-Alias -Name user-profile -Value "$scriptsPath\user-profile.ps1" -Option AllScope
Set-Alias -Name parallel-runner -Value "$scriptsPath\parallel-runner.ps1" -Option AllScope
