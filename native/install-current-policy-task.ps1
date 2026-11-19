param(
    [string]$TaskName = 'AmdMobilePower CurrentPolicy AtLogon',
    [string]$ScriptPath = (Join-Path $PSScriptRoot 'restore-current-policy.ps1'),
    [ValidateRange(5, 60)][int]$DayBatteryWatts = 25,
    [ValidateRange(5, 60)][int]$DayAcWatts = 45,
    [ValidateRange(5, 60)][int]$NightBatteryWatts = 10,
    [ValidateRange(5, 60)][int]$NightAcWatts = 10,
    [ValidateRange(1, 60)][int]$WatchdogIntervalMinutes = 5,
    [switch]$Apply
)

$ErrorActionPreference = 'Stop'
$resolvedScript = [System.IO.Path]::GetFullPath($ScriptPath)
if (-not (Test-Path -LiteralPath $resolvedScript -PathType Leaf)) {
    throw "Current-policy script is missing: $resolvedScript"
}
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$arguments = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -DayBatteryWatts {1} -DayAcWatts {2} -NightBatteryWatts {3} -NightAcWatts {4} -SkipIfAlreadyApplied' -f `
    $resolvedScript, $DayBatteryWatts, $DayAcWatts, $NightBatteryWatts, $NightAcWatts
$action = New-ScheduledTaskAction -Execute $powershell -Argument $arguments `
    -WorkingDirectory (Split-Path -Parent $resolvedScript)
$logonTrigger = New-ScheduledTaskTrigger -AtLogOn -User $identity.Name
$logonTrigger.Delay = 'PT20S'
$watchdogTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date).Date `
    -RepetitionInterval (New-TimeSpan -Minutes $WatchdogIntervalMinutes)
$watchdogTrigger.Repetition.Duration = 'P3650D'
$watchdogTrigger.Repetition.StopAtDurationEnd = $false
$triggers = @($logonTrigger, $watchdogTrigger)
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 3)
$principal = New-ScheduledTaskPrincipal -UserId $identity.Name `
    -LogonType Interactive -RunLevel Limited
$existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue

$plan = [ordered]@{
    TaskName = $TaskName
    Exists = [bool]$existing
    Action = $powershell
    Arguments = $arguments
    Trigger = "Current user logon + 20 seconds; every $WatchdogIntervalMinutes minutes"
    Day = "$DayBatteryWatts/$DayAcWatts W"
    Night = "$NightBatteryWatts/$NightAcWatts W"
    Apply = [bool]$Apply
}
if (-not $Apply) {
    $plan | ConvertTo-Json -Depth 5
    return
}

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $triggers `
    -Settings $settings -Principal $principal `
    -Description 'Restore the configured AMD Mobile Power day/night policy after logon and missed sleep boundaries.' `
    -Force | Out-Null
$registered = Get-ScheduledTask -TaskName $TaskName
$registeredUser = [string]$registered.Principal.UserId
$registeredSid = if ($registeredUser -match '^S-1-5-21-') {
    $registeredUser
}
else {
    try {
        ([Security.Principal.NTAccount]$registeredUser).
            Translate([Security.Principal.SecurityIdentifier]).Value
    } catch { '' }
}
$registeredName = try {
    ([Security.Principal.SecurityIdentifier]$registeredSid).
        Translate([Security.Principal.NTAccount]).Value
} catch { '' }
$currentName = $identity.Name
$currentShortName = if ($currentName.Contains('\')) {
    $currentName.Substring($currentName.IndexOf('\') + 1)
} else { $currentName }
if ($registered.Actions[0].Arguments -ne $arguments -or
    $registered.Triggers.Count -ne 2 -or
    $registered.Triggers[0].Delay -ne 'PT20S' -or
    $registered.Triggers[1].Repetition.Interval -ne "PT${WatchdogIntervalMinutes}M" -or
    $registered.Triggers[1].Repetition.StopAtDurationEnd -or
    ($registeredSid -ne $identity.User.Value -and
     $registeredName -ne $currentName -and
     $registeredUser -ne $currentName -and
     $registeredUser -ne $currentShortName) -or
    $registered.Settings.DisallowStartIfOnBatteries -or
    $registered.Settings.StopIfGoingOnBatteries -or
    -not $registered.Settings.StartWhenAvailable -or
    [string]$registered.Settings.MultipleInstances -ne 'IgnoreNew') {
    throw 'Registered current-policy task did not match the reviewed plan.'
}
[pscustomobject]@{
    Verification = 'PASS'
    TaskName = $TaskName
    State = [string]$registered.State
    Arguments = $registered.Actions[0].Arguments
    WatchdogIntervalMinutes = $WatchdogIntervalMinutes
} | ConvertTo-Json -Depth 5
