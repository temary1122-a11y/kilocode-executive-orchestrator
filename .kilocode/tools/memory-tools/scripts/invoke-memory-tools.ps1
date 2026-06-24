<#
.SYNOPSIS
Invokes memory-tool scripts with suppressed progress UI and optional JSON output.

.DESCRIPTION
Generic wrapper for invoking memory-tool scripts by name. Sets $ProgressPreference='SilentlyContinue'
to suppress progress UI dialogs, dot-sources the target script with provided arguments, and supports
returning JSON-formatted results for programmatic consumption.

.PARAMETER ScriptName
Name of the script to invoke without the .ps1 extension (e.g., 'add-task', 'health-check', 'batch-memory').

.PARAMETER Arguments
Arguments to forward to the target script. Supports both '-Param Value' and '-Param', 'Value' syntaxes.
Switch parameters (e.g., '-Json', '-Quiet') are passed as boolean flags.

.PARAMETER Json
When specified, returns the result as a compressed JSON object instead of plain text output.
The target script must support a -Json parameter to return structured data.

.EXAMPLE
.\invoke-memory-tools.ps1 -ScriptName 'add-task' -Arguments '-Type', 'coding', '-Priority', 'p1', '-Objective', 'Test task'

.EXAMPLE
.\invoke-memory-tools.ps1 -ScriptName 'health-check' -Json

.EXAMPLE
.\invoke-memory-tools.ps1 -ScriptName 'batch-memory' -Arguments '-Action', 'list'

.NOTES
The target script must exist in the same directory as this wrapper.
All arguments after -ScriptName are forwarded to the target script.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true, Position=0)]
    [string]$ScriptName,

    [Parameter(ValueFromRemainingArguments=$true)]
    [string[]]$Arguments,

    [switch]$Json
)

$ProgressPreference = 'SilentlyContinue'

$scriptsPath = $PSScriptRoot
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

    # Check if this is a switch parameter (starts with -)
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

# Add -Json parameter to forwarded arguments if specified
if ($Json) {
    $paramHash['Json'] = $true
}

# Dot-source the target script with splatted parameters
. $scriptPath @paramHash