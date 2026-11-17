$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSCommandPath
$repositoryRoot = Split-Path -Parent $root
$helperPath = Join-Path $root 'apply-power-policy-direct.ps1'
$source = Get-Content -LiteralPath $helperPath -Raw
$failures = New-Object System.Collections.Generic.List[string]

function Assert-Contains([string]$Text, [string]$Needle, [string]$Message) {
    if (-not $Text.Contains($Needle)) {
        $script:failures.Add($Message)
    }
}

Assert-Contains $source '[switch]$AllowGuiAutoStart' `
    'helper must gate GUI auto-start behind an explicit switch'
Assert-Contains $source '[switch]$RefreshGui' `
    'helper must expose a safe GUI reload path'
Assert-Contains $source 'if (-not $AllowStart) {' `
    'Ensure-GuiWorker must refuse to spawn a GUI unless AllowStart is set'
Assert-Contains $source '[AmdDirectPolicyUi]::IsWindowVisible($batteryEdit)' `
    'hidden policy edits must be detected before any POLICY_SAVE post'
Assert-Contains $source 'RESTARTED GUI to reload the saved policy' `
    'policy reload must gracefully restart the tray GUI'
Assert-Contains $source 'gui={2}' `
    'PASS log must describe the GUI reload mode explicitly'
if ($source.Contains('guiSynced=')) {
    $failures.Add('PASS log must not report a boolean guiSynced success state')
}

foreach ($taskName in @(
        'AmdMobilePower DirectDayPolicy 0700',
        'AmdMobilePower DirectNightPolicy 2300')) {
    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if (-not $task) {
        $failures.Add("missing scheduled task: $taskName")
        continue
    }
    $arguments = $task.Actions[0].Arguments
    if ($arguments -notmatch '-AllowGuiAutoStart') {
        $failures.Add("$taskName must opt in to GUI auto-start")
    }
    if ($arguments -notmatch '-RefreshGui') {
        $failures.Add("$taskName must reload the GUI after applying policy")
    }
}

if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Error $_ }
    Write-Output 'policy-helper-contract: FAIL'
    exit 1
}
Write-Output 'policy-helper-contract: PASS'
