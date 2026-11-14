$ErrorActionPreference = 'Stop'
$repository = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'rust-path-remapping.ps1')
$oldFlags = $env:CARGO_ENCODED_RUSTFLAGS
$oldPlainFlags = $env:RUSTFLAGS
try {
    $env:CARGO_ENCODED_RUSTFLAGS = '--cfg' + [char]31 + 'fixture="value with spaces"'
    $expected = $env:CARGO_ENCODED_RUSTFLAGS
    $caught = $false
    try {
        Invoke-RemappedRustBuild -RepositoryRoot $repository -Action {
            if (-not $env:CARGO_ENCODED_RUSTFLAGS.StartsWith($expected)) { throw 'Flags lost.' }
            if ($env:CARGO_ENCODED_RUSTFLAGS -notmatch 'remap-path-prefix') { throw 'Mapping absent.' }
            throw 'expected-action-failure'
        }
    } catch {
        if ($_.Exception.Message -ne 'expected-action-failure') { throw }
        $caught = $true
    }
    if (-not $caught -or $env:CARGO_ENCODED_RUSTFLAGS -ne $expected) { throw 'Flags restoration failed.' }
    $env:CARGO_ENCODED_RUSTFLAGS = $null
    $env:RUSTFLAGS = "--cfg fixture`t-C opt-level=2"
    Invoke-RemappedRustBuild -RepositoryRoot $repository -Action {
        $parts = $env:CARGO_ENCODED_RUSTFLAGS.Split([char]31)
        if (($parts[0..3] -join '|') -ne '--cfg|fixture|-C|opt-level=2') {
            throw 'Plain RUSTFLAGS whitespace semantics changed.'
        }
        $homeIndex = -1
        $repoIndex = -1
        for ($i = 0; $i -lt $parts.Length; $i++) {
            if ($parts[$i].EndsWith('=/build/home')) { $homeIndex = $i }
            if ($parts[$i].EndsWith('=/src/amd-mobile-power')) { $repoIndex = $i }
        }
        if ($env:USERPROFILE -and ($homeIndex -lt 0 -or $repoIndex -le $homeIndex)) {
            throw 'Specific remapping must follow the home prefix.'
        }
    }
    if ($env:CARGO_ENCODED_RUSTFLAGS) { throw 'Unset encoded flags were not restored.' }
} finally {
    $env:CARGO_ENCODED_RUSTFLAGS = $oldFlags
    $env:RUSTFLAGS = $oldPlainFlags
}

$workspace = Join-Path $repository ('artifacts\privacy-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $workspace | Out-Null
try {
    & git -C $workspace init --quiet
    if ($LASTEXITCODE -ne 0) { throw 'Fixture git init failed.' }
    & git -C $workspace -c user.name=Fixture -c user.email=fixture@example.invalid -c commit.gpgsign=false commit --allow-empty --quiet -m fixture
    if ($LASTEXITCODE -ne 0) { throw 'Fixture commit failed.' }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    foreach ($case in @('clean', 'ASCII', 'UTF16')) {
        $zip = Join-Path $workspace "$case.zip"
        $archive = [System.IO.Compression.ZipFile]::Open($zip, [System.IO.Compression.ZipArchiveMode]::Create)
        try {
            $entry = $archive.CreateEntry('fixture.exe')
            $stream = $entry.Open()
            try {
                $text = if ($case -eq 'clean') { 'neutral fixture content' } else {
                    'C:' + '\Users\' + 'FixtureAccount\registry\source.rs'
                }
                $encoding = if ($case -eq 'UTF16') { [Text.Encoding]::Unicode } else { [Text.Encoding]::ASCII }
                $bytes = $encoding.GetBytes($text)
                $stream.Write($bytes, 0, $bytes.Length)
            } finally { $stream.Dispose() }
        } finally { $archive.Dispose() }
        $detected = $false
        try {
            & (Join-Path $PSScriptRoot 'verify-public-sanitization.ps1') -RepositoryRoot $workspace -PackagePath $zip -ScanPackageBinaries | Out-Null
        } catch {
            if ($_.Exception.Message -notmatch 'public-sanitization hit') { throw }
            $detected = $true
        }
        if ($detected -ne ($case -ne 'clean')) { throw "Unexpected scanner verdict: $case" }
    }
} finally {
    $resolved = [IO.Path]::GetFullPath($workspace)
    $allowed = [IO.Path]::GetFullPath((Join-Path $repository 'artifacts')) + [IO.Path]::DirectorySeparatorChar
    if (-not $resolved.StartsWith($allowed, [StringComparison]::OrdinalIgnoreCase)) { throw 'Cleanup path escaped artifacts.' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
Write-Output 'PASS: clean binary, ASCII/UTF-16LE detection, failure-path environment restoration.'
