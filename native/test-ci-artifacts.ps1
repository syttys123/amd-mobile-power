param([string]$Version = '1.0.37')
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$manifestPath = Join-Path $root "docs/evidence/release/candidate-$Version-frozen-2026-11-15.json"
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
$privacy = Join-Path $root "docs/evidence/release/public-sanitization-$Version-2026-11-15.json"
$zip = Join-Path $root "artifacts/native-packages/$($manifest.Package)"
$scratch = [IO.Path]::GetFullPath((Join-Path $root ('artifacts/ci-contract-' + [guid]::NewGuid().ToString('N'))))
$allowed = [IO.Path]::GetFullPath((Join-Path $root 'artifacts')) + [IO.Path]::DirectorySeparatorChar
if (-not $scratch.StartsWith($allowed, [StringComparison]::OrdinalIgnoreCase)) { throw 'Invalid fixture directory.' }
New-Item -ItemType Directory -Path $scratch | Out-Null
try {
    $results = @{}
    foreach ($pair in @(@('Gui',$manifest.GuiSHA256),@('Worker',$manifest.WorkerSHA256),@('Probe',$manifest.ProbeSHA256))) {
        $results[$pair[0]] = @{ First=$pair[1]; Second=$pair[1]; Reproducible=$true }
    }
    $results.Package = @{ First=$manifest.PackageSHA256; Second=$manifest.PackageSHA256; Reproducible=$true; Version=$Version }
    $synthetic = Join-Path $scratch 'synthetic-repro.json'
    @{ Verification='PASS'; Failures=@(); Results=$results } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $synthetic
    & (Join-Path $PSScriptRoot 'verify-ci-artifacts.ps1') -PackagePath $zip -ReproducibilityPath $synthetic -SanitizationPath $privacy
    $caught = $false
    try {
        & (Join-Path $PSScriptRoot 'verify-ci-artifacts.ps1') -PackagePath $zip -ReproducibilityPath (Join-Path $scratch 'missing.json') -SanitizationPath $privacy
    } catch {
        if ($_.Exception.Message -notmatch 'Missing CI artifact') { throw }
        $caught = $true
    }
    if (-not $caught) { throw 'Missing report was accepted.' }
    Write-Output 'PASS: synthetic contract only; positive and missing-report negative control.'
} finally { Remove-Item -LiteralPath $scratch -Recurse -Force }
