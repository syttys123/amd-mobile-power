param([string]$EvidencePath)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSCommandPath
$repositoryRoot = Split-Path -Parent $root
$work = Join-Path $repositoryRoot ('artifacts\policy-current-contract-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work -Force | Out-Null
$results = [System.Collections.Generic.List[object]]::new()

function Add-Result([string]$Name, [bool]$Passed, [string]$Detail) {
    $results.Add([ordered]@{ Name = $Name; Passed = $Passed; Detail = $Detail })
    Write-Host ('{0} {1} :: {2}' -f $(if ($Passed) { 'PASS' } else { 'FAIL' }), $Name, $Detail)
}

try {
    $fakeHelper = Join-Path $work 'fake-helper.ps1'
    @'
param([int]$BatteryWatts,[int]$AcWatts,[string]$LogPath,[switch]$AllowGuiAutoStart,[switch]$RefreshGui)
if (-not $AllowGuiAutoStart -or -not $RefreshGui) { throw 'unsafe helper flags' }
"$BatteryWatts/$AcWatts" | Set-Content -LiteralPath $LogPath -Encoding ascii
'@ | Set-Content -LiteralPath $fakeHelper -Encoding UTF8
    $script = Join-Path $root 'restore-current-policy.ps1'
    foreach ($case in @(
        @{ Hour = 6; Expected = '15/15'; Window = 'night' },
        @{ Hour = 7; Expected = '25/45'; Window = 'day' },
        @{ Hour = 22; Expected = '25/45'; Window = 'day' },
        @{ Hour = 23; Expected = '15/15'; Window = 'night' },
        @{ Hour = 0; Expected = '15/15'; Window = 'night' }
    )) {
        $log = Join-Path $work ("case-$($case.Hour).log")
        & $script -HelperPath $fakeHelper -LogPath $log `
            -Now ([datetime]"2026-11-19T$('{0:D2}' -f $case.Hour):30:00") | Out-Null
        $text = Get-Content -LiteralPath $log -Raw
        Add-Result "hour-$($case.Hour)" `
            ($text.Contains($case.Expected) -and $text.Contains("window=$($case.Window)")) `
            "expected=$($case.Expected) window=$($case.Window)"
    }

    $wrapLog = Join-Path $work 'wrap.log'
    & $script -HelperPath $fakeHelper -LogPath $wrapLog `
        -DayStartHour 22 -NightStartHour 6 `
        -Now ([datetime]'2026-11-19T23:30:00') | Out-Null
    Add-Result 'wrapped-day-window' `
        ((Get-Content -LiteralPath $wrapLog -Raw).Contains('25/45')) `
        '23:30 belongs to a 22:00-06:00 day window'

    $invalidRejected = $false
    try {
        & $script -HelperPath $fakeHelper -LogPath (Join-Path $work 'invalid.log') `
            -DayStartHour 7 -NightStartHour 7 | Out-Null
    } catch { $invalidRejected = $true }
    Add-Result 'equal-boundaries-rejected' $invalidRejected 'ambiguous zero-length window fails closed'

    $installer = Join-Path $root 'install-current-policy-task.ps1'
    $planJson = & $installer -ScriptPath $script -Apply:$false
    $plan = ($planJson -join "`n") | ConvertFrom-Json
    Add-Result 'installer-dry-run' `
        (-not $plan.Apply -and $plan.Arguments.Contains('-DayBatteryWatts 25') -and
         $plan.Arguments.Contains('-NightBatteryWatts 15')) `
        'dry run emits the reviewed action without registration'

    $installerText = Get-Content -LiteralPath $installer -Raw
    Add-Result 'task-safety-settings' `
        ($installerText.Contains('-AllowStartIfOnBatteries') -and
         $installerText.Contains('-DontStopIfGoingOnBatteries') -and
         $installerText.Contains('-MultipleInstances IgnoreNew') -and
         $installerText.Contains("-LogonType Interactive -RunLevel Limited")) `
        'battery execution, overlap suppression, and limited interactive principal are explicit'
    Add-Result 'task-readback-normalizes-account-forms' `
        ($installerText.Contains('$currentShortName') -and
         $installerText.Contains('$registeredSid -ne $identity.User.Value') -and
         $installerText.Contains('$registeredUser -ne $currentShortName')) `
        'Task Scheduler may return SID, qualified account, or short account'
    Add-Result 'sleep-boundary-watchdog' `
        ($installerText.Contains('-RepetitionInterval') -and
         $installerText.Contains('$registered.Triggers.Count -ne 2') -and
         $installerText.Contains("Repetition.Duration = 'P3650D'") -and
         $installerText.Contains('Repetition.StopAtDurationEnd = $false') -and
         $installerText.Contains('-SkipIfAlreadyApplied')) `
        'periodic trigger recovers missed sleep boundaries without unconditional GUI restart'

    $restoreText = Get-Content -LiteralPath $script -Raw
    Add-Result 'watchdog-readback-gate' `
        ($restoreText.Contains('$settingsMatch -and $attemptMatch -and $readBackMatch') -and
         $restoreText.Contains('reason=already-applied') -and
         $restoreText.Contains('lastAppliedPowerLine') -and
         $restoreText.Contains('[Math]::Abs([double]$telemetry.fastLimitWatts - $expected) -le 1.0')) `
        'skip requires matching settings, fresh applied-line fields, and Fast/Slow read-back'

    foreach ($file in @('restore-current-policy.ps1','install-current-policy-task.ps1','test-current-policy-contract.ps1')) {
        $tokens = $null; $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $root $file), [ref]$tokens, [ref]$errors) | Out-Null
        Add-Result "ast-$file" ($errors.Count -eq 0) "errors=$($errors.Count)"
    }
}
finally {
    $resolvedWork = [System.IO.Path]::GetFullPath($work)
    $artifacts = [System.IO.Path]::GetFullPath((Join-Path $repositoryRoot 'artifacts'))
    if ($resolvedWork.StartsWith($artifacts + [IO.Path]::DirectorySeparatorChar,
        [StringComparison]::OrdinalIgnoreCase) -and
        (Test-Path -LiteralPath $resolvedWork)) {
        Remove-Item -LiteralPath $resolvedWork -Recurse -Force
    }
}

$failed = @($results | Where-Object { -not $_.Passed })
$report = [ordered]@{
    Verification = if ($failed.Count) { 'FAIL' } else { 'PASS' }
    Checks = $results
    Failures = $failed
    HardwareAccess = $false
    ScheduledTaskMutated = $false
    RecordedAt = (Get-Date).ToString('o')
}
if ($EvidencePath) {
    $resolvedEvidence = [System.IO.Path]::GetFullPath($EvidencePath)
    $artifacts = [System.IO.Path]::GetFullPath((Join-Path $repositoryRoot 'artifacts'))
    if (-not $resolvedEvidence.StartsWith($artifacts + [IO.Path]::DirectorySeparatorChar,
        [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Contract evidence must stay under artifacts.'
    }
    New-Item -ItemType Directory -Path (Split-Path -Parent $resolvedEvidence) -Force | Out-Null
    $report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $resolvedEvidence -Encoding UTF8
}
$report | ConvertTo-Json -Depth 8
if ($failed.Count) { exit 1 }
