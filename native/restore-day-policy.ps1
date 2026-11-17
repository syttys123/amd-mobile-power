param(
    [ValidateRange(5, 60)][int]$BatteryWatts = 10,
    [ValidateRange(5, 60)][int]$AcWatts = 45,
    [string]$GuiPath = 'C:\RyzenAdj\amd-mobile-power-gui.exe',
    [string]$ProbePath = 'C:\RyzenAdj\amd-mobile-power-probe.exe',
    [string]$PipeName = '\\.\pipe\AmdMobilePower.RustGui.Worker.v1',
    [string]$LogPath
)
$ErrorActionPreference = 'Stop'
if (-not $LogPath) { $LogPath = Join-Path $PSScriptRoot 'restore-day-policy.log' }
. (Join-Path $PSScriptRoot 'worker-client.ps1')
function Write-Log([string]$Message) {
    "{0:o} {1}" -f (Get-Date), $Message |
        Add-Content -LiteralPath $LogPath -Encoding UTF8
}

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class AmdDayPolicyUi {
    public delegate bool EnumProc(IntPtr hwnd, IntPtr parameter);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc callback, IntPtr parameter);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint processId);
    [DllImport("user32.dll")] public static extern IntPtr GetDlgItem(IntPtr hwnd, int id);
    // Cross-process GetWindowTextW returns the cached creation text of an edit,
    // not its live content; WM_GETTEXT via SendMessage reads the real value.
    [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "SendMessageW")]
    public static extern IntPtr GetText(IntPtr hwnd, uint message, UIntPtr wParam, StringBuilder text);
    [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "SendMessageW")]
    public static extern IntPtr SetText(IntPtr hwnd, uint message, UIntPtr wParam, string text);
    [DllImport("user32.dll", EntryPoint = "SendMessageW")]
    public static extern IntPtr Send(IntPtr hwnd, uint message, UIntPtr wParam, IntPtr lParam);
}
'@

$pipeName = $PipeName

function Read-PolicyViaPipe {
    $result = Invoke-WorkerPipeRequest -PipeName $pipeName -Command 'getPowerPolicy' `
        -ConnectTimeoutMilliseconds 4000 -ReadTimeoutMilliseconds 8000
    if (-not $result.Success) { throw "Worker getPowerPolicy failed: $($result.ErrorText)" }
    return $result.Payload
}
function Test-DayPolicyMatch($State, [int]$BatteryTarget, [int]$AcTarget) {
    $settings = $State.settings
    if (-not $settings) { return $false }
    if ($settings.enabled -ne $true -or
        $settings.batteryEnabled -ne $true -or
        $settings.acEnabled -ne $true) { return $false }
    $battery = $settings.batteryTarget
    $ac = $settings.acTarget
    if (-not $battery -or -not $ac) { return $false }
    if ($battery.stapmWatts -ne $BatteryTarget -or
        $battery.fastWatts -ne $BatteryTarget -or
        $battery.slowWatts -ne $BatteryTarget -or
        $ac.stapmWatts -ne $AcTarget -or
        $ac.fastWatts -ne $AcTarget -or
        $ac.slowWatts -ne $AcTarget) { return $false }
    # Require the worker to confirm it actually applied the target, not just
    # that the settings were stored.
    if ($State.lastAttemptSucceeded -ne $true) { return $false }
    $line = $State.lastObservedPowerLine
    $applied = $State.lastAppliedTarget
    if (-not $line -or -not $applied) { return $false }
    $expected = if ($line -eq 'ac') { $AcTarget } else { $BatteryTarget }
    return ($applied.stapmWatts -eq $expected -and
        $applied.fastWatts -eq $expected -and
        $applied.slowWatts -eq $expected)
}

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

    $batteryEdit = [AmdDayPolicyUi]::GetDlgItem($window, 312)
    $acEdit = [AmdDayPolicyUi]::GetDlgItem($window, 314)
    $enabledToggle = [AmdDayPolicyUi]::GetDlgItem($window, 315)
    $batteryOnlyToggle = [AmdDayPolicyUi]::GetDlgItem($window, 318)

    # POLICY_ENABLED (315) / POLICY_BATTERY_ONLY (318) are BS_OWNERDRAW toggles
    # painted from GUI memory, so BM_GETCHECK always reads 0 and cannot gate a
    # click. Instead converge on the worker read-back: save, inspect the flags
    # the GUI actually persisted, BM_CLICK only the toggles that are wrong, and
    # save again. The leading zero on the battery edit is a save-landed marker
    # (POLICY_SAVE rewrites the edit with the normalized integer).
    $marker = '0' + $BatteryWatts
    $verified = $false
    $lastState = $null
    for ($attempt = 1; $attempt -le 2 -and -not $verified; $attempt++) {
        [AmdDayPolicyUi]::SetText($batteryEdit, 0x000C, [UIntPtr]::Zero, $marker) | Out-Null
        [AmdDayPolicyUi]::SetText($acEdit, 0x000C, [UIntPtr]::Zero, "$AcWatts") | Out-Null
        [AmdDayPolicyUi]::Send(
            $window, 0x0111, [UIntPtr]::new([uint64]105), [IntPtr]::Zero) | Out-Null

        $landed = $false
        $deadline = (Get-Date).AddSeconds(12)
        while ((Get-Date) -lt $deadline) {
            $buffer = [System.Text.StringBuilder]::new(64)
            [AmdDayPolicyUi]::GetText($batteryEdit, 0x000D, [UIntPtr]::new([uint64]64), $buffer) | Out-Null
            $landed = $buffer.ToString() -ne $marker
            $lastState = Read-PolicyViaPipe
            if ($landed -and (Test-DayPolicyMatch $lastState $BatteryWatts $AcWatts)) {
                $verified = $true
                break
            }
            Start-Sleep -Milliseconds 300
        }
        if ($verified) { break }
        if (-not $landed) {
            throw 'GUI did not execute POLICY_SAVE (write controls may be locked).'
        }
        # The save landed but the persisted flags/targets are wrong. Correct
        # only the toggles that disagree with the desired enabled/AC state.
        $settings = $lastState.settings
        if ($settings) {
            if ($settings.enabled -ne $true -and $enabledToggle -ne [IntPtr]::Zero) {
                [AmdDayPolicyUi]::Send($enabledToggle, 0x00F5, [UIntPtr]::Zero, [IntPtr]::Zero) | Out-Null
            }
            if ($settings.acEnabled -ne $true -and $batteryOnlyToggle -ne [IntPtr]::Zero) {
                [AmdDayPolicyUi]::Send($batteryOnlyToggle, 0x00F5, [UIntPtr]::Zero, [IntPtr]::Zero) | Out-Null
            }
        }
    }
    if (-not $verified) {
        $observedJson = if ($lastState -and $lastState.settings) {
            $lastState.settings | ConvertTo-Json -Compress -Depth 6
        } else { 'none' }
        throw "Day policy read-back mismatch after retry. Observed: $observedJson"
    }

    # Independent confirmation through the probe binary (separate code path).
    $probe = Invoke-ProbeProcess -ProbePath $ProbePath -PipePath $pipeName -Command 'getPowerPolicy'
    if ($probe.ExitCode -ne 0) { throw "Worker policy probe read-back failed: $($probe.Output)" }
    $probeSettings = ($probe.Output | ConvertFrom-Json).settings
    if (-not $probeSettings.enabled -or
        $probeSettings.batteryEnabled -ne $true -or
        $probeSettings.acEnabled -ne $true -or
        $probeSettings.batteryTarget.stapmWatts -ne $BatteryWatts -or
        $probeSettings.batteryTarget.fastWatts -ne $BatteryWatts -or
        $probeSettings.batteryTarget.slowWatts -ne $BatteryWatts -or
        $probeSettings.acTarget.stapmWatts -ne $AcWatts -or
        $probeSettings.acTarget.fastWatts -ne $AcWatts -or
        $probeSettings.acTarget.slowWatts -ne $AcWatts) {
        throw "Day policy probe read-back mismatch: $($probe.Output)"
    }
    Write-Log "PASS battery=$BatteryWatts ac=$AcWatts $($probe.Output)"
} catch {
    Write-Log "FAIL $($_.Exception.Message)"
    throw
} finally {
    if ($process) { $process.Dispose() }
}
