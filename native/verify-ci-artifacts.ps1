param(
    [Parameter(Mandatory = $true)][string]$PackagePath,
    [Parameter(Mandatory = $true)][string]$ReproducibilityPath,
    [Parameter(Mandatory = $true)][string]$SanitizationPath
)
$ErrorActionPreference = 'Stop'
foreach ($path in @($PackagePath, "$PackagePath.sha256", $ReproducibilityPath, $SanitizationPath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing CI artifact: $path" }
}
$hash = (Get-FileHash -LiteralPath $PackagePath -Algorithm SHA256).Hash.ToLowerInvariant()
$checksum = (Get-Content -LiteralPath "$PackagePath.sha256" -Raw).Trim()
if ($checksum -notmatch '^([0-9a-fA-F]{64})(?:\s|$)' -or $Matches[1].ToLowerInvariant() -ne $hash) {
    throw 'CI checksum does not match the ZIP.'
}
$repro = Get-Content -LiteralPath $ReproducibilityPath -Raw | ConvertFrom-Json
$privacy = Get-Content -LiteralPath $SanitizationPath -Raw | ConvertFrom-Json
if ($repro.Verification -ne 'PASS' -or @($repro.Failures).Count -ne 0 -or
    $repro.Results.Package.First -ne $hash -or $repro.Results.Package.Second -ne $hash -or
    $repro.Results.Package.Reproducible -ne $true) {
    throw 'CI reproducibility evidence is incomplete or does not match the ZIP.'
}
foreach ($name in @('Gui', 'Worker', 'Probe')) {
    $item = $repro.Results.$name
    if ($item.Reproducible -ne $true -or $item.First -notmatch '^[0-9a-f]{64}$' -or
        $item.First -ne $item.Second) { throw "Missing or failed CI binary rebuild: $name" }
}
if ($privacy.Verification -ne 'PASS' -or $privacy.PackageSHA256 -ne $hash -or
    [int]$privacy.PackageBinariesScanned -lt 7 -or [int]$privacy.PackageEntriesScanned -lt 1 -or
    'ASCII' -notin $privacy.BinaryEncodings -or 'UTF-16LE' -notin $privacy.BinaryEncodings) {
    throw 'CI sanitization evidence lacks matching ZIP or binary coverage.'
}
Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [System.IO.Compression.ZipFile]::OpenRead((Resolve-Path -LiteralPath $PackagePath).Path)
try {
    $buildEntries = @($archive.Entries | Where-Object { $_.FullName -match '^[^/]+/BUILD-INFO\.txt$' })
    if ($buildEntries.Count -ne 1) { throw 'CI ZIP must contain one root BUILD-INFO.' }
    $reader = [IO.StreamReader]::new($buildEntries[0].Open())
    try { $buildText = $reader.ReadToEnd() } finally { $reader.Dispose() }
    $build = @{}
    foreach ($line in $buildText -split '\r?\n') {
        if ($line -match '^([^=]+)=(.*)$') { $build[$Matches[1]] = $Matches[2] }
    }
    if ($build.WorkingTree -ne 'Clean' -or $build.Commit -ne $privacy.SourceCommit -or
        $build.Version -ne $repro.Results.Package.Version) { throw 'CI source/version identity mismatch.' }
    foreach ($pair in @(@('Gui','amd-mobile-power-gui.exe'),
        @('Worker','amdmobilepower_native_worker.exe'), @('Probe','amd-mobile-power-probe.exe'))) {
        $entries = @($archive.Entries | Where-Object { $_.FullName -match ('^[^/]+/' + [regex]::Escape($pair[1]) + '$') })
        if ($entries.Count -ne 1) { throw "CI ZIP binary is missing or duplicated: $($pair[0])" }
        $stream = $entries[0].Open()
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $actual = ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-','').ToLowerInvariant() }
        finally { $sha.Dispose(); $stream.Dispose() }
        if ($actual -ne $repro.Results.($pair[0]).First) { throw "CI ZIP binary hash mismatch: $($pair[0])" }
    }
} finally { $archive.Dispose() }
Write-Output 'PASS: required CI artifacts, source identity and packaged binary hashes match.'
