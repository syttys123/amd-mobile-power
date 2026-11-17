$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSCommandPath
$scriptPath = Join-Path $root 'verify-release.ps1'
$source = Get-Content -LiteralPath $scriptPath -Raw
$failures = New-Object System.Collections.Generic.List[string]

function Assert-Contains([string]$Text, [string]$Needle, [string]$Message) {
    if (-not $Text.Contains($Needle)) {
        $script:failures.Add($Message)
    }
}

Assert-Contains $source '$stableGuiSnapshot = @(Get-StableGuiSnapshot)' `
    'verify-release must snapshot the stable GUI before hardware/package work'
Assert-Contains $source 'Stop-TestOwnerProcesses' `
    'test-owned GUI/worker cleanup must run before recovery'
Assert-Contains $source 'Restore-StableGuiAfterReleaseGate' `
    'finally must enter the stable GUI recovery function'
Assert-Contains $source 'try {' `
    'the release body must be exception-guarded'
Assert-Contains $source 'finally {' `
    'the release body must have a finally recovery path'
Assert-Contains $source '-AllowGuiAutoStart' `
    'stable recovery must use the opt-in GUI auto-start helper path'
Assert-Contains $source '-RefreshGui' `
    'stable recovery must use the safe GUI reload path'
Assert-Contains $source '$hour -ge 7 -and $hour -lt 23' `
    'recovery must select the 07:00-23:00 day window'
Assert-Contains $source '{ 25 } else { 15 }' `
    'recovery must select battery 25/15 W by time window'
Assert-Contains $source '{ 45 } else { 15 }' `
    'recovery must select AC 45/15 W by time window'
Assert-Contains $source 'getPowerPolicy' `
    'recovery must probe the worker policy'
Assert-Contains $source 'getSnapshot' `
    'recovery must probe current telemetry limits'
Assert-Contains $source 'stable GUI recovery also failed' `
    'recovery failure must not hide the original verification failure'
Assert-Contains $source 'InitialStableGui' `
    'gate evidence must record the initial stable GUI state'

if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Error $_ }
    Write-Output 'release-gui-recovery-contract: FAIL'
    exit 1
}
Write-Output 'release-gui-recovery-contract: PASS'
