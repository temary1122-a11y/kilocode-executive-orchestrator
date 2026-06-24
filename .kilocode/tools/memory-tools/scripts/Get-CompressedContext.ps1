param(
    [int]$Count = 10,
    [switch]$Compress
)

try {
    $eventsPath = Join-Path $PSScriptRoot '..' '..' 'memory' 'bus' 'events.jsonl'
    if (-not (Test-Path $eventsPath)) {
        Write-Output ""
        exit 0
    }
    $lines = Get-Content $eventsPath -Tail $Count -ErrorAction Stop
    $objects = @()
    foreach ($line in $lines) {
        if ($line.Trim()) {
            $objects += ($line | ConvertFrom-Json)
        }
    }
    $json = $objects | ConvertTo-Json -Compress
    if ($Compress) {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
        $mem = New-Object System.IO.MemoryStream
        $gzip = New-Object System.IO.Compression.GzipStream $mem, ([System.IO.Compression.CompressionMode]::Compress)
        $gzip.Write($bytes, 0, $bytes.Length)
        $gzip.Close()
        $compressed = $mem.ToArray()
        [System.Convert]::ToBase64String($compressed)
    } else {
        Write-Output $json
    }
} catch {
    Write-Output ""
}