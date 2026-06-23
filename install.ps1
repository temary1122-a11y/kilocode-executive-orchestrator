<#
.SYNOPSIS
Installer for Executive Orchestrator (Early Beta).
.DESCRIPTION
Creates required project runtime directories and global Kilo memory directories.
Supports local install (default) and optional copy mode.
.PARAMETER SourcePath
Path to source .kilocode tree. Defaults to script directory.
.PARAMETER TargetPath
Target project root. Defaults to SourcePath (local mode).
.PARAMETER DryRun
Show actions without writing.
.PARAMETER Force
Overwrite existing target .kilocode in copy mode.
.PARAMETER SkipGlobal
Skip creation of ~/.kilocode/global/... directories.
#>
[CmdletBinding()]
param(
    [string]$SourcePath = "",
    [string]$TargetPath = "",
    [switch]$DryRun,
    [switch]$Force,
    [switch]$SkipGlobal
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'SilentlyContinue'

function Write-Status {
    param([string]$Label, [string]$Message)
    switch ($Label) {
        'OK' { Write-Host "[OK] $Message" -ForegroundColor Green }
        'WARN' { Write-Host "[WARN] $Message" -ForegroundColor Yellow }
        'ERROR' { Write-Host "[ERROR] $Message" -ForegroundColor Red }
        'DRYRUN' { Write-Host "[DRYRUN] $Message" -ForegroundColor Cyan }
        default { Write-Host "[INFO] $Message" -ForegroundColor Gray }
    }
}

function Ensure-Directory {
    param([string]$Path, [string]$Context = "")
    if (-not (Test-Path -LiteralPath $Path)) {
        if ($DryRun) {
            Write-Status 'DRYRUN' "Would create directory: $Path"
            return $true
        }
        try {
            New-Item -ItemType Directory -Path $Path -Force | Out-Null
            Write-Status 'OK' "Created directory: $Path"
            return $true
        } catch {
            Write-Status 'ERROR' "Failed to create directory $Path : $($_.Exception.Message)"
            return $false
        }
    } else {
        Write-Status 'OK' "Directory exists: $Path"
        return $true
    }
}

function Test-FileExists {
    param([string]$Path, [string]$Context = "")
    if (Test-Path -LiteralPath $Path) {
        Write-Status 'OK' "Found: $Path"
        return $true
    } else {
        Write-Status 'ERROR' "Missing required file: $Path"
        return $false
    }
}

# Resolve source path
if (-not $SourcePath) {
    $SourcePath = Split-Path -Parent $MyInvocation.MyCommand.Path
}
if (-not $SourcePath) {
    $SourcePath = (Get-Location).Path
}
$SourcePath = (Resolve-Path $SourcePath).Path

# Resolve target path
if (-not $TargetPath) {
    $TargetPath = $SourcePath
}
$TargetPath = (Resolve-Path $TargetPath).Path

$sourceKilo = Join-Path $SourcePath '.kilocode'
$targetKilo = Join-Path $TargetPath '.kilocode'

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host " Executive Orchestrator Installer (Beta) " -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Source : $SourcePath"
Write-Host "Target : $TargetPath"
Write-Host "DryRun : $DryRun"
Write-Host ""

# Validate source .kilocode exists
if (-not (Test-Path -LiteralPath $sourceKilo)) {
    Write-Status 'ERROR' "Source .kilocode directory not found at: $sourceKilo"
    Write-Host "Installation aborted." -ForegroundColor Red
    exit 1
}

# Copy mode safety
if ($SourcePath -ne $TargetPath) {
    if (-not $Force -and (Test-Path -LiteralPath $targetKilo)) {
        Write-Status 'ERROR' "Target .kilocode already exists at: $targetKilo"
        Write-Host "Use -Force to overwrite, or remove the directory first." -ForegroundColor Yellow
        Write-Host "Installation aborted." -ForegroundColor Red
        exit 1
    }
    if ($Force -and (Test-Path -LiteralPath $targetKilo)) {
        if (-not $DryRun) {
            Write-Status 'WARN' "Removing existing target .kilocode: $targetKilo"
            Remove-Item -LiteralPath $targetKilo -Recurse -Force
        } else {
            Write-Status 'DRYRUN' "Would remove existing target .kilocode: $targetKilo"
        }
    }
}

# Copy .kilocode if needed
if ($SourcePath -ne $TargetPath) {
    if (-not $DryRun) {
        try {
            if (-not (Test-Path -LiteralPath $targetKilo)) {
                New-Item -ItemType Directory -Path $targetKilo -Force | Out-Null
            }
            # Copy everything except runtime-generated heavy files
            $excludeDirs = @('memory/bus', 'memory/delegation', 'node_modules')
            $items = Get-ChildItem -LiteralPath $sourceKilo -Force
            foreach ($item in $items) {
                $relPath = $item.FullName.Substring($sourceKilo.Length + 1)
                $destPath = Join-Path $targetKilo $relPath
                if ($item.PSIsContainer) {
                    $dirName = $item.Name
                    if ($excludeDirs -contains $relPath) {
                        Write-Status 'WARN' "Skipping runtime directory: $relPath"
                        continue
                    }
                    if (-not (Test-Path -LiteralPath $destPath)) {
                        New-Item -ItemType Directory -Path $destPath -Force | Out-Null
                    }
                    Get-ChildItem -LiteralPath $item.FullName -Force | ForEach-Object {
                        $childRel = $_.FullName.Substring($sourceKilo.Length + 1)
                        $childDest = Join-Path $targetKilo $childRel
                        if ($_.PSIsContainer) {
                            if (-not (Test-Path -LiteralPath $childDest)) {
                                New-Item -ItemType Directory -Path $childDest -Force | Out-Null
                            }
                            Copy-Item -LiteralPath $_.FullName -Destination $childDest -Recurse -Force
                        } else {
                            Copy-Item -LiteralPath $_.FullName -Destination $childDest -Force
                        }
                    }
                } else {
                    Copy-Item -LiteralPath $item.FullName -Destination $destPath -Force
                }
            }
            Write-Status 'OK' "Copied .kilocode from $sourceKilo to $targetKilo"
        } catch {
            Write-Status 'ERROR' "Copy failed: $($_.Exception.Message)"
            Write-Host "Installation aborted." -ForegroundColor Red
            exit 1
        }
    } else {
        Write-Status 'DRYRUN' "Would copy .kilocode from $sourceKilo to $targetKilo"
    }
}

# Ensure runtime directories in target
Write-Host ""
Write-Host "Ensuring runtime directories in target..." -ForegroundColor Gray
$runtimeDirs = @(
    'memory',
    'memory/bus',
    'memory/delegation/pending',
    'memory/execution-traces',
    'memory/context-enrichment',
    'memory/research-reports',
    'tools/memory-tools/scripts'
)
foreach ($rel in $runtimeDirs) {
    $full = Join-Path $targetKilo $rel
    Ensure-Directory -Path $full -Context "runtime"
}

# Verify key files
Write-Host ""
Write-Host "Verifying key files..." -ForegroundColor Gray
$keyFiles = @(
    'modes/executive-orchestrator.md',
    'tools/memory-tools/scripts/common.ps1',
    'tools/memory-tools/scripts/phase-runner.ps1',
    'tools/memory-tools/scripts/parallel-runner.ps1',
    'delegation/kilo-sdk-delegate.js',
    'README.md'
)
$allFilesOk = $true
foreach ($rel in $keyFiles) {
    $full = Join-Path $targetKilo $rel
    if (-not (Test-FileExists -Path $full -Context "keyfile")) {
        $allFilesOk = $false
    }
}

# Global directories
if (-not $SkipGlobal) {
    Write-Host ""
    Write-Host "Ensuring global Kilo directories..." -ForegroundColor Gray
    $globalBase = Join-Path $env:USERPROFILE '.kilocode' 'global'
    $globalDirs = @(
        (Join-Path $globalBase 'self-healing'),
        (Join-Path $globalBase 'user')
    )
    foreach ($d in $globalDirs) {
        Ensure-Directory -Path $d -Context "global"
    }
} else {
    Write-Host ""
    Write-Status 'WARN' "Skipping global directory creation (-SkipGlobal)"
}

# Environment checks
Write-Host ""
Write-Host "Environment checks:" -ForegroundColor Gray

# PowerShell version
$psVersion = $PSVersionTable.PSVersion.Major
if ($psVersion -ge 5) {
    Write-Status 'OK' "PowerShell version: $($PSVersionTable.PSVersion)"
} else {
    Write-Status 'WARN' "PowerShell version $psVersion detected; PowerShell 5+ recommended."
}

# Git
$gitCmd = Get-Command git -ErrorAction SilentlyContinue
if ($gitCmd) {
    $gitVersion = & git --version
    Write-Status 'OK' "Git found: $gitVersion"
} else {
    Write-Status 'WARN' "Git not found. Initialize a git repo in your project for best experience."
}

# Node.js
$nodeCmd = Get-Command node -ErrorAction SilentlyContinue
if ($nodeCmd) {
    $nodeVersion = & node --version
    Write-Status 'OK' "Node.js found: $nodeVersion (fallback stub supported)"
} else {
    Write-Status 'WARN' "Node.js not found. Fallback delegation stub requires Node.js; without it, pending manifests will be created directly."
}

# agent_manager
$agentMgr = Get-Command agent_manager -ErrorAction SilentlyContinue
if ($agentMgr) {
    Write-Status 'OK' "agent_manager found: $($agentMgr.Source)"
} else {
    Write-Status 'WARN' "agent_manager not found. Delegation will use fallback/pending manifest path."
}

# Execution policy
$currentPolicy = Get-ExecutionPolicy -List | ForEach-Object {
    [pscustomobject]@{
        Scope = $_.Scope
        Policy = $_.ExecutionPolicy
    }
}
$effectivePolicy = Get-ExecutionPolicy
if ($effectivePolicy -eq 'Restricted') {
    Write-Status 'WARN' "PowerShell execution policy is Restricted. Scripts may be blocked."
    Write-Host "  To allow local scripts, run as Administrator:" -ForegroundColor Yellow
    Write-Host "    Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned -Force" -ForegroundColor Yellow
} else {
    Write-Status 'OK' "PowerShell execution policy: $effectivePolicy"
}

# Summary
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
if ($allFilesOk -and (-not $DryRun)) {
    Write-Status 'OK' "Installation completed."
} elseif ($allFilesOk -and $DryRun) {
    Write-Status 'DRYRUN' "Dry-run completed. No changes were made."
} else {
    Write-Status 'ERROR' "Installation finished with missing key files. Review the errors above."
}

Write-Host ""
Write-Host "Next steps:" -ForegroundColor Cyan
Write-Host "1. Open this workspace in Kilo Code."
Write-Host "2. Select/activate Executive Orchestrator mode."
Write-Host "3. Run a medium task and inspect:"
Write-Host "   - .kilocode/memory/bus/events.jsonl"
Write-Host "   - .kilocode/memory/delegation/pending/"
Write-Host ""

if ($DryRun) {
    Write-Host "Note: Dry-run mode was active. Re-run without -DryRun to apply changes." -ForegroundColor Yellow
}

exit 0
