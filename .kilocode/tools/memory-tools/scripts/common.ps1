# Canonical version. Source of truth for all memory paths.
<#
.SYNOPSIS
Common utilities for memory-tools.
.DESCRIPTION
Provides shared paths (both project-level and global), configuration loading, logging, JSONL helpers, event publishing, state updates, and execution traces.
#>

# Resolve base path relative to this script (project-level .kilocode)
function Resolve-KiloBasePath {
    $dir = $PSScriptRoot
    while ($dir) {
        if ((Split-Path -Leaf $dir) -eq '.kilocode') {
            return (Resolve-Path $dir).Path
        }
        $parent = Split-Path -Parent $dir
        if (-not $parent -or $parent -eq $dir) { break }
        $dir = $parent
    }
    return (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
}

$script:BasePath = Resolve-KiloBasePath

# ============================================================================
# PROJECT-LEVEL PATHS (.kilocode/memory/)
# ============================================================================
$script:MemoryPath = Join-Path $script:BasePath 'memory'
$script:TasksPath = Join-Path $script:MemoryPath 'tasks.jsonl'
$script:StatePath = Join-Path $script:MemoryPath 'state.json'
$script:DecisionsMdPath = Join-Path $script:MemoryPath 'decisions.md'
$script:DecisionsJsonlPath = Join-Path $script:MemoryPath 'decisions.jsonl'
$script:BusPath = Join-Path $script:MemoryPath 'bus'
$script:CheckpointsPath = Join-Path $script:MemoryPath 'checkpoints'
$script:ContextEnrichmentPath = Join-Path $script:MemoryPath 'context-enrichment'
$script:ResearchReportsPath = Join-Path $script:MemoryPath 'research-reports'
$script:UserProfilePath = Join-Path $script:MemoryPath 'user-profile.jsonl'
$script:ExecutionTracesPath = Join-Path $script:MemoryPath 'execution-traces'

# ============================================================================
# GLOBAL PATHS (~/.kilocode/global/)
# ============================================================================
$script:GlobalBasePath = Join-Path $env:USERPROFILE '.kilocode\global'
$script:GlobalSelfHealingPath = Join-Path $script:GlobalBasePath 'self-healing'
$script:GlobalUserProfilePath = Join-Path $script:GlobalBasePath 'user\user-profile.jsonl'
$script:GlobalAgentErrorsPath = Join-Path $script:GlobalSelfHealingPath 'agent-errors.jsonl'
$script:GlobalErrorPatternsPath = Join-Path $script:GlobalSelfHealingPath 'error-patterns.md'
$script:GlobalSelfHealRulesPath = Join-Path $script:GlobalSelfHealingPath 'self-heal-rules.md'

function Get-GlobalSelfHealingPath { return $script:GlobalSelfHealingPath }
function Get-GlobalErrorLogPath { return $script:GlobalAgentErrorsPath }
function Get-GlobalErrorPatternsPath { return $script:GlobalErrorPatternsPath }
function Get-GlobalUserProfilePath { return $script:GlobalUserProfilePath }
function Get-GlobalSelfHealRulesPath { return $script:GlobalSelfHealRulesPath }

function Get-BasePath { return $script:BasePath }
function Get-MemoryPath { return $script:MemoryPath }
function Get-TasksPath { return $script:TasksPath }
function Get-StatePath { return $script:StatePath }
function Get-DecisionsPath { return $script:DecisionsMdPath }
function Get-DecisionsMdPath { return $script:DecisionsMdPath }
function Get-DecisionsJsonlPath { return $script:DecisionsJsonlPath }
function Get-BusPath { return $script:BusPath }
function Get-CheckpointsPath { return $script:CheckpointsPath }
function Get-ContextEnrichmentPath { return $script:ContextEnrichmentPath }
function Get-ResearchReportsPath { return $script:ResearchReportsPath }
function Get-UserProfilePath { return $script:UserProfilePath }
function Get-ExecutionTracesPath { return $script:ExecutionTracesPath }

function Test-QuietMode {
    param([switch]$Quiet)
    return ($Quiet -or $env:KILO_QUIET -eq '1' -or $env:KILO_QUIET -eq 'true')
}

function Write-QuietAwareHost {
    param(
        [string]$Message,
        [switch]$Quiet,
        [string]$ForegroundColor = 'Gray'
    )
    if (-not (Test-QuietMode -Quiet:$Quiet)) {
        Write-Host $Message -ForegroundColor $ForegroundColor
    }
}

function Write-JsonResult {
    param(
        [object]$Data,
        [int]$Depth = 20
    )
    $Data | ConvertTo-Json -Compress -Depth $Depth
}

function Ensure-MemoryDirectories {
    foreach ($path in @(
        $script:MemoryPath,
        $script:CheckpointsPath,
        $script:ContextEnrichmentPath,
        $script:ResearchReportsPath,
        $script:ExecutionTracesPath,
        $script:GlobalSelfHealingPath
    )) {
        if (-not (Test-Path $path)) {
            New-Item -ItemType Directory -Path $path -Force | Out-Null
        }
    }
}

function New-TraceCorrelationId {
    param(
        [string]$TaskId = '',
        [string]$RunId = ''
    )
    if ($TaskId -and $RunId) { return "$TaskId::$RunId" }
    if ($TaskId) { return $TaskId }
    if ($RunId) { return $RunId }
    return ([guid]::NewGuid().ToString('N'))
}

# ============================================================================
# ENHANCED EXECUTION TRACING - Improved observability with replay support
# ============================================================================

# Enhanced trace function with structured events and failure mode tracking
function Write-ExecutionTrace {
    param(
        [Parameter(Mandatory=$true)][string]$TaskId,
        [Parameter(Mandatory=$true)][string]$Phase,
        [Parameter(Mandatory=$true)][string]$Status,
        [hashtable]$Data = @{},
        [string]$RunId = '',
        [string]$CorrelationId = '',
        [string]$Event = 'phase',
        [string]$Actor = '',
        [string]$FailureMode = '',
        [string]$FailureSubMode = '',
        [hashtable]$Metadata = @{}
    )

    if ($env:KILO_TRACE_WRITE -eq '0') { return $null }
    Ensure-MemoryDirectories
    $resolvedRunId = if ($RunId) { $RunId } elseif ($env:KILO_RUN_ID) { $env:KILO_RUN_ID } else { '' }
    $resolvedCorrelationId = if ($CorrelationId) { $CorrelationId } elseif ($env:KILO_CORRELATION_ID) { $env:KILO_CORRELATION_ID } else { New-TraceCorrelationId -TaskId $TaskId -RunId $resolvedRunId }
    $resolvedActor = if ($Actor) { $Actor } elseif ($env:KILO_TRACE_ACTOR) { $env:KILO_TRACE_ACTOR } else { '' }

    # Enhanced trace with structured failure mode and metadata
    $trace = [ordered]@{
        trace_id = ([guid]::NewGuid().ToString('N'))
        task_id = $TaskId
        phase = $Phase
        status = $Status
        event = $Event
        actor = $resolvedActor
        run_id = $resolvedRunId
        correlation_id = $resolvedCorrelationId
        
        # Enhanced failure tracking
        failure_mode = $FailureMode
        failure_submode = $FailureSubMode
        failure_severity = if ($FailureMode -and $FailureMode -in @('circuit_breaker', 'policy_denied', 'max_retries_exceeded')) { 'high' } elseif ($FailureMode) { 'medium' } else { 'low' }
        
        # Enhanced metadata for better observability
        metadata = [ordered]@{
            timestamp_utc = (Get-Date).ToString('o')
            timestamp_local = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')
            actor_type = 'orchestrator'
            event_version = '2.0'
            trace_version = 'enhanced_v2'
        }

        constraints = $Data['constraints']
        success_criteria = $Data['success_criteria']
        stop_conditions = $Data['stop_conditions']
        context_packet = $Data['context_packet']
        research_report = $Data['research_report']
        handoff_contract = $Data['handoff_contract']

        delegation_attempted = if ($Event -eq 'delegation.policy_denied' -or $Event -eq 'delegation') { $true } else { $false }
        policy_checked = if ($Event -eq 'delegation.policy_denied' -or $Event -eq 'delegation') { $true } else { $false }

        subagent_invoked = if ($Event -eq 'delegation.succeeded' -or $Event -eq 'delegation.failed') { $true } else { $false }

        status_category = switch ($Status) {
            { $_ -in @('failed', 'blocked', 'policy_denied') } { 'error'; break }
            { $_ -in @('warn', 'partial') } { 'warning'; break }
            { $_ -in @('timeout', 'stalled') } { 'critical'; break }
            default { 'normal' }
        }

        dry_run = if ($env:KILO_TRACE_WRITE -eq '0') { $true } else { $false }
        parallel = if ($env:KILO_PARALLEL_ENABLED) { $true } else { $false }
        
        timestamp = (Get-Date).ToString('o')
        data = $Data
    }

    $tracePath = Join-Path $script:ExecutionTracesPath ("trace_{0}.jsonl" -f $TaskId)
    ($trace | ConvertTo-Json -Compress -Depth 30) | Add-Content -LiteralPath $tracePath -Encoding UTF8
    return $tracePath
}

# Enhanced trace retrieval with filtering and analysis
function Get-ExecutionTrace {
    param(
        [Parameter(Mandatory=$true)][string]$TaskId,
        [string]$RunId = '',
        [string]$Phase = '',
        [string]$Status = '',
        [string]$Event = '',
        [string]$FailureMode = '',
        [switch]$IncludeMetadata,
        [switch]$ReplayMode
    )

    $tracePath = Join-Path $script:ExecutionTracesPath ("trace_{0}.jsonl" -f $TaskId)
    if (-not (Test-Path $tracePath)) { return @() }
    
    $allTraces = @(Read-JsonlSafe -Path $tracePath)
    $filteredTraces = @()

    foreach ($trace in $allTraces) {
        $include = $true

        if ($RunId -and $trace.run_id -ne $RunId) { $include = $false }
        if ($Phase -and $trace.phase -ne $Phase) { $include = $false }
        if ($Status -and $trace.status -ne $Status) { $include = $false }
        if ($Event -and $trace.event -ne $Event) { $include = $false }
        if ($FailureMode -and $trace.failure_mode -ne $FailureMode) { $include = $false }

        if ($include) {
            if ($ReplayMode) {
                # Enhance trace for replay mode
                $trace.metadata['replay_enabled'] = $true
                $trace.metadata['replay_timestamp'] = (Get-Date).ToString('o')
                if ($IncludeMetadata) { $filteredTraces += $trace } else { $filteredTraces += @{ task_id = $trace.task_id; phase = $trace.phase; status = $trace.status; event = $trace.event; run_id = $trace.run_id; correlation_id = $trace.correlation_id } }
            } else {
                if ($IncludeMetadata) { $filteredTraces += $trace } else { $filteredTraces += @{ task_id = $trace.task_id; phase = $trace.phase; status = $trace.status; event = $trace.event; run_id = $trace.run_id; correlation_id = $trace.correlation_id } }
            }
        }
    }

    return $filteredTraces
}

# Replay mechanism for trace analysis
function Start-TraceReplay {
    param(
        [Parameter(Mandatory=$true)][string]$TaskId,
        [string]$RunId = '',
        [string]$FromEvent = '',
        [string]$ToEvent = '',
        [string]$FailureMode = '',
        [switch]$ReplayToLive,
        [string]$OutputPath = '',
        [switch]$Verbose
    )

    Write-Log "Starting trace replay for Task: $TaskId" -Level INFO -Component 'trace-replay'

    $replaySessionId = "replay_$(Get-Date -Format yyyyMMddHHmmss)_$([guid]::NewGuid().ToString('N').Substring(0,8))"
    $replayTimestamp = (Get-Date).ToString('o')

    $traces = Get-ExecutionTrace -TaskId $TaskId -RunId $RunId -FromEvent $FromEvent -ToEvent $ToEvent -FailureMode $FailureMode -IncludeMetadata -ReplayMode

    if ($traces.Count -eq 0) {
        Write-Log "No traces found for replay for Task: $TaskId" -Level WARN -Component 'trace-replay'
        return $null
    }

    # Analyze trace patterns
    $traceAnalysis = Analyze-TraceData -Traces $traces -Verbose:$Verbose

    # Generate replay report
    $replayReport = [ordered]@{
        replay_session_id = $replaySessionId
        task_id = $TaskId
        replay_started = $replayTimestamp
        run_id = if ($RunId) { $RunId } else { $traces[0].run_id }
        correlation_id = $traces[0].correlation_id
        trace_count = $traces.Count
        analysis = $traceAnalysis
        traces = $traces
        replay_options = @{ replay_to_live = $ReplayToLive; output_path = $OutputPath; verbose = $Verbose }
        enhanced_observability = @{ version = '2.0'; features = @('structured_events', 'failure_tracking', 'metadata_enhancement') }
    }

    if ($OutputPath) {
        $outputDir = Split-Path $OutputPath -Parent
        if (-not (Test-Path $outputDir)) { New-Item -ItemType Directory -Path $outputDir -Force | Out-Null }
        $replayReport | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
        Write-Log "Replay report saved to: $OutputPath" -Level INFO -Component 'trace-replay'
    }

    # Execute replay if requested
    if ($ReplayToLive) {
        Write-Log "Executing replay to live execution (simulation mode)" -Level INFO -Component 'trace-replay'
        # Simulate actions from traces for analysis
    }

    Write-Log "Trace replay completed. Session: $replaySessionId. Analyzed $($traces.Count) trace events." -Level INFO -Component 'trace-replay'
    return $replayReport
}

# Trace data analysis function
function Analyze-TraceData {
    param(
        [Parameter(Mandatory=$true)][array]$Traces,
        [switch]$Verbose
    )

    $analysis = [ordered]@{} 
    $analysis['summary'] = [ordered]@{} 
    $analysis['timeline'] = @() 
    $analysis['failure_patterns'] = @{}
    $analysis['performance_metrics'] = @{}
    $analysis['actor_behavior'] = @{}

    # Basic statistics
    $analysis['summary']['total_events'] = $Traces.Count
    $analysis['summary']['unique_phases'] = @($Traces | ForEach-Object { $_.phase } | Select-Object -Unique).Count
    $analysis['summary']['unique_actors'] = @($Traces | ForEach-Object { $_.actor } | Where-Object { $_ } | Select-Object -Unique).Count

    # Status distribution
    $statusCounts = @{}
    foreach ($trace in $Traces) {
        if (-not $statusCounts.ContainsKey($trace.status)) { $statusCounts[$trace.status] = 0 }
        $statusCounts[$trace.status]++
    }
    $analysis['summary']['status_distribution'] = $statusCounts

    # Failure mode analysis
    $failureModes = @($Traces | Where-Object { $_.failure_mode } | ForEach-Object { $_.failure_mode } | Select-Object -Unique)
    if ($failureModes.Count -gt 0) {
        $analysis['failure_patterns']['detected_modes'] = $failureModes
        $analysis['failure_patterns']['total_failures'] = @($Traces | Where-Object { $_.failure_mode }).Count

        foreach ($mode in $failureModes) {
            $modeCount = @($Traces | Where-Object { $_.failure_mode -eq $mode }).Count
            $analysis['failure_patterns']['by_mode'][$mode] = $modeCount

            if ($Verbose) {
                $analysis['failure_patterns']['details'][$mode] = @(
                    $Traces | Where-Object { $_.failure_mode -eq $mode }
                    $_ | ForEach-Object {
                        [ordered]@{ 
                            trace_id = $_.trace_id
                            task_id = $_.task_id
                            phase = $_.phase
                            status = $_.status
                            timestamp = $_.timestamp
                            correlation_id = $_.correlation_id
                        }
                    }
                )
            }
        }
    }

    # Timeline construction
    foreach ($trace in @($Traces | Sort-Object { $_.timestamp })) {
        $timelineEntry = [ordered]@{} 
        $timelineEntry['timestamp'] = $trace.timestamp
        $timelineEntry['trace_id'] = $trace.trace_id
        $timelineEntry['phase'] = $trace.phase
        $timelineEntry['event'] = $trace.event
        $timelineEntry['status'] = $trace.status
        $timelineEntry['actor'] = $trace.actor

        if ($trace.failure_mode) {
            $timelineEntry['failure'] = [ordered]@{ mode = $trace.failure_mode; severity = $trace.failure_severity }
        }

        $timelineEntry['run_id'] = $trace.run_id
        $timelineEntry['correlation_id'] = $trace.correlation_id
        $analysis['timeline'] += $timelineEntry
    }

    # Performance metrics
    $analysis['performance_metrics']['events_per_minute'] = [Math]::Round($Traces.Count / ((Get-Date) - [DateTime]::Parse($Traces[0].timestamp)).TotalMinutes, 2)
    $analysis['performance_metrics']['trace_density'] = if ($Traces[0].correlation_id) { 'high' } else { 'low' }

    # Actor behavior patterns
    foreach ($actor in @($Traces | Where-Object { $_.actor } | ForEach-Object { $_.actor } | Select-Object -Unique)) {
        $actorTraces = @($Traces | Where-Object { $_.actor -eq $actor })
        $analysis['actor_behavior'][$actor] = [ordered]@{} 
        $analysis['actor_behavior'][$actor]['event_count'] = $actorTraces.Count
        $analysis['actor_behavior'][$actor]['avg_severity'] = [Math]::Round((@($actorTraces | Where-Object { $_.failure_severity } | ForEach-Object { if ($_.failure_severity -eq 'high') { 3 } elseif ($_.failure_severity -eq 'medium') { 2 } else { 1 } } | Measure-Object -Average).Average, 2))
    }

    return $analysis
}

# Enhanced execution trace with replay capabilities
function Write-DetailedExecutionTrace {
    param(
        [Parameter(Mandatory=$true)][string]$TaskId,
        [Parameter(Mandatory=$true)][string]$Phase,
        [Parameter(Mandatory=$true)][string]$Status,
        [hashtable]$Data = @{},
        [string]$RunId = '',
        [string]$CorrelationId = '',
        [string]$Event = 'phase',
        [string]$Actor = '',
        [string]$FailureMode = '',
        [string]$FailureSubMode = '',
        [hashtable]$Metadata = @{},
        [switch]$EnableReplay
    )

    $traceEvent = Write-ExecutionTrace -TaskId $TaskId -Phase $Phase -Status $Status -Data $Data -RunId $RunId -CorrelationId $CorrelationId -Event $Event -Actor $Actor -FailureMode $FailureMode -FailureSubMode $FailureSubMode -Metadata $Metadata

    # Auto-replay trigger for critical events
    if ($EnableReplay -and ($Status -in @('failed', 'policy_denied', 'max_retries_exceeded'))) {
        Write-Log "Critical event triggered auto-replay: $Status. Failure mode: $FailureMode" -Level WARN -Component 'trace-replay'
        # Trigger replay for analysis
        Start-TraceReplay -TaskId $TaskId -RunId $RunId -FailureMode $FailureMode -Verbose
    }

    return $traceEvent
}

# Legacy compatibility function (maintains existing API)
function Write-ExecutionTraceLegacy {
    param(
        [Parameter(Mandatory=$true)][string]$TaskId,
        [Parameter(Mandatory=$true)][string]$Phase,
        [Parameter(Mandatory=$true)][string]$Status,
        [hashtable]$Data = @{},
        [string]$RunId = '',
        [string]$CorrelationId = '',
        [string]$Event = 'phase',
        [string]$Actor = '',
        [string]$FailureMode = ''
    )

    # Delegate to enhanced version with default parameters
    return Write-ExecutionTrace -TaskId $TaskId -Phase $Phase -Status $Status -Data $Data -RunId $RunId -CorrelationId $CorrelationId -Event $Event -Actor $Actor -FailureMode $FailureMode -FailureSubMode '' -Metadata @{}
}

# Enhanced trace export/import for interoperability
function Export-TraceSet {
    param(
        [Parameter(Mandatory=$true)][string]$TaskId,
        [string]$RunId = '',
        [string]$OutputPath,
        [string]$Format = 'json',
        [switch]$IncludeMetadata,
        [switch]$Compress
    )

    $traces = Get-ExecutionTrace -TaskId $TaskId -RunId $RunId -IncludeMetadata:$IncludeMetadata

    $exportPackage = [ordered]@{} 
    $exportPackage['trace_export_metadata'] = [ordered]@{} 
    $exportPackage['trace_export_metadata']['task_id'] = $TaskId
    $exportPackage['trace_export_metadata']['export_timestamp'] = (Get-Date).ToString('o')
    $exportPackage['trace_export_metadata']['export_format'] = $Format
    $exportPackage['trace_export_metadata']['trace_count'] = $traces.Count
    $exportPackage['trace_export_metadata']['version'] = 'enhanced_v2.0'

    $exportPackage['traces'] = $traces

    $exportPackage['analysis'] = Analyze-TraceData -Traces $traces

    $outputDir = Split-Path $OutputPath -Parent
    if (-not (Test-Path $outputDir)) { New-Item -ItemType Directory -Path $outputDir -Force | Out-Null }

    switch ($Format.ToLower()) {
        'json' {
            $exportPackage | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
        }
        'csv' {
            # Convert to CSV format for analysis tools
            $csvData = $traces | ForEach-Object {
                [ordered]@{ 
                    TraceID = $_.trace_id
                    TaskID = $_.task_id
                    Phase = $_.phase
                    Event = $_.event
                    Status = $_.status
                    Actor = $_.actor
                    RunID = $_.run_id
                    CorrelationID = $_.correlation_id
                    FailureMode = $_.failure_mode
                    Timestamp = $_.timestamp
                    Severity = if ($_.failure_severity) { $_.failure_severity } else { 'normal' }
                }
            }
            $csvData | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
        }
        default { throw "Unsupported export format: $Format" }
    }

    Write-Log "Trace set exported to: $OutputPath ($($traces.Count) events)" -Level INFO -Component 'trace-export'
    return $OutputPath
}

# Trace validation and quality checks
function Test-TraceQuality {
    param(
        [Parameter(Mandatory=$true)][string]$TaskId,
        [string]$RunId = '',
        [int]$MinTraceCount = 1,
        [switch]$CheckCompleteness
    )

    $traces = Get-ExecutionTrace -TaskId $TaskId -RunId $RunId

    $qualityReport = [ordered]@{} 
    $qualityReport['task_id'] = $TaskId
    $qualityReport['total_traces'] = $traces.Count
    $qualityReport['passed'] = $true
    $qualityReport['issues'] = @()
    $qualityReport['recommendations'] = @()

    if ($traces.Count -lt $MinTraceCount) {
        $qualityReport.passed = $false
        $qualityReport.issues += "Insufficient trace data: $($traces.Count) < $MinTraceCount"
    }

    if ($CheckCompleteness) {
        $phasesPresent = @($traces | ForEach-Object { $_.phase } | Select-Object -Unique)
        if ($phasesPresent.Count -lt 4) {  # Expecting most phases
            $qualityReport.issues += "Limited phase coverage: $($phasesPresent -join ', ')"
        }

        $actorCoverage = @($traces | Where-Object { $_.actor } | ForEach-Object { $_.actor } | Select-Object -Unique)
        if ($actorCoverage.Count -eq 1 -and $actorCoverage[0] -eq '') {
            $qualityReport.recommendations += 'Consider adding actor attribution for better observability'
        }
    }

    if ($qualityReport.issues.Count -gt 0) {
        Write-Log "Trace quality issues detected for Task: $TaskId" -Level WARN -Component 'trace-quality'
        foreach ($issue in $qualityReport.issues) {
            Write-Log "  - $issue" -Level WARN -Component 'trace-quality'
        }
    } else {
        Write-Log "Trace quality check passed for Task: $TaskId ( $($traces.Count) events)" -Level INFO -Component 'trace-quality'
    }

    return $qualityReport
}

# Read JSONL file into array of objects
function Read-Jsonl {
    param([Parameter(Mandatory=$true)][string]$Path)
    if (-not (Test-Path $Path)) { return @() }
    $content = Get-Content $Path -Raw -ErrorAction SilentlyContinue
    if (-not $content) { return @() }
    $result = @()
    $lines = $content -split "`n"
    foreach ($line in $lines) {
        if (-not $line -or -not $line.Trim()) { continue }
        try {
            $result += $line.Trim() | ConvertFrom-Json
        } catch {
            Write-Log "Skipping invalid JSONL line in $Path : $_" -Level 'WARN' -Component 'jsonl'
        }
    }
    return $result
}

# Write objects to JSONL file as one compact JSON object per line.
function Write-Jsonl {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][array]$Objects
    )
    $dir = Split-Path $Path -Parent
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $tempPath = "$Path.tmp"
    try {
        $Objects | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 20 } | Set-Content -Path $tempPath -Encoding UTF8
        Move-Item -Path $tempPath -Destination $Path -Force
    } catch {
        Remove-Item -Path $tempPath -Force -ErrorAction SilentlyContinue
        throw
    }
}

function Read-JsonlSafe {
    param([Parameter(Mandatory=$true)][string]$Path)
    if (-not (Test-Path $Path)) { return @() }
    $items = @()
    foreach ($line in (Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue | Where-Object { $_ -and $_.Trim() })) {
        try {
            $items += $line.Trim() | ConvertFrom-Json
        } catch {
            Write-Log "Skipping invalid JSONL line in $Path : $_" -Level 'WARN' -Component 'jsonl'
        }
    }
    return ,@($items)
}

# ============================================================================
# FILE LOCK INTEGRATION - for parallel execution safety
# ============================================================================
$script:FileLockScript = Join-Path $PSScriptRoot 'file-lock.ps1'
if (Test-Path $script:FileLockScript) {
    . $script:FileLockScript
}

# Safe append with lock - prevents race conditions when multiple agents append
function Safe-AppendToFile {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$Content,
        [int]$MaxRetries = 5
    )
    $lockPath = Get-LockFilePath -Path $Path
    $result = Lock-WithRetry -Path $lockPath -MaxRetries $MaxRetries
    if (-not $result.acquired) {
        throw "Failed to acquire lock for append on $Path after $MaxRetries attempts"
    }
    try {
        Add-Content -LiteralPath $Path -Value $Content -Encoding UTF8
    } finally {
        Release-FileLock -Path $lockPath | Out-Null
    }
}

# Atomic JSONL append - reads existing, appends new record with lock
function Lock-AndAppendJsonl {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][object]$Object,
        [switch]$ValidateBeforeWrite
    )
    $lockPath = Get-LockFilePath -Path $Path
    $result = Lock-WithRetry -Path $lockPath -MaxRetries 5
    if (-not $result.acquired) {
        throw "Failed to acquire lock for $Path after 5 attempts"
    }
    try {
        $existing = @()
        if (Test-Path -LiteralPath $Path) {
            $existing = Read-JsonlSafe -Path $Path
        }
        $existing += $Object
        Write-Jsonl -Path $Path -Objects $existing
    } finally {
        Release-FileLock -Path $lockPath | Out-Null
    }
}

# Atomic JSONL update - reads existing, applies scriptblock, writes back with lock
function Lock-AndUpdateJsonl {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][scriptblock]$UpdateAction
    )
    $lockPath = Get-LockFilePath -Path $Path
    $result = Lock-WithRetry -Path $lockPath -MaxRetries 10 -InitialDelayMs 100 -MaxDelayMs 5000
    if (-not $result.acquired) {
        throw "Failed to acquire lock for $Path after 10 attempts"
    }
    try {
        $existing = @()
        if (Test-Path -LiteralPath $Path) {
            $existing = Read-JsonlSafe -Path $Path
        }
        $updated = &$UpdateAction $existing
        if ($null -ne $updated) {
            Write-Jsonl -Path $Path -Objects $updated
        }
        return $updated
    } finally {
        Release-FileLock -Path $lockPath | Out-Null
    }
}

# Orchestrator Bus — restored via JSONL persistence.
function Publish-Event {
    param(
        [Parameter(Mandatory=$true)][ValidateSet('task.created','task.updated','task.completed','task.graph.updated','checkpoint.created','checkpoint.restored','agent.killed','agent.paused','agent.heartbeat','agent.updated','consolidation.completed','user.profile.updated')][string]$Type,
        [hashtable]$Data = @{}
    )
    try {
        $busDir = Get-BusPath
        if (-not (Test-Path -LiteralPath $busDir)) {
            New-Item -ItemType Directory -Path $busDir -Force | Out-Null
        }
        $busFile = Join-Path $busDir 'events.jsonl'
        $event = [ordered]@{
            timestamp = (Get-Date -Format 'o')
            type      = $Type
            data      = $Data
        }
        Lock-AndAppendJsonl -Path $busFile -Object $event | Out-Null
    } catch {
        Write-Log "Failed to publish event '$Type': $($_.Exception.Message)" -Level WARN -Component 'bus'
    }
}

function Get-BusEvents {
    param(
        [string]$Path = '',
        [string[]]$Types = @()
    )
    try {
        $busFile = if ($Path) { $Path } else { (Join-Path (Get-BusPath) 'events.jsonl') }
        if (-not (Test-Path -LiteralPath $busFile)) {
            return ,@()
        }
        $events = Read-JsonlSafe -Path $busFile
        if ($Types -and $Types.Count -gt 0) {
            $events = $events | Where-Object { $_.type -in $Types }
        }
        return ,@($events)
    } catch {
        Write-Log "Failed to read bus events: $($_.Exception.Message)" -Level WARN -Component 'bus'
        return ,@()
    }
}

# Atomic state update
function Update-SystemState {
    param(
        [Parameter(Mandatory=$true)][string]$Key,
        [Parameter(Mandatory=$true)][object]$Value
    )
    $statePath = $script:StatePath

    # Ensure directory exists
    $stateDir = Split-Path $statePath
    if (-not (Test-Path $stateDir)) {
        New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
    }

    # Initialize or read existing state
    $state = [ordered]@{}
    if (Test-Path $statePath) {
        try {
            $content = Get-Content $statePath -Raw | ConvertFrom-Json
            $content.PSObject.Properties | ForEach-Object { $state[$_.Name] = $_.Value }
        } catch {
            Write-Log "Failed to read state.json, initializing fresh: $_" -Level 'WARN'
        }
    }

    $state[$Key] = $Value
    $state['last_updated'] = (Get-Date -Format 'o')

    # Atomic write
    $tempPath = "$statePath.tmp"
    $state | ConvertTo-Json -Depth 10 | Set-Content $tempPath -Encoding UTF8
    Move-Item -Path $tempPath -Destination $statePath -Force
}

function Get-LatestTaskRecord {
    $tasks = Read-JsonlSafe -Path $script:TasksPath
    if (-not $tasks -or $tasks.Count -eq 0) { return $null }
    return ($tasks | Sort-Object created_at -Descending | Select-Object -First 1)
}

function Get-CurrentTaskRecord {
    $tasks = Read-JsonlSafe -Path $script:TasksPath
    if (-not $tasks -or $tasks.Count -eq 0) { return $null }
    return ($tasks | Where-Object { $_.status -eq 'in_progress' } | Sort-Object created_at -Descending | Select-Object -First 1)
}

function Sync-SystemStateFromTasks {
    $latest = Get-LatestTaskRecord
    $current = Get-CurrentTaskRecord

    Update-SystemState -Key 'last_task_id' -Value $(if ($latest) { $latest.task_id } else { $null })
    Update-SystemState -Key 'current_task' -Value $(if ($current) { $current.task_id } else { $null })
    Update-SystemState -Key 'task_count' -Value ((Read-JsonlSafe -Path $script:TasksPath).Count)
}

# ============================================================================
# ENHANCED EXECUTION TRACING - Improved observability with replay support
# ============================================================================

# Enhanced trace function with structured events and failure mode tracking

# Enhanced trace retrieval with filtering and analysis

# Replay mechanism for trace analysis

# Trace data analysis function

# Enhanced execution trace with replay capabilities

# Legacy compatibility function (maintains existing API)

# Enhanced trace export/import for interoperability

# Trace validation and quality checks

# Legacy logging function (maintains compatibility)
function Write-Log {
    param(
        [Parameter(Mandatory=$true)][string]$Message,
        [ValidateSet('DEBUG','INFO','WARN','ERROR')][string]$Level = 'INFO',
        [string]$Component = 'memory-tools',
        [switch]$Quiet
    )
    $timestamp = Get-Date -Format 'o'
    $color = switch ($Level) {
        'DEBUG' { 'DarkGray' }
        'INFO' { 'Gray' }
        'WARN' { 'Yellow' }
        'ERROR' { 'Red' }
    }

    if (-not (Test-QuietMode -Quiet:$Quiet)) {
        Write-Host "$timestamp [$Level] [$Component] $Message" -ForegroundColor $color
    }
}

# Read JSONL file into array of objects

# Write objects to JSONL file as one compact JSON object per line.


# ============================================================================
# FILE LOCK INTEGRATION - for parallel execution safety
# ============================================================================
$script:FileLockScript = Join-Path $PSScriptRoot 'file-lock.ps1'
if (Test-Path $script:FileLockScript) {
    . $script:FileLockScript
}

# Safe append with lock - prevents race conditions when multiple agents append

# Atomic JSONL append - reads existing, appends new record with lock

# Atomic JSONL update - reads existing, applies scriptblock, writes back with lock

# Orchestrator Bus is removed in v3.0. Keep Publish-Event as a no-op
# compatibility hook so existing scripts do not fail after cleanup.


# Atomic state update




function Test-HandoffContract {
    param([Parameter(Mandatory=$true)][object]$Contract)

    $required = @(
        'task_id',
        'objective',
        'role',
        'task_type',
        'priority',
        'agent',
        'context_packet',
        'research_report',
        'constraints',
        'success_criteria',
        'stop_conditions',
        'output_format',
        'version'
    )
    $missing = @()
    foreach ($name in $required) {
        if (-not ($Contract.PSObject.Properties.Name -contains $name)) {
            $missing += $name
        } elseif ($null -eq $Contract.$name) {
            $missing += $name
        } elseif ($Contract.$name -is [string] -and [string]::IsNullOrWhiteSpace($Contract.$name)) {
            $missing += $name
        } elseif ($Contract.$name -is [array] -and @($Contract.$name).Count -eq 0) {
            $missing += $name
        }
    }

    return [pscustomobject]@{
        valid = ($missing.Count -eq 0)
        missing = $missing
    }
}

function Write-OrchestratorUiStatus {
    param(
        [string]$TaskId = '',
        [string]$RunId = '',
        [string]$Phase = '',
        [string]$ParallelGroup = '',
        [string]$HealingStatus = '',
        [string]$VerificationStatus = '',
        [string]$ResearchStatus = '',
        [bool]$TraceEnabled = $true,
        [string]$Summary = ''
    )

    $shortRunId = if ($RunId) { $RunId.Substring([Math]::Max(0, $RunId.Length - 8)) } else { 'n/a' }
    $healLabel = if ($HealingStatus) { $HealingStatus } else { 'none' }
    $verifyLabel = if ($VerificationStatus) { $VerificationStatus } else { 'pending' }

    $parts = @()
    if ($Phase) { $parts += "phase:$Phase" }
    if ($shortRunId -ne 'n/a') { $parts += "run:$shortRunId" }
    if ($TaskId) { $parts += "task:$TaskId" }
    if ($ParallelGroup) { $parts += "group:$ParallelGroup" }
    if ($healLabel -ne 'none') { $parts += "heal:$healLabel" }
    if ($verifyLabel -ne 'pending') { $parts += "verify:$verifyLabel" }

    $prefix = "[UI] EO | " + ($parts -join ' | ')
    $msg = if ($Summary) { "$prefix -> $Summary" } else { $prefix }

    # Plain string output to avoid object serialization XML noise
    Write-Host $msg -ForegroundColor Cyan
}

function Write-OrchestratorUiParallelStatus {
    param(
        [string]$Group = '',
        [string]$Summary = '',
        [string]$TasksDetail = ''
    )
    $msg = "[UI] PARALLEL | group:$Group -> $Summary"
    if ($TasksDetail) {
        $msg += " [$TasksDetail]"
    }
    Write-Host $msg -ForegroundColor DarkCyan
}




