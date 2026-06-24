<#
.SYNOPSIS
Generic wrapper to invoke memory tool scripts with suppressed progress UI.
.DESCRIPTION
Accepts a script name and arguments, dot-sources the target script with $ProgressPreference='SilentlyContinue',
and forwards all arguments to the target script. Useful for programmatic invocation where progress
dialogs would be disruptive.
.PARAMETER ScriptName
Name of the script to invoke (e.g., 'add-task', 'health-check')
.PARAMETER Arguments
Arguments to forward to the target script (supports -Param and -Param Value syntax)
.EXAMPLE
.\invoke-memory-tool.ps1 -ScriptName 'add-task' -Arguments '-Type', 'coding', '-Priority', 'p1', '-Objective', 'Test'
#>

param(
    [Parameter(Mandatory=$true)][string]$ScriptName,
    [Parameter(ValueFromRemainingArguments=$true)][string[]]$Arguments
)

$scriptsPath = Split-Path -Parent $MyInvocation.MyCommand.Path
$scriptPath = Join-Path $scriptsPath "$ScriptName.ps1"

if (-not (Test-Path $scriptPath)) {
    Write-Error "Script not found: $scriptPath"
    exit 1
}

# Parse arguments into a hashtable for splatting
$paramHash = @{}
$i = 0
while ($i -lt $Arguments.Count) {
    $arg = $Arguments[$i]
    # Check if this is a switch parameter (starts with - or --)
    if ($arg -match '^-') {
        $paramName = $arg.TrimStart('-')
        # Check if next argument is a value (not another switch)
        if ($i + 1 -lt $Arguments.Count -and $Arguments[$i + 1] -notmatch '^-') {
            $paramValue = $Arguments[$i + 1]
            # Try to convert numeric values
            if ($paramValue -match '^\d+$') {
                $paramHash[$paramName] = [int]$paramValue
            } else {
                $paramHash[$paramName] = $paramValue
            }
            $i += 2
        } else {
            # It's a boolean switch (no value)
            $paramHash[$paramName] = $true
            $i += 1
        }
    } else {
        $i += 1
    }
}

# Suppress progress UI and dot-source the target script
$ProgressPreference = 'SilentlyContinue'
. $scriptPath @paramHash