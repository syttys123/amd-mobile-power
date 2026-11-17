param(
    [ValidateRange(5, 60)][int]$BatteryWatts = 10,
    [ValidateRange(5, 60)][int]$AcWatts = 45,
    [string]$StatePath = (Join-Path $env:LOCALAPPDATA 'AmdMobilePower\rust-ui-state.json'),
    [string]$PipeName = '\\.\pipe\AmdMobilePower.RustGui.Worker.v1',
    [string]$GuiPath = 'C:\RyzenAdj\amd-mobile-power-gui.exe',
    [string]$LogPath
)
$ErrorActionPreference = 'Stop'
if (-not $LogPath) { $LogPath = Join-Path $PSScriptRoot 'apply-power-policy-direct.log' }
function Write-Log([string]$Message) {
    "{0:o} {1}" -f (Get-Date), $Message |
        Add-Content -LiteralPath $LogPath -Encoding UTF8
}
function Invoke-WorkerRequest([string]$Command, $Payload) {
    $plainName = $PipeName -replace '^\\\\\.\\pipe\\', ''
    $client = [System.IO.Pipes.NamedPipeClientStream]::new(
        '.', $plainName, [System.IO.Pipes.PipeDirection]::InOut,
        [System.IO.Pipes.PipeOptions]::Asynchronous)
    try {
        $client.Connect(4000)
        $requestId = 'maintenance-' + [guid]::NewGuid().ToString('N')
        $request = [ordered]@{
            protocolVersion = 1
            requestId = $requestId
            command = $Command
            payload = $Payload
        }
        $bytes = [Text.Encoding]::UTF8.GetBytes(
            ($request | ConvertTo-Json -Compress -Depth 10) + "`n")
        $writeTask = $client.WriteAsync($bytes, 0, $bytes.Length)
        if (-not $writeTask.Wait(8000)) {
            throw "Worker write timed out for $Command."
        }
        $flushTask = $client.FlushAsync()
        if (-not $flushTask.Wait(8000)) {
            throw "Worker flush timed out for $Command."
        }
        $reader = [IO.StreamReader]::new($client, [Text.Encoding]::UTF8, $false, 1024, $true)
        try {
            # NamedPipeClientStream rejects ReadTimeout, so bound the read with
            # ReadLineAsync + Wait; a hung worker must not stall maintenance.
            $readTask = $reader.ReadLineAsync()
            if (-not $readTask.Wait(8000)) {
                throw "Worker did not answer $Command within 8 seconds."
            }
            $line = $readTask.Result
        } finally { $reader.Dispose() }
        if (-not $line) { throw "Worker closed pipe during $Command." }
        $response = $line | ConvertFrom-Json
        if ($response.protocolVersion -ne 1 -or $response.requestId -ne $requestId) {
            throw "Worker response identity mismatch during $Command."
        }
        if (-not $response.success) {
            throw "Worker $Command failed: $($response.error.code) $($response.error.message)"
        }
        return $response.payload
    } finally { $client.Dispose() }
}
function Invoke-WorkerRequestWithRetry([string]$Command, $Payload, [int]$Attempts = 6) {
    $lastError = $null
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        try {
            return Invoke-WorkerRequest $Command $Payload
        }
        catch {
            $lastError = $_.Exception.Message
            if ($attempt -eq $Attempts) { break }
            Start-Sleep -Milliseconds (250 * $attempt)
        }
    }
    throw "Worker $Command failed after $Attempts attempts: $lastError"
}
function Test-PolicySettingsMatch($Settings, [int]$BatteryTarget, [int]$AcTarget) {
    if (-not $Settings) { return $false }
    if ($Settings.enabled -ne $true -or
        $Settings.batteryEnabled -ne $true -or
        $Settings.acEnabled -ne $true) { return $false }
    $battery = $Settings.batteryTarget
    $ac = $Settings.acTarget
    if (-not $battery -or -not $ac) { return $false }
    return ($battery.stapmWatts -eq $BatteryTarget -and
        $battery.fastWatts -eq $BatteryTarget -and
        $battery.slowWatts -eq $BatteryTarget -and
        $ac.stapmWatts -eq $AcTarget -and
        $ac.fastWatts -eq $AcTarget -and
        $ac.slowWatts -eq $AcTarget)
}
function Wait-PolicyTelemetry([int]$BatteryTarget, [int]$AcTarget) {
    $deadline = (Get-Date).AddSeconds(12)
    $last = $null
    while ((Get-Date) -lt $deadline) {
        $snapshot = Invoke-WorkerRequestWithRetry 'getSnapshot' $null
        $telemetry = $snapshot.telemetry
        $last = $telemetry
        $expected = if ($telemetry.powerLine -eq 'ac') { $AcTarget } else { $BatteryTarget }
        if ([Math]::Abs([double]$telemetry.fastLimitWatts - $expected) -le 1.0 -and
            [Math]::Abs([double]$telemetry.slowLimitWatts - $expected) -le 1.0) {
            return $telemetry
        }
        Start-Sleep -Milliseconds 300
    }
    $line = if ($last) { $last.powerLine } else { 'unknown' }
    $fast = if ($last) { $last.fastLimitWatts } else { '--' }
    $slow = if ($last) { $last.slowLimitWatts } else { '--' }
    throw "Telemetry read-back mismatch on ${line}: Fast/Slow ${fast}/${slow} W."
}
function Wait-PolicyApplied([int]$BatteryTarget, [int]$AcTarget) {
    $deadline = (Get-Date).AddSeconds(12)
    $last = $null
    while ((Get-Date) -lt $deadline) {
        $state = Invoke-WorkerRequestWithRetry 'getPowerPolicy' $null
        $last = $state
        $line = $state.lastObservedPowerLine
        $applied = $state.lastAppliedTarget
        if ($state.lastAttemptSucceeded -eq $true -and $line -and $applied -and
            (Test-PolicySettingsMatch $state.settings $BatteryTarget $AcTarget)) {
            $expected = if ($line -eq 'ac') { $AcTarget } else { $BatteryTarget }
            if ($applied.stapmWatts -eq $expected -and
                $applied.fastWatts -eq $expected -and
                $applied.slowWatts -eq $expected) {
                return
            }
        }
        Start-Sleep -Milliseconds 300
    }
    $line = if ($last) { $last.lastObservedPowerLine } else { 'unknown' }
    throw "Worker did not confirm applied policy on ${line} within 12 seconds."
}
function Update-UiStatePolicy([string]$Path, $Settings) {
    # The GUI persists the same file with atomic tmp+rename writes. Share the
    # cross-process lock (identical name on the Rust side) so the read-modify-
    # write cannot lose a concurrent GUI update.
    $mutex = [System.Threading.Mutex]::new($false, 'Local\AmdMobilePower.UiState.v1')
    $acquired = $false
    try {
        try { $acquired = $mutex.WaitOne(5000) }
        catch [System.Threading.AbandonedMutexException] { $acquired = $true }
        if (-not $acquired) {
            throw 'Timed out waiting for Local\AmdMobilePower.UiState.v1 after 5 seconds.'
        }
        $ui = $null
        if (Test-Path -LiteralPath $Path) {
            try { $ui = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json }
            catch {
                # Mirror state.rs: keep the damaged file for diagnostics and
                # rebuild from defaults instead of failing the policy run.
                Copy-Item -LiteralPath $Path -Destination ($Path + '.corrupt.bak') -Force
                $ui = $null
            }
        }
        if (-not $ui) { $ui = [pscustomobject]@{} }
        # Plain assignment silently no-ops when powerPolicy is absent.
        $ui | Add-Member -NotePropertyName 'powerPolicy' -NotePropertyValue ([pscustomobject]$Settings) -Force
        $directory = Split-Path -Parent $Path
        if ($directory -and -not (Test-Path -LiteralPath $directory)) {
            New-Item -ItemType Directory -Path $directory -Force | Out-Null
        }
        $temporary = $Path + '.maintenance.tmp'
        [IO.File]::WriteAllText(
            $temporary,
            ($ui | ConvertTo-Json -Depth 10),
            [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temporary -Destination $Path -Force
    }
    finally {
        if ($acquired) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}
function Sync-GuiPolicy([int]$BatteryTarget, [int]$AcTarget, $Settings) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class AmdDirectPolicyUi {
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
    $process = Get-Process | Where-Object { $_.Path -eq $GuiPath } | Select-Object -First 1
    if (-not $process) { return $false }
    try {
        $targetPid = $process.Id
        $script:syncWindow = [IntPtr]::Zero
        $callback = [AmdDirectPolicyUi+EnumProc] {
            param($hwnd, $parameter)
            $owner = 0
            [AmdDirectPolicyUi]::GetWindowThreadProcessId($hwnd, [ref]$owner) | Out-Null
            if ($owner -eq $targetPid -and
                [AmdDirectPolicyUi]::GetDlgItem($hwnd, 312) -ne [IntPtr]::Zero) {
                $script:syncWindow = $hwnd
            }
            return $true
        }
        [AmdDirectPolicyUi]::EnumWindows($callback, [IntPtr]::Zero) | Out-Null
        if ($script:syncWindow -eq [IntPtr]::Zero) { return $false }
        $window = $script:syncWindow
        $batteryEdit = [AmdDirectPolicyUi]::GetDlgItem($window, 312)
        $acEdit = [AmdDirectPolicyUi]::GetDlgItem($window, 314)
        $enabledToggle = [AmdDirectPolicyUi]::GetDlgItem($window, 315)
        $batteryOnlyToggle = [AmdDirectPolicyUi]::GetDlgItem($window, 318)

        # POLICY_ENABLED (315) and POLICY_BATTERY_ONLY (318) are BS_OWNERDRAW
        # toggles painted from GUI memory. BM_GETCHECK always returns 0 for
        # them (verified against a synthetic owner-draw button), so the only
        # reliable state probe is the settings the GUI actually saves; BM_CLICK
        # still delivers BN_CLICKED and flips the GUI bools. The leading zero
        # on the battery edit is a save-landed marker: only POLICY_SAVE rewrites
        # that edit, normalizing the parsed integer.
        $marker = '0' + $BatteryTarget
        $observed = $null
        for ($attempt = 1; $attempt -le 2; $attempt++) {
            [AmdDirectPolicyUi]::SetText($batteryEdit, 0x000C, [UIntPtr]::Zero, $marker) | Out-Null
            [AmdDirectPolicyUi]::SetText($acEdit, 0x000C, [UIntPtr]::Zero, "$AcTarget") | Out-Null
            [AmdDirectPolicyUi]::Send(
                $window, 0x0111, [UIntPtr]::new([uint64]105), [IntPtr]::Zero) | Out-Null

            $landed = $false
            $deadline = (Get-Date).AddSeconds(10)
            while ((Get-Date) -lt $deadline) {
                $buffer = [System.Text.StringBuilder]::new(64)
                [AmdDirectPolicyUi]::GetText($batteryEdit, 0x000D, [UIntPtr]::new([uint64]64), $buffer) | Out-Null
                $landed = $buffer.ToString() -ne $marker
                $observed = Invoke-WorkerRequestWithRetry 'getPowerPolicy' $null
                if ($landed) { break }
                Start-Sleep -Milliseconds 200
            }
            if ($landed -and
                (Test-PolicySettingsMatch $observed.settings $BatteryTarget $AcTarget)) {
                return $true
            }
            if (-not $landed) {
                # POLICY_SAVE never executed (write controls locked, or a save
                # already in flight). A locked GUI cannot overwrite the worker
                # policy through the save button; restore the clean edit text
                # and confirm the worker still holds the requested policy.
                [AmdDirectPolicyUi]::SetText($batteryEdit, 0x000C, [UIntPtr]::Zero, "$BatteryTarget") | Out-Null
                $still = Invoke-WorkerRequestWithRetry 'getPowerPolicy' $null
                if (Test-PolicySettingsMatch $still.settings $BatteryTarget $AcTarget) { return $true }
                break
            }
            if ($attempt -eq 2) { break }
            # The save landed with the GUI's stale in-memory flags. Correct the
            # toggles toward enabled=true / batteryOnly=false using what the
            # GUI actually saved, then save again.
            if ($observed.settings) {
                if ($observed.settings.enabled -ne $true -and $enabledToggle -ne [IntPtr]::Zero) {
                    [AmdDirectPolicyUi]::Send($enabledToggle, 0x00F5, [UIntPtr]::Zero, [IntPtr]::Zero) | Out-Null
                }
                if ($observed.settings.acEnabled -ne $true -and $batteryOnlyToggle -ne [IntPtr]::Zero) {
                    [AmdDirectPolicyUi]::Send($batteryOnlyToggle, 0x00F5, [UIntPtr]::Zero, [IntPtr]::Zero) | Out-Null
                }
            }
        }
        # Verification failed after the retry: put the worker back on the
        # requested policy so a bad GUI save cannot stick, then report FAIL.
        [AmdDirectPolicyUi]::SetText($batteryEdit, 0x000C, [UIntPtr]::Zero, "$BatteryTarget") | Out-Null
        $null = Invoke-WorkerRequestWithRetry 'setPowerPolicy' @{ settings = $Settings }
        $recheck = Invoke-WorkerRequestWithRetry 'getPowerPolicy' $null
        if (-not (Test-PolicySettingsMatch $recheck.settings $BatteryTarget $AcTarget)) {
            throw 'GUI policy sync failed and the worker policy could not be re-asserted.'
        }
        $observedJson = if ($observed -and $observed.settings) {
            $observed.settings | ConvertTo-Json -Compress -Depth 6
        } else { 'none' }
        throw "GUI policy sync verification failed after retry; worker policy re-asserted. Observed: $observedJson"
    } finally { $process.Dispose() }
}

$target = [ordered]@{
    stapmWatts = $BatteryWatts
    fastWatts = $BatteryWatts
    slowWatts = $BatteryWatts
}
$acTarget = [ordered]@{
    stapmWatts = $AcWatts
    fastWatts = $AcWatts
    slowWatts = $AcWatts
}
$settings = [ordered]@{
    enabled = $true
    batteryEnabled = $true
    acEnabled = $true
    batteryTarget = $target
    acTarget = $acTarget
}
try {
    $null = Invoke-WorkerRequestWithRetry 'setPowerPolicy' @{ settings = $settings }
    $verified = (Invoke-WorkerRequestWithRetry 'getPowerPolicy' $null).settings
    if (-not (Test-PolicySettingsMatch $verified $BatteryWatts $AcWatts)) {
        throw 'Worker policy read-back mismatch.'
    }
    Wait-PolicyApplied -BatteryTarget $BatteryWatts -AcTarget $AcWatts
    $telemetry = Wait-PolicyTelemetry -BatteryTarget $BatteryWatts -AcTarget $AcWatts

    Update-UiStatePolicy -Path $StatePath -Settings $settings
    $guiSynced = Sync-GuiPolicy -BatteryTarget $BatteryWatts -AcTarget $AcWatts -Settings $settings
    # Independent final read-back: never trust guiSynced alone.
    $final = Invoke-WorkerRequestWithRetry 'getPowerPolicy' $null
    if (-not (Test-PolicySettingsMatch $final.settings $BatteryWatts $AcWatts)) {
        throw 'Final worker policy read-back mismatch after GUI sync.'
    }
    $message = "PASS battery={0} ac={1} forcedWrite=True guiSynced={2} line={3} fastSlow={4}/{5}" -f `
        $BatteryWatts, $AcWatts, $guiSynced,
        $telemetry.powerLine, $telemetry.fastLimitWatts, $telemetry.slowLimitWatts
    Write-Log $message
} catch {
    Write-Log "FAIL battery=$BatteryWatts ac=$AcWatts $($_.Exception.Message)"
    throw
}
