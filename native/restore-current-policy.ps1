param(
    [ValidateRange(5, 60)][int]$DayBatteryWatts = 25,
    [ValidateRange(5, 60)][int]$DayAcWatts = 45,
    [ValidateRange(5, 60)][int]$NightBatteryWatts = 15,
    [ValidateRange(5, 60)][int]$NightAcWatts = 15,
    [ValidateRange(0, 23)][int]$DayStartHour = 7,
    [ValidateRange(0, 23)][int]$NightStartHour = 23,
    [string]$HelperPath = (Join-Path $PSScriptRoot 'apply-power-policy-direct.ps1'),
    [string]$LogPath = (Join-Path $env:LOCALAPPDATA 'AmdMobilePower\maintenance\current-policy.log'),
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
