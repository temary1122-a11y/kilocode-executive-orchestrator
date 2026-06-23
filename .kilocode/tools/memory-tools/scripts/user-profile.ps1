<#
.SYNOPSIS
User Modeling - Read and update user profile in user-profile.jsonl.
.DESCRIPTION
Stores user preferences, observed task patterns, and project context facts.
#>

param(
    [Parameter(Mandatory=$true)][ValidateSet('read', 'update', 'record-preference', 'record-task-pattern', 'record-task-completion', 'update-project-context', 'get-preference', 'suggest-model', 'get-frequent-patterns', 'suggest-approach')][string]$Action,
    [string]$Key,
    [string]$Value,
    [string]$Category,
    [string]$SubKey,
    [string]$TaskId,
    [string]$TaskType,
    [string]$Priority,
    [string]$Agent,
    [string]$Objective
)

. "$PSScriptRoot\common.ps1"
$userProfilePath = Get-UserProfilePath

function Convert-ToHashtable {
    param($InputObject)
    if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
        $ht = @{}
        $InputObject.PSObject.Properties | ForEach-Object { $ht[$_.Name] = Convert-ToHashtable $_.Value }
        return $ht
    }
    if ($InputObject -is [array]) {
        $list = @()
        $InputObject | ForEach-Object { $list += Convert-ToHashtable $_ }
        return $list
    }
    return $InputObject
}

function New-DefaultProfile {
    $now = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssZ')
    return @{
        user_id = 'default'
        preferences = @{
            models = @()
            coding_style = 'concise'
            favorite_commands = @()
            communication_style = 'concise'
            knowledge_level = 'intermediate'
        }
        task_patterns = @()
        project_context = @{}
        created_at = $now
        last_updated = $now
    }
}

function Ensure-ProfileShape {
    param($Profile)
    if (-not $Profile) { return New-DefaultProfile }
    if (-not $Profile.preferences) { $Profile.preferences = @{} }
    if (-not $Profile.preferences.models) { $Profile.preferences.models = @() }
    if ($Profile.preferences.models -isnot [array]) { $Profile.preferences.models = @($Profile.preferences.models) }
    if (-not $Profile.preferences.favorite_commands) { $Profile.preferences.favorite_commands = @() }
    if ($Profile.preferences.favorite_commands -isnot [array]) { $Profile.preferences.favorite_commands = @($Profile.preferences.favorite_commands) }
    if (-not $Profile.preferences.coding_style) { $Profile.preferences.coding_style = 'concise' }
    if (-not $Profile.preferences.communication_style) { $Profile.preferences.communication_style = 'concise' }
    if (-not $Profile.preferences.knowledge_level) { $Profile.preferences.knowledge_level = 'intermediate' }
    if (-not $Profile.task_patterns) { $Profile.task_patterns = @() }
    if ($Profile.task_patterns -isnot [array]) { $Profile.task_patterns = @($Profile.task_patterns) }
    if (-not $Profile.project_context) { $Profile.project_context = @{} }
    if ($Profile.project_context -is [string]) {
        try { $Profile.project_context = $Profile.project_context | ConvertFrom-Json } catch { $Profile.project_context = @{} }
    }
    if ($Profile.project_context -isnot [System.Collections.IDictionary]) { $Profile.project_context = @{} }
    if (-not $Profile.user_id) { $Profile.user_id = 'default' }
    if (-not $Profile.created_at) { $Profile.created_at = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssZ') }
    return $Profile
}

function Get-UserProfile {
    if (-not (Test-Path $userProfilePath)) {
        return Ensure-ProfileShape (New-DefaultProfile)
    }
    try {
        $obj = Get-Content $userProfilePath -Raw | ConvertFrom-Json
        return Ensure-ProfileShape (Convert-ToHashtable $obj)
    } catch {
        Write-Log "Invalid user-profile.jsonl, using defaults: $_" -Level 'WARN' -Component 'user-profile'
        return Ensure-ProfileShape (New-DefaultProfile)
    }
}

function Save-UserProfile {
    param($Profile)
    $dir = Split-Path $userProfilePath
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $Profile.last_updated = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssZ')
    $Profile | ConvertTo-Json -Depth 20 -Compress | Set-Content $userProfilePath -Encoding UTF8
    Publish-Event -Type 'user.profile.updated' -Data @{ path = $userProfilePath }
}

function Add-UniqueToArray {
    param([array]$Array, [string]$Value)
    if (-not $Value) { return @($Array) }
    $result = @()
    foreach ($item in @($Array)) {
        if ([string]$item -ne $Value) { $result += $item }
    }
    $result += $Value
    return $result
}

function Trim-Array {
    param([array]$Array, [int]$Max = 20)
    if (-not $Array) { return @() }
    $count = @($Array).Count
    if ($count -le $Max) { return @($Array) }
    return @($Array)[($count - $Max)..($count - 1)]
}

function Get-ObjectiveSummary {
    param([string]$Text)
    if (-not $Text) { return '' }
    if ($Text.Length -le 120) { return $Text }
    return $Text.Substring(0, 117) + '...'
}

switch ($Action) {
    'read' {
        Get-UserProfile | ConvertTo-Json -Depth 20
    }

    'update' {
        if (-not $Key -or -not $Value) {
            Write-Error 'Key and Value required for update action'
            exit 1
        }
        $profile = Get-UserProfile
        $profile.$Key = $Value
        Save-UserProfile -Profile $profile
        Write-Host "Updated $Key in user profile" -ForegroundColor Green
    }

    'record-preference' {
        if (-not $Category -or -not $Value) {
            Write-Error 'Category and Value required for record-preference action'
            exit 1
        }
        $profile = Get-UserProfile
        $subKey = if ($SubKey) { $SubKey } else { (Get-Date).ToString('yyyyMMddHHmmss') }

        if ($Category -eq 'models') {
            $profile.preferences.models = Add-UniqueToArray -Array $profile.preferences.models -Value $Value
        } elseif ($Category -eq 'favorite_commands') {
            $profile.preferences.favorite_commands = Add-UniqueToArray -Array $profile.preferences.favorite_commands -Value $Value
        } elseif ($Category -eq 'coding_style') {
            $profile.preferences.coding_style = $Value
        } else {
            if (-not $profile.preferences.$Category) { $profile.preferences.$Category = @{} }
            $profile.preferences.$Category.$subKey = $Value
        }

        Save-UserProfile -Profile $profile
        Write-Host "Recorded preference: $Category = $Value" -ForegroundColor Green
    }

    'record-task-pattern' {
        if (-not $Category -or -not $SubKey -or -not $Value) {
            Write-Error 'Category, SubKey, and Value required for record-task-pattern action'
            exit 1
        }
        $profile = Get-UserProfile
        $entry = @{
            timestamp = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssZ')
            category = $Category
            key = $SubKey
            value = $Value
        }
        if ($TaskId) { $entry.task_id = $TaskId }
        $profile.task_patterns = Trim-Array -Array (@($profile.task_patterns) + @($entry)) -Max 50
        Save-UserProfile -Profile $profile
        Write-Host "Recorded task pattern: $Category.$SubKey = $Value" -ForegroundColor Green
    }

    'record-task-completion' {
        if (-not $TaskId -or -not $TaskType) {
            Write-Error 'TaskId and TaskType required for record-task-completion action'
            exit 1
        }
        $profile = Get-UserProfile
        $entry = @{
            timestamp = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssZ')
            task_id = $TaskId
            type = $TaskType
            priority = if ($Priority) { $Priority } else { 'unknown' }
            agent = if ($Agent) { $Agent } else { 'unknown' }
            objective = Get-ObjectiveSummary -Text $Objective
        }
        $profile.task_patterns = Trim-Array -Array (@($profile.task_patterns) + @($entry)) -Max 50
        Save-UserProfile -Profile $profile
        Write-Host "Recorded task completion pattern for $TaskId" -ForegroundColor Green
    }

    'update-project-context' {
        if (-not $Key -or -not $Value) {
            Write-Error 'Key and Value required for update-project-context action'
            exit 1
        }
        $profile = Get-UserProfile
        $profile.project_context.$Key = $Value
        Save-UserProfile -Profile $profile
        Write-Host "Updated project context: $Key = $Value" -ForegroundColor Green
    }

    'get-preference' {
        if (-not $Category -or -not $SubKey) {
            Write-Error 'Category and SubKey required for get-preference action'
            exit 1
        }
        $profile = Get-UserProfile
        if ($Category -eq 'models') {
            Write-Output ($profile.preferences.models -join ', ')
        } elseif ($Category -eq 'favorite_commands') {
            Write-Output ($profile.preferences.favorite_commands -join ' | ')
        } else {
            $pref = $profile.preferences.$Category.$SubKey
            if ($pref) { Write-Output $pref } else { Write-Error "Preference $Category.$SubKey not found"; exit 1 }
        }
    }

    'suggest-model' {
        $profile = Get-UserProfile
        $models = @($profile.preferences.models | Where-Object { $_ })
        if ($models.Count -gt 0) {
            # Most recently used = last in array (append-only)
            $suggested = $models[-1]
            Write-Output $suggested
        } else {
            Write-Output "kilo/kilo-auto/free"
        }
    }

    'get-frequent-patterns' {
        $profile = Get-UserProfile
        $patterns = @($profile.task_patterns | Where-Object { $_ })
        if ($patterns.Count -eq 0) {
            Write-Output "No patterns recorded yet."
            exit 0
        }
        # Group by type and count
        $typeCounts = @{}
        $agentCounts = @{}
        foreach ($p in $patterns) {
            $t = if ($p.type) { $p.type } else { 'unknown' }
            $a = if ($p.agent) { $p.agent } else { 'unknown' }
            if (-not $typeCounts[$t]) { $typeCounts[$t] = 0 }; $typeCounts[$t]++
            if (-not $agentCounts[$a]) { $agentCounts[$a] = 0 }; $agentCounts[$a]++
        }
        Write-Host '=== FREQUENT PATTERNS ===' -ForegroundColor Cyan
        Write-Host 'By task type:' -ForegroundColor Gray
        $typeCounts.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object { Write-Host ('  {0}: {1}' -f $_.Key, $_.Value) }
        Write-Host 'By agent:' -ForegroundColor Gray
        $agentCounts.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object { Write-Host ('  {0}: {1}' -f $_.Key, $_.Value) }
        Write-Host ('Total patterns: {0}' -f $patterns.Count) -ForegroundColor DarkGray
    }

    'suggest-approach' {
        $profile = Get-UserProfile
        $patterns = @($profile.task_patterns | Where-Object { $_ })
        if ($patterns.Count -lt 2) {
            Write-Output "Not enough data to suggest approach. Continue working."
            exit 0
        }
        # Simple heuristic: most common type + most successful agent for that type
        $typeCounts = @{}
        foreach ($p in $patterns) {
            $t = if ($p.type) { $p.type } else { 'unknown' }
            if (-not $typeCounts[$t]) { $typeCounts[$t] = 0 }; $typeCounts[$t]++
        }
        $topType = ($typeCounts.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 1).Key
        $agentForType = $patterns | Where-Object { $_.type -eq $topType } | Group-Object agent | Sort-Object Count -Descending | Select-Object -First 1
        $suggestedAgent = if ($agentForType) { $agentForType.Name } else { 'executive-orchestrator' }
        Write-Output "{ \"suggested_type\": \"$topType\", \"suggested_agent\": \"$suggestedAgent\", \"reason\": \"most frequent type + most used agent\" }"
    }
}

exit 0
