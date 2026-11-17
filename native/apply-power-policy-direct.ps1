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
        $client.Write($bytes, 0, $bytes.Length)
        $client.Flush()
        $reader = [IO.StreamReader]::new($client, [Text.Encoding]::UTF8, $false, 1024, $true)
        try { $line = $reader.ReadLine() } finally { $reader.Dispose() }
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
        if ($state.lastAttemptSucceeded -eq $true -and $line -and $applied) {
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
function Sync-GuiPolicy {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class AmdDirectPolicyUi {
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
        [AmdDirectPolicyUi]::SetText(
            [AmdDirectPolicyUi]::GetDlgItem($script:syncWindow, 312),
            0x000C, [UIntPtr]::Zero, "$BatteryWatts") | Out-Null
        [AmdDirectPolicyUi]::SetText(
            [AmdDirectPolicyUi]::GetDlgItem($script:syncWindow, 314),
            0x000C, [UIntPtr]::Zero, "$AcWatts") | Out-Null
        [AmdDirectPolicyUi]::Send(
            $script:syncWindow, 0x0111, [UIntPtr]::new([uint64]105),
            [IntPtr]::Zero) | Out-Null
        return $true
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
    if (-not $verified.enabled -or
        $verified.batteryTarget.stapmWatts -ne $BatteryWatts -or
        $verified.batteryTarget.fastWatts -ne $BatteryWatts -or
        $verified.batteryTarget.slowWatts -ne $BatteryWatts -or
        $verified.acTarget.stapmWatts -ne $AcWatts -or
        $verified.acTarget.fastWatts -ne $AcWatts -or
        $verified.acTarget.slowWatts -ne $AcWatts) {
        throw 'Worker policy read-back mismatch.'
    }
    Wait-PolicyApplied -BatteryTarget $BatteryWatts -AcTarget $AcWatts
    $telemetry = Wait-PolicyTelemetry -BatteryTarget $BatteryWatts -AcTarget $AcWatts

    $ui = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
    $ui.powerPolicy = [pscustomobject]$settings
    $temporary = $StatePath + '.maintenance.tmp'
    [IO.File]::WriteAllText(
        $temporary,
        ($ui | ConvertTo-Json -Depth 10),
        [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporary -Destination $StatePath -Force
    $guiSynced = Sync-GuiPolicy
    $message = "PASS battery={0} ac={1} forcedWrite=True guiSynced={2} line={3} fastSlow={4}/{5}" -f `
        $BatteryWatts, $AcWatts, $guiSynced,
        $telemetry.powerLine, $telemetry.fastLimitWatts, $telemetry.slowLimitWatts
    Write-Log $message
} catch {
    Write-Log "FAIL battery=$BatteryWatts ac=$AcWatts $($_.Exception.Message)"
    throw
}
