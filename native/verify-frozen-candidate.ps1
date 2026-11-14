param(
    [Parameter(Mandatory = $true)][string]$ManifestPath,
    [string]$PackageDirectory,
    [string]$EvidencePath
)
$ErrorActionPreference = 'Stop'
$repository = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
if (-not $PackageDirectory) { $PackageDirectory = Join-Path $repository 'artifacts\native-packages' }
$manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
if ([System.IO.Path]::GetFileName($manifest.Package) -ne $manifest.Package -or
    $manifest.Package -notmatch '\.zip$') { throw 'Manifest package must be a ZIP filename.' }
$zip = Join-Path $PackageDirectory $manifest.Package
function Assert-Hash([string]$Path, [string]$Expected) {
    if ($Expected -notmatch '^[0-9a-f]{64}$') { throw 'Invalid expected SHA256.' }
    if ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() -ne $Expected) {
        throw "Candidate hash mismatch: $([System.IO.Path]::GetFileName($Path))"
    }
}
Assert-Hash $zip $manifest.PackageSHA256
if ((Get-Item -LiteralPath $zip).Length -ne $manifest.PackageBytes) { throw 'Candidate ZIP size mismatch.' }
$stage = [System.IO.Path]::GetFullPath((Join-Path $PackageDirectory ([System.IO.Path]::GetFileNameWithoutExtension($zip))))
$prefix = $stage + [System.IO.Path]::DirectorySeparatorChar
$checksums = @(Get-Content -LiteralPath (Join-Path $stage 'SHA256SUMS.txt'))
$seen = @{}
foreach ($line in $checksums) {
    if ($line -notmatch '^([0-9a-f]{64})  (.+)$') { throw 'Malformed candidate checksum entry.' }
    $hash = $Matches[1]
    $relative = $Matches[2]
    $path = [System.IO.Path]::GetFullPath((Join-Path $stage $relative))
    if ([System.IO.Path]::IsPathRooted($relative) -or
        -not $path.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase) -or
        $seen.ContainsKey($path)) { throw 'Escaping or duplicate candidate checksum target.' }
    $seen[$path] = $true
    Assert-Hash $path $hash
}
foreach ($pair in @(@('amd-mobile-power-gui.exe', $manifest.GuiSHA256),
    @('amdmobilepower_native_worker.exe', $manifest.WorkerSHA256),
    @('amd-mobile-power-probe.exe', $manifest.ProbeSHA256))) {
    Assert-Hash (Join-Path $stage $pair[0]) $pair[1]
}
$build = @{}
foreach ($line in Get-Content -LiteralPath (Join-Path $stage 'BUILD-INFO.txt')) {
    if ($line -match '^([^=]+)=(.*)$') { $build[$Matches[1]] = $Matches[2] }
}
if ($build.Commit -ne $manifest.SourceCommit -or $build.Version -ne $manifest.Version -or
    $build.WorkingTree -ne 'Clean') { throw 'Candidate source/version/clean identity mismatch.' }
foreach ($file in Get-ChildItem -LiteralPath $stage -File -Recurse) {
    if ($file.Name -eq 'SHA256SUMS.txt' -and $file.DirectoryName -eq $stage) { continue }
    if (-not $seen.ContainsKey($file.FullName)) { throw 'Candidate contains an unchecked extra file.' }
}
Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [System.IO.Compression.ZipFile]::OpenRead((Resolve-Path -LiteralPath $zip).Path)
$zipSeen = @{}
$rootName = [System.IO.Path]::GetFileName($stage) + '/'
try {
    foreach ($entry in $archive.Entries) {
        if (-not $entry.FullName.StartsWith($rootName, [System.StringComparison]::Ordinal)) {
            throw 'ZIP entry is outside the candidate root.'
        }
        if (-not $entry.Name) { continue }
        $relative = $entry.FullName.Substring($rootName.Length)
        $path = [System.IO.Path]::GetFullPath((Join-Path $stage $relative))
        if (-not $path.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase) -or
            $zipSeen.ContainsKey($path)) { throw 'Escaping or duplicate ZIP entry.' }
        $zipSeen[$path] = $true
        $stream = $entry.Open()
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try { $entryHash = [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-', '').ToLowerInvariant() }
        finally { $stream.Dispose(); $sha.Dispose() }
        Assert-Hash $path $entryHash
    }
    foreach ($file in Get-ChildItem -LiteralPath $stage -File -Recurse) {
        if (-not $zipSeen.ContainsKey($file.FullName)) { throw 'Staged file is absent from the candidate ZIP.' }
    }
}
finally { $archive.Dispose() }
$record = [ordered]@{
    Verification = 'PASS'
    Scope = 'Pinned ZIP identity and staged payload checksums; not runtime or release approval'
    Version = $manifest.Version
    SourceCommit = $manifest.SourceCommit
    PackageSHA256 = $manifest.PackageSHA256
    ChecksumEntries = $checksums.Count
    ZipEntriesMatched = $zipSeen.Count
    RecordedAt = (Get-Date).ToString('o')
}
if ($EvidencePath) {
    $parent = Split-Path -Parent $EvidencePath
    if ($parent) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $record | ConvertTo-Json | Set-Content -LiteralPath $EvidencePath -Encoding utf8
}
$record | ConvertTo-Json
