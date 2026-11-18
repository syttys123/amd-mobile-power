param(
    [string]$TaskName = 'AmdMobilePower CurrentPolicy AtLogon',
    [string]$ScriptPath = (Join-Path $PSScriptRoot 'restore-current-policy.ps1'),
    [ValidateRange(5, 60)][int]$DayBatteryWatts = 25,
    [ValidateRange(5, 60)][int]$DayAcWatts = 45,
    [ValidateRange(5, 60)][int]$NightBatteryWatts = 15,
    [ValidateRange(5, 60)][int]$NightAcWatts = 15,
    [switch]$Apply
)

$ErrorActionPreference = 'Stop'
$resolvedScript = [System.IO.Path]::GetFullPath($ScriptPath)
if (-not (Test-Path -LiteralPath $resolvedScript -PathType Leaf)) {
    throw "Current-policy script is missing: $resolvedScript"
}
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$arguments = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -DayBatteryWatts {1} -DayAcWatts {2} -NightBatteryWatts {3} -NightAcWatts {4}' -f `
    $resolvedScript, $DayBatteryWatts, $DayAcWatts, $NightBatteryWatts, $NightAcWatts
$action = New-ScheduledTaskAction -Execute $powershell -Argument $arguments `
    -WorkingDirectory (Split-Path -Parent $resolvedScript)
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $identity.Name
$trigger.Delay = 'PT20S'
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
$principal = New-ScheduledTaskPrincipal -UserId $identity.Name `
    -LogonType Interactive -RunLevel Limited
$existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue

$plan = [ordered]@{
    TaskName = $TaskName
    Exists = [bool]$existing
    Action = $powershell
    Arguments = $arguments
    Trigger = 'Current user logon + 20 seconds'
    Day = "$DayBatteryWatts/$DayAcWatts W"
    Night = "$NightBatteryWatts/$NightAcWatts W"
    Apply = [bool]$Apply
}
if (-not $Apply) {
    $plan | ConvertTo-Json -Depth 5
    return
}

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
    -Settings $settings -Principal $principal `
    -Description 'Restore the configured AMD Mobile Power day/night policy after current-user logon.' `
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
    $registered.Triggers.Count -ne 1 -or
    $registered.Triggers[0].Delay -ne 'PT20S' -or
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
} | ConvertTo-Json -Depth 5
