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
    $state = Invoke-WorkerRequest 'getPowerPolicy' $null
    $current = $state.settings
    $alreadyApplied = $current -and $current.enabled -and
        $current.batteryTarget.stapmWatts -eq $BatteryWatts -and
        $current.batteryTarget.fastWatts -eq $BatteryWatts -and
        $current.batteryTarget.slowWatts -eq $BatteryWatts -and
        $current.acTarget.stapmWatts -eq $AcWatts -and
        $current.acTarget.fastWatts -eq $AcWatts -and
        $current.acTarget.slowWatts -eq $AcWatts
    if (-not $alreadyApplied) {
        $null = Invoke-WorkerRequest 'setPowerPolicy' @{ settings = $settings }
    }
    $verified = (Invoke-WorkerRequest 'getPowerPolicy' $null).settings
    if (-not $verified.enabled -or
        $verified.batteryTarget.stapmWatts -ne $BatteryWatts -or
        $verified.batteryTarget.fastWatts -ne $BatteryWatts -or
        $verified.batteryTarget.slowWatts -ne $BatteryWatts -or
        $verified.acTarget.stapmWatts -ne $AcWatts -or
        $verified.acTarget.fastWatts -ne $AcWatts -or
        $verified.acTarget.slowWatts -ne $AcWatts) {
        throw 'Worker policy read-back mismatch.'
    }

    $ui = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
    $ui.powerPolicy = [pscustomobject]$settings
    $temporary = $StatePath + '.maintenance.tmp'
    [IO.File]::WriteAllText(
        $temporary,
        ($ui | ConvertTo-Json -Depth 10),
        [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporary -Destination $StatePath -Force
    $guiSynced = Sync-GuiPolicy
    Write-Log "PASS battery=$BatteryWatts ac=$AcWatts skippedWrite=$alreadyApplied guiSynced=$guiSynced"
} catch {
    Write-Log "FAIL battery=$BatteryWatts ac=$AcWatts $($_.Exception.Message)"
    throw
}
