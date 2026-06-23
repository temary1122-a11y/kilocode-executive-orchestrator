<#
.SYNOPSIS
Performs real external research and writes a structured Executive Orchestrator report.

.DESCRIPTION
research-report.ps1 executes targeted web searches, fetches the most relevant pages,
scans local project context when useful, synthesizes findings, saves a Markdown report,
and records a short decision entry through record-decision.ps1.

If Kilo-native websearch/webfetch is not available to a child PowerShell process,
the script falls back to real public web search/fetch using DuckDuckGo/Bing HTML
endpoints and standard HTTP requests. This keeps the research path executable from
PowerShell while still documenting every URL used.

.PARAMETER TaskId
Task identifier from memory-tools.

.PARAMETER Keywords
Keywords that describe the research topic. Use this or -Query.

.PARAMETER Query
Full research query. Use this or -Keywords.

.PARAMETER Complexity
Research depth: low, medium, or high.

.PARAMETER MaxSources
Maximum number of external sources to fetch and cite. Defaults to 6.

.PARAMETER FetchDepth
Number of highest-ranked search results to fetch. Defaults to 3.

.PARAMETER SearchBackend
External search provider mode: auto, bing, duckduckgo, or none. Defaults to auto.

.PARAMETER SearchTimeoutSeconds
HTTP timeout for each external search request. Defaults to 10.

.PARAMETER FetchTimeoutSeconds
HTTP timeout for each fetched page. Defaults to 20.

.PARAMETER SkipInternalContext
Skip local grep/glob-style context scanning.

.PARAMETER NoRecordDecision
Do not call record-decision.ps1 after report creation.

.EXAMPLE
& ".\.kilocode\tools\memory-tools\scripts\research-report.ps1" `
  -TaskId task_123 `
  -Keywords "Executive Orchestrator","research automation","memory tools" `
  -Complexity high `
  -MaxSources 5

.EXAMPLE
& ".\.kilocode\tools\memory-tools\scripts\research-report.ps1" `
  -TaskId task_456 `
  -Query "PowerShell MCP tool orchestration patterns" `
  -Complexity medium
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$TaskId,

    [Parameter(Mandatory = $true, ParameterSetName = 'Keywords')]
    [string[]]$Keywords,

    [Parameter(Mandatory = $true, ParameterSetName = 'Query')]
    [string]$Query,

    [ValidateSet('low', 'medium', 'high')]
    [string]$Complexity = 'medium',

    [ValidateRange(1, 20)]
    [int]$MaxSources = 6,

    [ValidateRange(1, 10)]
    [int]$FetchDepth = 3,

    [ValidateSet('auto', 'bing', 'duckduckgo', 'none')]
    [string]$SearchBackend = 'auto',

    [ValidateRange(3, 30)]
    [int]$SearchTimeoutSeconds = 10,

    [ValidateRange(5, 60)]
    [int]$FetchTimeoutSeconds = 20,

    [switch]$SkipInternalContext,

    [switch]$NoRecordDecision
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

. "$PSScriptRoot\common.ps1"

$script:UserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) KiloResearchReport/1.0'
$script:BaseSearchDepth = 10
$script:Warnings = New-Object System.Collections.Generic.List[string]
$script:SearchErrors = New-Object System.Collections.Generic.List[string]
$script:FetchErrors = New-Object System.Collections.Generic.List[string]

function Add-Warning {
    param([Parameter(Mandatory = $true)][string]$Message)
    $script:Warnings.Add($Message) | Out-Null
    Write-Warning $Message
}

function ConvertFrom-HtmlText {
    param([Parameter(Mandatory = $true)][string]$Html)

    $withoutScripts = [regex]::Replace($Html, '(?is)<(script|style|noscript|svg|canvas)\b.*?</\1>', ' ')
    $withoutTags = [regex]::Replace($withoutScripts, '(?is)<[^>]+>', ' ')
    $decoded = [System.Net.WebUtility]::HtmlDecode($withoutTags)
    return ($decoded -replace '\s+', ' ').Trim()
}

function Get-HtmlTitle {
    param([Parameter(Mandatory = $true)][string]$Html)

    $match = [regex]::Match($Html, '(?is)<title[^>]*>(.*?)</title>')
    if ($match.Success) {
        return (ConvertFrom-HtmlText $match.Groups[1].Value)
    }

    return ''
}

function ConvertFrom-Base64UrlValue {
    param([Parameter(Mandatory = $true)][string]$Value)

    $base64 = $Value.Replace('-', '+').Replace('_', '/')
    while (($base64.Length % 4) -ne 0) {
        $base64 += '='
    }

    $bytes = [Convert]::FromBase64String($base64)
    return [System.Text.Encoding]::UTF8.GetString($bytes)
}

function Normalize-ExternalUrl {
    param([Parameter(Mandatory = $true)][string]$Url)

    $decodedUrl = [System.Uri]::UnescapeDataString($Url)
    if ($decodedUrl -match '(?i)[?&]u=([^&]+)') {
        $encodedTarget = $Matches[1]
        if ($encodedTarget -match '^[a-z]\d(.+)$') {
            try {
                return (ConvertFrom-Base64UrlValue -Value $Matches[1])
            }
            catch {
                return $decodedUrl
            }
        }
    }

    return $decodedUrl
}

function Invoke-HttpGet {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [int]$TimeoutSeconds = 20
    )

    $uri = [System.Uri]$Url
    $request = [System.Net.HttpWebRequest]::Create($uri)
    $request.Method = 'GET'
    $request.UserAgent = $script:UserAgent
    $request.Accept = 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8'
    $request.AllowAutoRedirect = $true
    $request.MaximumAutomaticRedirections = 5
    $request.Timeout = $TimeoutSeconds * 1000
    $request.ReadWriteTimeout = $TimeoutSeconds * 1000

    try {
        $response = $request.GetResponse()
        try {
            $stream = $response.GetResponseStream()
            $reader = [System.IO.StreamReader]::new($stream, [System.Text.Encoding]::UTF8, $true)
            return [pscustomobject]@{
                Url        = $Url
                StatusCode = [int]$response.StatusCode
                Content    = $reader.ReadToEnd()
                Error      = ''
            }
        }
        finally {
            if ($reader) { $reader.Dispose() }
            $response.Dispose()
        }
    }
    catch {
        return [pscustomobject]@{
            Url        = $Url
            StatusCode = 0
            Content    = ''
            Error      = $_.Exception.Message
        }
    }
}

function Invoke-DuckDuckGoSearch {
    param(
        [Parameter(Mandatory = $true)][string]$Query,
        [int]$Limit = 10,
        [int]$TimeoutSeconds = 10
    )

    $escaped = [System.Uri]::EscapeDataString($Query)
    $searchUrl = "https://html.duckduckgo.com/html/?q=$escaped"
    $response = Invoke-HttpGet -Url $searchUrl -TimeoutSeconds $TimeoutSeconds

    if ($response.Error) {
        throw "DuckDuckGo search failed: $($response.Error)"
    }

    $results = New-Object System.Collections.Generic.List[object]
    $html = $response.Content
    $resultMatches = [regex]::Matches($html, '(?is)<a\s+[^>]*href=["'']([^"'']+)["''][^>]*class=["''][^"'']*result__a[^"'']*["''][^>]*>(.*?)</a>')

    foreach ($match in $resultMatches) {
        $href = [System.Net.WebUtility]::HtmlDecode($match.Groups[1].Value)
        $title = ConvertFrom-HtmlText $match.Groups[2].Value
        $rank = $results.Count + 1
        $snippet = ''

        $snippetMatch = [regex]::Match($match.Groups[2].Value, '(?is)<a\s+[^>]*class=["''][^"'']*result__snippet[^"'']*["''][^>]*>(.*?)</a>')
        if (-not $snippetMatch.Success) {
            $snippetMatch = [regex]::Match($html, '(?is)<a\s+[^>]*class=["''][^"'']*result__snippet[^"'']*["''][^>]*>(.*?)</a>')
        }
        if ($snippetMatch.Success) {
            $snippet = ConvertFrom-HtmlText $snippetMatch.Groups[1].Value
        }

        $results.Add([pscustomobject]@{
            Query  = $Query
            Rank   = $rank
            Title  = $title
            Url    = $href
            Snippet = $snippet
            Source = 'duckduckgo'
        })

        if ($results.Count -ge $Limit) { break }
    }

    if ($results.Count -eq 0) {
        throw "DuckDuckGo returned no parseable results for '$Query'."
    }

    return $results.ToArray()
}

function Invoke-BingSearch {
    param(
        [Parameter(Mandatory = $true)][string]$Query,
        [int]$Limit = 10,
        [int]$TimeoutSeconds = 10
    )

    $escaped = [System.Uri]::EscapeDataString($Query)
    $searchUrl = "https://www.bing.com/search?q=$escaped"
    $response = Invoke-HttpGet -Url $searchUrl -TimeoutSeconds $TimeoutSeconds

    if ($response.Error) {
        throw "Bing search failed: $($response.Error)"
    }

    $results = New-Object System.Collections.Generic.List[object]
    $html = $response.Content
    $items = [regex]::Matches($html, '(?is)<li[^>]*class=["''][^"'']*b_algo[^"'']*["''][^>]*>.*?</li>')

    foreach ($item in $items) {
        $anchor = [regex]::Match($item.Value, '(?is)<h2.*?<a[^>]*href=["'']([^"'']+)["''][^>]*>(.*?)</a>')
        if (-not $anchor.Success) { continue }

        $snippetMatch = [regex]::Match($item.Value, '(?is)<p>(.*?)</p>')
        $snippet = if ($snippetMatch.Success) { ConvertFrom-HtmlText $snippetMatch.Groups[1].Value } else { '' }

        $results.Add([pscustomobject]@{
            Query   = $Query
            Rank    = $results.Count + 1
            Title   = ConvertFrom-HtmlText $anchor.Groups[2].Value
            Url     = Normalize-ExternalUrl -Url ([System.Net.WebUtility]::HtmlDecode($anchor.Groups[1].Value))
            Snippet = $snippet
            Source  = 'bing'
        })

        if ($results.Count -ge $Limit) { break }
    }

    if ($results.Count -eq 0) {
        throw "Bing returned no parseable results for '$Query'."
    }

    return $results.ToArray()
}

function Invoke-WebSearch {
    <#
    Mirrors the Kilo websearch intent. A child PowerShell process cannot directly
    call Kilo's interactive tool functions, so this performs real public web search
    and returns the same shape the report pipeline needs.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Query,
        [int]$Limit = 10,
        [string]$SearchBackend = 'auto',
        [int]$TimeoutSeconds = 10
    )

    $providers = switch ($SearchBackend) {
        'auto'       { @('bing', 'duckduckgo') }
        'bing'       { @('bing') }
        'duckduckgo' { @('duckduckgo') }
        'none'       { @() }
    }
    $allResults = New-Object System.Collections.Generic.List[object]
    $seen = @{}

    foreach ($provider in $providers) {
        try {
            $providerResults = if ($provider -eq 'duckduckgo') {
                Invoke-DuckDuckGoSearch -Query $Query -Limit $Limit -TimeoutSeconds $TimeoutSeconds
            }
            else {
                Invoke-BingSearch -Query $Query -Limit $Limit -TimeoutSeconds $TimeoutSeconds
            }

            foreach ($result in $providerResults) {
                if ($seen.ContainsKey($result.Url)) { continue }
                $seen[$result.Url] = $true
                $allResults.Add($result)
            }

            if ($allResults.Count -gt 0) { break }
        }
        catch {
            $message = "$provider search failed for '$Query': $($_.Exception.Message)"
            $script:SearchErrors.Add($message) | Out-Null
            Add-Warning $message
        }
    }

    return $allResults.ToArray()
}

function Invoke-WebFetch {
    <#
    Mirrors the Kilo webfetch intent by fetching real URL content over HTTP.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [int]$TimeoutSeconds = 20
    )

    $response = Invoke-HttpGet -Url $Url -TimeoutSeconds $TimeoutSeconds
    if ($response.Error) {
        $script:FetchErrors.Add("$Url : $($response.Error)") | Out-Null
        return [pscustomobject]@{
            Url        = $Url
            Title      = ''
            Content    = ''
            StatusCode = 0
            Error      = $response.Error
        }
    }

    $title = Get-HtmlTitle $response.Content
    $plain = ConvertFrom-HtmlText $response.Content
    if ($plain.Length -gt 80000) {
        $plain = $plain.Substring(0, 80000)
    }

    return [pscustomobject]@{
        Url        = $Url
        Title      = if ($title) { $title } else { $Url }
        Content    = $plain
        StatusCode = $response.StatusCode
        Error      = ''
    }
}

function Get-Tokens {
    param([Parameter(Mandatory = $true)][string]$Text)

    $matches = [regex]::Matches($Text.ToLowerInvariant(), '\p{L}[\p{L}\p{N}]{2,}')
    return @($matches | ForEach-Object { $_.Value } | Select-Object -Unique)
}

function Get-ResultScore {
    param(
        [Parameter(Mandatory = $true)][object]$Result,
        [Parameter(Mandatory = $true)][string[]]$Tokens
    )

    $haystack = "$($Result.Title) $($Result.Snippet) $($Result.Url)".ToLowerInvariant()
    $score = 0
    foreach ($token in $Tokens) {
        if ($haystack.Contains($token.ToLowerInvariant())) { $score += 2 }
    }

    $domain = try { ([System.Uri]$Result.Url).Host } catch { '' }
    if ($domain -match '(^|\.)docs?\.|learn\.microsoft\.com|github\.com|rfc-editor\.org|wikipedia\.org|medium\.com|arxiv\.org') {
        $score += 3
    }
    if ($domain -match '(^|\.)stackoverflow\.com|reddit\.com|quora\.com') {
        $score += 1
    }

    $score -= [int]$Result.Rank
    return $score
}

function Get-TopFetchCandidates {
    param(
        [Parameter(Mandatory = $true)][object[]]$SearchResults,
        [Parameter(Mandatory = $true)][string[]]$Tokens,
        [Parameter(Mandatory = $true)][int]$FetchDepth
    )

    $selected = New-Object System.Collections.Generic.List[object]
    $seen = @{}
    $ordered = @($SearchResults | Sort-Object @{ Expression = { Get-ResultScore -Result $_ -Tokens $Tokens }; Descending = $true }, Rank)

    foreach ($result in $ordered) {
        if ($selected.Count -ge $FetchDepth) { break }
        if (-not $result.Url -or $seen.ContainsKey($result.Url)) { continue }

        try {
            [void][System.Uri]$result.Url
            $seen[$result.Url] = $true
            $selected.Add($result)
        }
        catch {
            $script:Warnings.Add("Skipped invalid URL: $($result.Url)") | Out-Null
        }
    }

    return $selected.ToArray()
}

function Get-Excerpt {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string[]]$Tokens,
        [int]$MaxLength = 260
    )

    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }

    $sentences = @([regex]::Split($Text, '(?<=[.!?])\s+') | Where-Object { $_.Length -gt 20 } | Select-Object -First 80)
    if ($sentences.Count -eq 0) {
        $sentence = $Text.Substring(0, [Math]::Min($Text.Length, $MaxLength))
        return "$sentence..."
    }

    $scored = foreach ($sentence in $sentences) {
        $lower = $sentence.ToLowerInvariant()
        $score = 0
        foreach ($token in $Tokens) {
            if ($lower.Contains($token.ToLowerInvariant())) { $score += 1 }
        }
        [pscustomobject]@{ Text = $sentence; Score = $score }
    }

    $best = @($scored | Sort-Object Score -Descending | Select-Object -First 2)
    $excerpt = ($best | ForEach-Object { $_.Text }) -join ' '
    if ($excerpt.Length -gt $MaxLength) {
        $excerpt = $excerpt.Substring(0, $MaxLength - 3).Trim() + '...'
    }
    return $excerpt
}

function Find-InternalContext {
    param(
        [Parameter(Mandatory = $true)][string]$Topic,
        [int]$Limit = 40
    )

    $base = Get-BasePath
    $tokens = @(Get-Tokens $Topic)
    if ($tokens.Count -eq 0) { return @() }

    $pattern = '(?i)' + (($tokens | Select-Object -First 8 | ForEach-Object { [regex]::Escape($_) }) -join '|')
    $paths = @(
        (Join-Path $base 'modes\executive-orchestrator.md'),
        (Join-Path $base 'tools\memory-tools\scripts'),
        (Join-Path $base 'tools\memory-tools\README.md'),
        (Join-Path $base 'memory\decisions.md'),
        (Join-Path $base 'memory\tasks.jsonl'),
        (Join-Path $base 'memory\research-reports')
    )

    $hits = @()
    foreach ($path in $paths) {
        if (-not (Test-Path $path)) { continue }

        try {
            $matches = Select-String -Path $path -Pattern $pattern -AllMatches -ErrorAction SilentlyContinue | Select-Object -First $Limit
            foreach ($match in $matches) {
                $hitPath = $match.Filename
                if (-not (Test-Path -LiteralPath $hitPath)) {
                    $joined = Join-Path $base $hitPath
                    if (Test-Path -LiteralPath $joined) {
                        $hitPath = $joined
                    }
                    else {
                        $leaf = Split-Path -Leaf $hitPath
                        $found = Get-ChildItem -Path $base -Recurse -Filter $leaf -File -ErrorAction SilentlyContinue | Select-Object -First 1
                        if ($found) { $hitPath = $found.FullName }
                    }
                }

                try {
                    $resolved = Resolve-Path -LiteralPath $hitPath
                    $relative = $resolved.Path.Replace($base, '.kilocode').Replace('\', '/')
                }
                catch {
                    $relative = $hitPath.Replace('\', '/')
                }

                $snippet = ($match.Line -replace '\s+', ' ').Trim()
                if ($snippet.Length -gt 240) { $snippet = $snippet.Substring(0, 237).Trim() + '...' }
                $hits += [pscustomobject]@{
                    Path    = $relative
                    Line    = $match.LineNumber
                    Snippet = $snippet
                }
            }
        }
        catch {
            $script:Warnings.Add("Internal context scan failed for $path : $($_.Exception.Message)") | Out-Null
        }

        if ($hits.Count -ge $Limit) { break }
    }

    return @($hits)
}

function New-SearchQueries {
    param(
        [Parameter(Mandatory = $true)][string]$Topic,
        [Parameter(Mandatory = $true)][string]$Complexity
    )

    $queryCount = switch ($Complexity) {
        'low'    { 3 }
        'medium' { 4 }
        'high'   { 6 }
    }

    $year = (Get-Date).Year
    $templates = @(
        "$Topic best practices",
        "$Topic architecture patterns",
        "$Topic risks limitations",
        "$Topic implementation examples",
        "$Topic $year",
        "$Topic alternatives comparison",
        "how to evaluate $Topic"
    )

    if ($PSCmdlet.ParameterSetName -eq 'Query') {
        $templates = @($Query) + $templates
    }

    return @($templates | Select-Object -First $queryCount)
}

function New-ShortTopic {
    param([Parameter(Mandatory = $true)][string]$Topic)

    $safe = $Topic.ToLowerInvariant()
    $safe = $safe -replace '[^a-zа-я0-9]+', '-'
    $safe = $safe -replace '^-|-$', ''
    if ([string]::IsNullOrWhiteSpace($safe)) { $safe = 'research' }
    if ($safe.Length -gt 70) { $safe = $safe.Substring(0, 70).TrimEnd('-') }
    return $safe
}

function New-ReportMarkdown {
    param(
        [Parameter(Mandatory = $true)][string]$TaskId,
        [Parameter(Mandatory = $true)][string]$Topic,
        [Parameter(Mandatory = $true)][string]$Complexity,
        [Parameter(Mandatory = $true)][string]$ReportPath,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Queries,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$SearchResults = @(),
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$FetchedPages = @(),
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$InternalContext = @(),
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Warnings = @(),
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$SearchErrors = @(),
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$FetchErrors = @()
    )

    $tokens = @(Get-Tokens $Topic)
    $externalSources = New-Object System.Collections.Generic.List[object]
    $seenSources = @{}

    foreach ($page in $FetchedPages) {
        if ($page.Url -and -not $seenSources.ContainsKey($page.Url)) {
            $seenSources[$page.Url] = $true
            $externalSources.Add($page)
        }
    }

    foreach ($result in $SearchResults | Sort-Object Rank) {
        if ($result.Url -and -not $seenSources.ContainsKey($result.Url)) {
            $seenSources[$result.Url] = $true
            $externalSources.Add($result)
        }
    }

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("# Research Report: $Topic")
    $lines.Add('')
    $lines.Add("- Generated: $(Get-Date -Format 'o')")
    $lines.Add("- TaskId: $TaskId")
    $lines.Add("- Complexity: $Complexity")
    $lines.Add("- Report path: $ReportPath")
    $lines.Add("- Research mode: real external websearch/webfetch with local grep/glob fallback for internal context")
    $lines.Add('')

    $lines.Add('## Summary')
    $lines.Add('')
    $lines.Add('Executed ' + $Queries.Count + ' targeted search queries, collected ' + $SearchResults.Count + ' search results, and fetched ' + $FetchedPages.Count + ' external pages for task ' + $TaskId + '.')
    if ($InternalContext.Count -gt 0) {
        $lines.Add("Internal context scan found $($InternalContext.Count) relevant local hits.")
    }
    else {
        $lines.Add('Internal context scan found no local hits or was skipped.')
    }
    $lines.Add('')

    $lines.Add('## Key Findings')
    $lines.Add('')

    if ($FetchedPages.Count -gt 0) {
        foreach ($page in $FetchedPages) {
            $excerpt = Get-Excerpt -Text $page.Content -Tokens $tokens -MaxLength 300
            if ($excerpt) {
                $lines.Add('- [' + $page.Title + '](' + $page.Url + ') - ' + $excerpt)
            }
            else {
                $lines.Add('- [' + $page.Title + '](' + $page.Url + ') - fetched successfully; no extractable evidence snippet was available.')
            }
        }
    }
    else {
        $lines.Add('- No external pages were fetched successfully.')
    }

    if ($SearchResults.Count -gt 0) {
        $topSignals = @($SearchResults | Sort-Object Rank | Select-Object -First 5)
        foreach ($result in $topSignals) {
            $snippet = if ($result.Snippet) { $result.Snippet } else { 'Search result was available, but no snippet was returned.' }
            $lines.Add('- [' + $result.Title + '](' + $result.Url + ') - ' + $snippet)
        }
    }
    else {
        $lines.Add('- No external search results were returned.')
    }

    if ($InternalContext.Count -gt 0) {
        $lines.Add('')
        $lines.Add('Internal context signals:')
        foreach ($hit in $InternalContext | Select-Object -First 8) {
            $lines.Add('- `' + $hit.Path + ':' + $hit.Line + '` - ' + $hit.Snippet)
        }
    }

    $domains = @($externalSources | ForEach-Object {
        try { ([System.Uri]$_.Url).Host } catch { '' }
    } | Where-Object { $_ } | Sort-Object -Unique)
    if ($domains.Count -gt 0) {
        $lines.Add('')
        $lines.Add('Primary external domains: ' + ($domains -join ', ') + '.')
    }
    $lines.Add('')

    $lines.Add('## Sources')
    $lines.Add('')
    $lines.Add('### Search Queries')
    $lines.Add('')
    foreach ($query in $Queries) {
        $lines.Add('`' + $query + '`')
    }
    $lines.Add('')
    $lines.Add('### External Sources')
    $lines.Add('')
    if ($externalSources.Count -gt 0) {
        foreach ($source in $externalSources) {
            $title = if ($source.Title) { $source.Title } else { $source.Url }
            $lines.Add('- [' + $title + '](' + $source.Url + ')')
        }
    }
    else {
        $lines.Add('- No external sources with usable URLs were collected.')
    }
    $lines.Add('')
    $lines.Add('### Internal Sources')
    $lines.Add('')
    if ($InternalContext.Count -gt 0) {
        foreach ($hit in $InternalContext) {
            $lines.Add('`' + $hit.Path + ':' + $hit.Line + '`')
        }
    }
    else {
        $lines.Add('- None.')
    }
    $lines.Add('')

    $lines.Add('## Risks & Limitations')
    $lines.Add('')
    $lines.Add('- Kilo-native websearch/webfetch cannot be called directly from a child PowerShell process; this script performs real HTTP-based search/fetch and records the exact URLs used.')
    $lines.Add('- Automated extraction is heuristic and may miss nuanced points that require human reading of full sources.')
    $lines.Add('- Fetched pages can be stale, blocked, redirected, or partially rendered; dynamic JavaScript content may be unavailable.')
    if ($Warnings.Count -gt 0) {
        $lines.Add('- Runtime warnings:')
        foreach ($warning in $Warnings) {
            $lines.Add("  - $warning")
        }
    }
    if ($SearchErrors.Count -gt 0) {
        $lines.Add('- Search backend errors:')
        foreach ($errorText in $SearchErrors) {
            $lines.Add("  - $errorText")
        }
    }
    if ($FetchErrors.Count -gt 0) {
        $lines.Add('- Fetch errors:')
        foreach ($errorText in $FetchErrors) {
            $lines.Add("  - $errorText")
        }
    }
    $lines.Add('')

    $lines.Add('## Gaps')
    $lines.Add('')
    if ($SearchResults.Count -eq 0) {
        $lines.Add('- External web search returned no usable results; rerun with a narrower query or use Context7/manual sources when available.')
    }
    if ($FetchedPages.Count -eq 0) {
        $lines.Add('- No fetched page content is available; conclusions should rely only on search snippets and internal context.')
    }
    if ($InternalContext.Count -eq 0) {
        $lines.Add('- No local project context was found; implementation decisions may need direct codebase review.')
    }
    $lines.Add('- Source credibility still needs human validation before high-impact architectural or security decisions.')
    $lines.Add('- If the task depends on a specific library/API, Context7 or official documentation should be checked separately when relevant.')
    $lines.Add('')

    $lines.Add('## Recommendations')
    $lines.Add('')
    if ($Complexity -eq 'low') {
        $lines.Add('- Use this report for lightweight planning and cite the strongest source before implementation.')
    }
    elseif ($Complexity -eq 'medium') {
        $lines.Add('- Review the top fetched sources before turning findings into tasks or delegation packets.')
        $lines.Add('- Convert unresolved risks into explicit verification steps.')
    }
    else {
        $lines.Add('- Treat this as an evidence pack, not a final decision: validate claims against official docs or subject-matter experts.')
        $lines.Add('- Split implementation into small tasks with verification gates for each high-risk assumption.')
        $lines.Add('- Preserve the report path in the context packet for downstream agents.')
    }
    $lines.Add('- Record the research decision and keep this report attached as an artifact in memory.')
    $lines.Add('')

    return ($lines -join [Environment]::NewLine)
}

$topic = if ($PSCmdlet.ParameterSetName -eq 'Keywords') { $Keywords -join ' ' } else { $Query }
$shortTopic = New-ShortTopic -Topic $topic
$queries = New-SearchQueries -Topic $topic -Complexity $Complexity
$tokens = @(Get-Tokens $topic)

$reportDir = Get-ResearchReportsPath
if (-not (Test-Path $reportDir)) {
    New-Item -ItemType Directory -Path $reportDir -Force | Out-Null
}

$timestamp = Get-Date -Format 'yyyyMMdd_HHmm'
$reportPath = Join-Path $reportDir "$timestamp`_$shortTopic.md"

Write-Host "[research-report] TaskId=$TaskId"
Write-Host "[research-report] Topic=$topic"
Write-Host "[research-report] Queries=$($queries.Count)"

$searchResults = New-Object System.Collections.Generic.List[object]
foreach ($query in $queries) {
    Write-Host "[research-report] websearch: $query"
    $results = Invoke-WebSearch -Query $query -Limit $script:BaseSearchDepth -SearchBackend $SearchBackend -TimeoutSeconds $SearchTimeoutSeconds
    foreach ($result in $results) {
        $searchResults.Add($result)
    }
}

$allSearchResults = @($searchResults | Sort-Object Rank | Select-Object -First ($MaxSources * 3))
$candidates = Get-TopFetchCandidates -SearchResults $allSearchResults -Tokens $tokens -FetchDepth ([Math]::Min($FetchDepth, $MaxSources))

$fetchedPages = New-Object System.Collections.Generic.List[object]
foreach ($candidate in $candidates) {
    Write-Host "[research-report] webfetch: $($candidate.Url)"
    $page = Invoke-WebFetch -Url $candidate.Url -TimeoutSeconds $FetchTimeoutSeconds
    $fetchedPages.Add($page)
}

$internalContext = @()
if (-not $SkipInternalContext) {
    $internalContext = @(Find-InternalContext -Topic $topic)
}

$markdown = New-ReportMarkdown `
    -TaskId $TaskId `
    -Topic $topic `
    -Complexity $Complexity `
    -ReportPath $reportPath `
    -Queries $queries `
    -SearchResults $allSearchResults `
    -FetchedPages $fetchedPages.ToArray() `
    -InternalContext $internalContext `
    -Warnings @($script:Warnings) `
    -SearchErrors @($script:SearchErrors) `
    -FetchErrors @($script:FetchErrors)

Set-Content -Path $reportPath -Value $markdown -Encoding UTF8

$recordDecisionStatus = 'skipped'
if (-not $NoRecordDecision) {
    $recordScript = Join-Path $PSScriptRoot 'record-decision.ps1'
    try {
        & $recordScript `
            -Topic "Research: $shortTopic" `
            -Problem ('Research needed for task ' + $TaskId + ': ' + $topic) `
            -Choice "Research report generated" `
            -Rationale "Executed $($queries.Count) searches, fetched $($fetchedPages.Count) pages, and saved $reportPath" `
            -Task $TaskId `
            -Artifacts $reportPath
        $recordDecisionStatus = 'recorded'
    }
    catch {
        $recordDecisionStatus = 'failed'
        Add-Warning "record-decision.ps1 failed: $($_.Exception.Message)"
    }
}

$status = [ordered]@{
    taskId             = $TaskId
    topic              = $topic
    complexity         = $Complexity
    reportPath         = $reportPath
    queriesExecuted    = $queries.Count
    searchResults      = $allSearchResults.Count
    pagesFetched       = $fetchedPages.Count
    internalHits       = $internalContext.Count
    recordDecision     = $recordDecisionStatus
}

Write-Host "[research-report] Report=$reportPath"
Write-Host "[research-report] SearchResults=$($status.searchResults) FetchedPages=$($status.pagesFetched) InternalHits=$($status.internalHits) Decision=$recordDecisionStatus"
$status | ConvertTo-Json -Depth 4
