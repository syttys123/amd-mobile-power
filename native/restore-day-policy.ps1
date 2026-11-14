param(
    [int]$BatteryWatts = 10,
    [int]$AcWatts = 45,
    [string]$GuiPath = 'C:\RyzenAdj\amd-mobile-power-gui.exe',
    [string]$ProbePath = 'C:\RyzenAdj\amd-mobile-power-probe.exe',
    [string]$LogPath
)
$ErrorActionPreference = 'Stop'
if (-not $LogPath) { $LogPath = Join-Path $PSScriptRoot 'restore-day-policy.log' }
function Write-Log([string]$Message) {
    "{0:o} {1}" -f (Get-Date), $Message |
        Add-Content -LiteralPath $LogPath -Encoding UTF8
}

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class AmdDayPolicyUi {
    public delegate bool EnumProc(IntPtr hwnd, IntPtr parameter);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc callback, IntPtr parameter);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint processId);
    [DllImport("user32.dll")] public static extern IntPtr GetDlgItem(IntPtr hwnd, int id);
    [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "SendMessageW")]
    public static extern IntPtr SetText(IntPtr hwnd, uint message, UIntPtr wParam, string text);
    [DllImport("user32.dll", EntryPoint = "SendMessageW")]
    public static extern IntPtr Send(IntPtr hwnd, uint message, UIntPtr wParam, IntPtr lParam);
}
'@

$pipeName = '\\.\pipe\AmdMobilePower.RustGui.Worker.v1'
$process = Get-Process | Where-Object { $_.Path -eq $GuiPath } | Select-Object -First 1
if (-not $process) {
    Write-Log 'GUI not running; launching hidden tray session.'
    $process = Start-Process -FilePath $GuiPath `
        -ArgumentList '--tray --simple-mode --max-target-watts 45' `
        -WorkingDirectory (Split-Path -Parent $GuiPath) -WindowStyle Hidden -PassThru
}
try {
    $targetPid = $process.Id
    $window = [IntPtr]::Zero
    $deadline = (Get-Date).AddSeconds(15)
    do {
        $script:dayPolicyWindow = [IntPtr]::Zero
        $callback = [AmdDayPolicyUi+EnumProc] {
            param($hwnd, $parameter)
            $owner = 0
            [AmdDayPolicyUi]::GetWindowThreadProcessId($hwnd, [ref]$owner) | Out-Null
            if ($owner -eq $targetPid -and
                [AmdDayPolicyUi]::GetDlgItem($hwnd, 312) -ne [IntPtr]::Zero) {
                $script:dayPolicyWindow = $hwnd
            }
            return $true
        }
        [AmdDayPolicyUi]::EnumWindows($callback, [IntPtr]::Zero) | Out-Null
        $window = $script:dayPolicyWindow
        if ($window -eq [IntPtr]::Zero) { Start-Sleep -Milliseconds 200 }
    } while ($window -eq [IntPtr]::Zero -and (Get-Date) -lt $deadline)
    if ($window -eq [IntPtr]::Zero) { throw 'Policy window did not become available.' }

    [AmdDayPolicyUi]::SetText(
        [AmdDayPolicyUi]::GetDlgItem($window, 312),
        0x000C, [UIntPtr]::Zero, "$BatteryWatts") | Out-Null
    [AmdDayPolicyUi]::SetText(
        [AmdDayPolicyUi]::GetDlgItem($window, 314),
        0x000C, [UIntPtr]::Zero, "$AcWatts") | Out-Null
    [AmdDayPolicyUi]::Send(
        $window, 0x0111, [UIntPtr]::new([uint64]105), [IntPtr]::Zero) | Out-Null

    Start-Sleep -Seconds 2
    $raw = & $ProbePath --pipe-name $pipeName --command getPowerPolicy
    if ($LASTEXITCODE -ne 0) { throw 'Worker policy read-back failed.' }
    $settings = ($raw | ConvertFrom-Json).settings
    if (-not $settings.enabled -or
        $settings.batteryTarget.stapmWatts -ne $BatteryWatts -or
        $settings.batteryTarget.fastWatts -ne $BatteryWatts -or
        $settings.batteryTarget.slowWatts -ne $BatteryWatts -or
        $settings.acTarget.stapmWatts -ne $AcWatts -or
        $settings.acTarget.fastWatts -ne $AcWatts -or
        $settings.acTarget.slowWatts -ne $AcWatts) {
        throw "Day policy read-back mismatch: $raw"
    }
    Write-Log "PASS battery=$BatteryWatts ac=$AcWatts $raw"
} catch {
    Write-Log "FAIL $($_.Exception.Message)"
    throw
} finally {
    if ($process) { $process.Dispose() }
}
