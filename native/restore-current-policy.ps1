param(
    [ValidateRange(5, 60)][int]$DayBatteryWatts = 25,
    [ValidateRange(5, 60)][int]$DayAcWatts = 45,
    [ValidateRange(5, 60)][int]$NightBatteryWatts = 10,
    [ValidateRange(5, 60)][int]$NightAcWatts = 10,
    [ValidateRange(0, 23)][int]$DayStartHour = 7,
    [ValidateRange(0, 23)][int]$NightStartHour = 23,
    [string]$HelperPath = (Join-Path $PSScriptRoot 'apply-power-policy-direct.ps1'),
    [string]$LogPath = (Join-Path $env:LOCALAPPDATA 'AmdMobilePower\maintenance\current-policy.log'),
    [string]$ProbePath = 'C:\RyzenAdj\amd-mobile-power-probe.exe',
    [string]$PipeName = '\\.\pipe\AmdMobilePower.RustGui.Worker.v1',
    [switch]$SkipIfAlreadyApplied,
    [datetime]$Now = (Get-Date)
)

$ErrorActionPreference = 'Stop'
if ($DayStartHour -eq $NightStartHour) {
    throw 'DayStartHour and NightStartHour must differ.'
}
if (-not (Test-Path -LiteralPath $HelperPath -PathType Leaf)) {
    throw "Policy helper is missing: $HelperPath"
}

# The day window may wrap midnight. Evaluate the local wall clock supplied by
# Windows Task Scheduler; do not infer the active policy from the saved state,
# which may describe the previous boot or a manual temporary target.
$hour = $Now.Hour
$isDay = if ($DayStartHour -lt $NightStartHour) {
    $hour -ge $DayStartHour -and $hour -lt $NightStartHour
}
else {
    $hour -ge $DayStartHour -or $hour -lt $NightStartHour
}
$battery = if ($isDay) { $DayBatteryWatts } else { $NightBatteryWatts }
$ac = if ($isDay) { $DayAcWatts } else { $NightAcWatts }
$window = if ($isDay) { 'day' } else { 'night' }

$directory = Split-Path -Parent $LogPath
if ($directory -and -not (Test-Path -LiteralPath $directory)) {
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
}
"{0:o} START window={1} battery={2} ac={3}" -f (Get-Date), $window, $battery, $ac |
    Add-Content -LiteralPath $LogPath -Encoding UTF8

if ($SkipIfAlreadyApplied) {
    if (-not (Test-Path -LiteralPath $ProbePath -PathType Leaf)) {
        throw "Policy probe is missing: $ProbePath"
    }
    . (Join-Path $PSScriptRoot 'worker-client.ps1')
    try {
        $policyResult = Invoke-WorkerPipeRequest -PipeName $PipeName `
            -Command 'getPowerPolicy' -ConnectTimeoutMilliseconds 1500 `
            -ReadTimeoutMilliseconds 2500
        $snapshotResult = Invoke-WorkerPipeRequest -PipeName $PipeName `
            -Command 'getSnapshot' -ConnectTimeoutMilliseconds 1500 `
            -ReadTimeoutMilliseconds 2500
        if ($policyResult.Success -and $snapshotResult.Success) {
            $state = $policyResult.Payload
            $settings = $state.settings
            $telemetry = $snapshotResult.Payload.telemetry
            $line = [string]$telemetry.powerLine
            $expected = if ($line -eq 'ac') { $ac } else { $battery }
            $target = if ($line -eq 'ac') { $settings.acTarget } else { $settings.batteryTarget }
            $applied = $state.lastAppliedTarget
            $settingsMatch = $settings.enabled -eq $true -and
                $settings.batteryEnabled -eq $true -and $settings.acEnabled -eq $true -and
                $settings.batteryTarget.stapmWatts -eq $battery -and
                $settings.batteryTarget.fastWatts -eq $battery -and
                $settings.batteryTarget.slowWatts -eq $battery -and
                $settings.acTarget.stapmWatts -eq $ac -and
                $settings.acTarget.fastWatts -eq $ac -and
                $settings.acTarget.slowWatts -eq $ac
            $attemptMatch = $state.lastAttemptSucceeded -eq $true -and
                [string]$state.lastObservedPowerLine -eq $line -and
                [string]$state.lastAttemptPowerLine -eq $line -and
                [string]$state.lastAppliedPowerLine -eq $line -and
                $null -ne $applied -and
                $applied.stapmWatts -eq $expected -and
                $applied.fastWatts -eq $expected -and
                $applied.slowWatts -eq $expected
            $readBackMatch = $null -ne $telemetry.fastLimitWatts -and
                $null -ne $telemetry.slowLimitWatts -and
                [Math]::Abs([double]$telemetry.fastLimitWatts - $expected) -le 1.0 -and
                [Math]::Abs([double]$telemetry.slowLimitWatts - $expected) -le 1.0
            if ($settingsMatch -and $attemptMatch -and $readBackMatch) {
                "{0:o} SKIP window={1} battery={2} ac={3} reason=already-applied line={4} fastSlow={5}/{6}" -f `
                    (Get-Date), $window, $battery, $ac, $line,
                    $telemetry.fastLimitWatts, $telemetry.slowLimitWatts |
                    Add-Content -LiteralPath $LogPath -Encoding UTF8
                return
            }
        }
    }
    catch {
        "{0:o} RECOVER reason=probe-unavailable detail={1}" -f (Get-Date), $_.Exception.Message |
            Add-Content -LiteralPath $LogPath -Encoding UTF8
    }
}

$global:LASTEXITCODE = 0
& $HelperPath `
    -BatteryWatts $battery `
    -AcWatts $ac `
    -LogPath $LogPath `
    -AllowGuiAutoStart `
    -RefreshGui
if ($null -ne $LASTEXITCODE -and $LASTEXITCODE -ne 0) {
    throw "Current-policy helper failed with exit code $LASTEXITCODE."
}
"{0:o} PASS window={1} battery={2} ac={3}" -f (Get-Date), $window, $battery, $ac |
    Add-Content -LiteralPath $LogPath -Encoding UTF8
