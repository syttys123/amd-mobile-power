function Invoke-RemappedRustBuild {
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][scriptblock]$Action
    )
    $previous = $env:CARGO_ENCODED_RUSTFLAGS
    $separator = [string][char]31
    $flags = @()
    if ($previous) { $flags += $previous.Split([char]31) }
    elseif ($env:RUSTFLAGS) { $flags += $env:RUSTFLAGS -split '\s+' | Where-Object { $_ } }
    $roots = [ordered]@{}
    # rustc uses the last matching prefix; specific roots must follow home.
    if ($env:USERPROFILE) { $roots[$env:USERPROFILE] = '/build/home' }
    if ($env:CARGO_HOME) { $roots[$env:CARGO_HOME] = '/build/cargo' }
    if ($env:RUSTUP_HOME) { $roots[$env:RUSTUP_HOME] = '/build/rustup' }
    $roots[[System.IO.Path]::GetFullPath($RepositoryRoot)] = '/src/amd-mobile-power'
    foreach ($entry in $roots.GetEnumerator()) {
        foreach ($path in @($entry.Key, $entry.Key.Replace('\', '/')) | Select-Object -Unique) {
            $flags += "--remap-path-prefix=$path=$($entry.Value)"
        }
    }
    try {
        $env:CARGO_ENCODED_RUSTFLAGS = $flags -join $separator
        & $Action
    }
    finally { $env:CARGO_ENCODED_RUSTFLAGS = $previous }
}
