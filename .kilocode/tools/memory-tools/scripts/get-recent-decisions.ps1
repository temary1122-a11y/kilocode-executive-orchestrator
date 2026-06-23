<#
.SYNOPSIS
Get recent decisions from decisions.md (last 5)
.EXAMPLE
.\get-recent-decisions.ps1
#>

param(
    [int]$Count = 5
)

$decisionsPath = "$PSScriptRoot/../decisions.md"
$content = Get-Content $decisionsPath

# Extract decision sections (### headers)
$decisions = $content | Select-String -Pattern "^### \d{4}-\d{2}-\d{2} .+$" | Select-Object -Last $Count

$decisions | ForEach-Object { Write-Host $_.Line -ForegroundColor Yellow }