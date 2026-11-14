param(
    [Parameter(Mandatory = $true)][int[]]$ProcessIds,
    [ValidateRange(2, 10000)][int]$Samples = 13,
    [ValidateRange(1, 3600)][int]$IntervalSeconds = 5,
    [string]$EvidencePath
)
$ErrorActionPreference = 'Stop'
$targets = @()
$observations = @()
try {
    foreach ($targetId in $ProcessIds) {
        $process = Get-Process -Id $targetId -ErrorAction Stop
        $targets += [pscustomobject]@{
            Process = $process
            StartTime = $process.StartTime.ToUniversalTime()
            Name = $process.ProcessName
        }
    }
    for ($index = 0; $index -lt $Samples; $index++) {
        foreach ($target in $targets) {
            $process = $target.Process
            $process.Refresh()
            if ($process.HasExited -or $process.StartTime.ToUniversalTime() -ne $target.StartTime) {
                throw "Observed process exited or changed identity: $($target.Name)"
            }
            $observations += [pscustomobject]@{
                Sample = $index
                Name = $target.Name
                PrivateBytes = $process.PrivateMemorySize64
                WorkingSetBytes = $process.WorkingSet64
                Handles = $process.HandleCount
                Threads = $process.Threads.Count
                CpuSeconds = $process.TotalProcessorTime.TotalSeconds
            }
        }
        if ($index -lt $Samples - 1) { Start-Sleep -Seconds $IntervalSeconds }
    }
    $summary = foreach ($group in $observations | Group-Object Name) {
        $first = $group.Group[0]
        $last = $group.Group[-1]
        [pscustomobject]@{
            Name = $group.Name
            PrivateBytesFirst = $first.PrivateBytes
            PrivateBytesLast = $last.PrivateBytes
            PrivateBytesPeak = ($group.Group | Measure-Object PrivateBytes -Maximum).Maximum
            HandleDelta = $last.Handles - $first.Handles
            ThreadDelta = $last.Threads - $first.Threads
            CpuSecondsDelta = $last.CpuSeconds - $first.CpuSeconds
        }
    }
    $record = [ordered]@{
        CollectionStatus = 'PASS'
        Scope = 'Read-only bounded observation; not a leak-free verdict'
        DurationSeconds = ($Samples - 1) * $IntervalSeconds
        Summary = @($summary)
        Samples = $observations
        RecordedAt = (Get-Date).ToString('o')
    }
}
finally {
    foreach ($target in $targets) { $target.Process.Dispose() }
}
if ($EvidencePath) {
    $parent = Split-Path -Parent $EvidencePath
    if ($parent) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $record | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $EvidencePath -Encoding utf8
}
$record.Summary | Format-List
