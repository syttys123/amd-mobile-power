param(
    [Parameter(Mandatory = $true)]
    [string]$GuiExecutable,
    [string]$OutputDirectory,
    [string]$EvidencePath,
    [ValidateRange(10, 30)]
    [int]$Fps = 25,
    [ValidateRange(6, 15)]
    [double]$DurationSeconds = 8.5
)

$ErrorActionPreference = "Stop"
$repositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$artifactsRoot = [IO.Path]::GetFullPath((Join-Path $repositoryRoot "artifacts"))
if (-not $OutputDirectory) {
    $OutputDirectory = Join-Path $artifactsRoot "media\consent-flow"
}
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
if (-not $OutputDirectory.StartsWith(
    $artifactsRoot + [IO.Path]::DirectorySeparatorChar,
    [StringComparison]::OrdinalIgnoreCase)) {
    throw "Output must stay under artifacts: $OutputDirectory"
}
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$frameDirectory = Join-Path $OutputDirectory ("frames-" + [Guid]::NewGuid().ToString("N"))
$stateDirectory = Join-Path $artifactsRoot ("media\consent-state-" + [Guid]::NewGuid().ToString("N"))
$stateFileDirectory = Join-Path $stateDirectory "AmdMobilePower"
New-Item -ItemType Directory -Path $frameDirectory -Force | Out-Null
New-Item -ItemType Directory -Path $stateFileDirectory -Force | Out-Null
[IO.File]::WriteAllText(
    (Join-Path $stateFileDirectory "rust-ui-state.json"),
    '{"presets":[10,25,45],"mode":"simple","topMost":false}',
    [Text.UTF8Encoding]::new($false))

Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class AmdConsentFlowCapture {
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
    [DllImport("user32.dll")] public static extern IntPtr GetDlgItem(IntPtr hwnd, int id);
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr hwnd, out RECT rect);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);
    [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr hwnd, ref POINT point);
    [DllImport("user32.dll", SetLastError=true)] public static extern bool PrintWindow(IntPtr hwnd, IntPtr hdc, uint flags);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hwnd, uint msg, UIntPtr w, IntPtr l);
    [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr hwnd, uint msg, UIntPtr w, IntPtr l);
    [DllImport("user32.dll")] public static extern bool IsWindowEnabled(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hwnd);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern bool SetWindowText(IntPtr hwnd, string text);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr FindWindow(string cls, string title);
    public struct RECT { public int Left, Top, Right, Bottom; }
    public struct POINT { public int X, Y; }
}
"@
[void][AmdConsentFlowCapture]::SetProcessDpiAwarenessContext([IntPtr](-4))

function Get-ControlPoint {
    param([IntPtr]$Window, [int]$Id)
    $control = [AmdConsentFlowCapture]::GetDlgItem($Window, $Id)
    if ($control -eq [IntPtr]::Zero) { throw "Control $Id was not created." }
    $rect = New-Object AmdConsentFlowCapture+RECT
    [void][AmdConsentFlowCapture]::GetWindowRect($control, [ref]$rect)
    $origin = New-Object AmdConsentFlowCapture+POINT
    [void][AmdConsentFlowCapture]::ClientToScreen($Window, [ref]$origin)
    $client = New-Object AmdConsentFlowCapture+RECT
    [void][AmdConsentFlowCapture]::GetClientRect($Window, [ref]$client)
    return [pscustomobject]@{
        X = ((($rect.Left + $rect.Right) / 2.0) - $origin.X) / [Math]::Max(1, $client.Right)
        Y = ((($rect.Top + $rect.Bottom) / 2.0) - $origin.Y) / [Math]::Max(1, $client.Bottom)
        Enabled = [AmdConsentFlowCapture]::IsWindowEnabled($control)
    }
}

function Save-ClientFrame {
    param([IntPtr]$Window, [string]$Path)
    $rect = New-Object AmdConsentFlowCapture+RECT
    [void][AmdConsentFlowCapture]::GetClientRect($Window, [ref]$rect)
    $bitmap = New-Object Drawing.Bitmap ([Math]::Max(1, $rect.Right)), ([Math]::Max(1, $rect.Bottom))
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    try {
        $hdc = $graphics.GetHdc()
        try {
            if (-not [AmdConsentFlowCapture]::PrintWindow($Window, $hdc, 3)) {
                $errorNumber = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
                throw "PrintWindow failed for hwnd=$Window path=$Path win32=$errorNumber."
            }
        } finally { $graphics.ReleaseHdc($hdc) }
        $bitmap.Save($Path, [Drawing.Imaging.ImageFormat]::Png)
    } finally {
        $graphics.Dispose()
        $bitmap.Dispose()
    }
}

$previousLocalAppData = $env:LOCALAPPDATA
$process = $null
$window = [IntPtr]::Zero
$dialog = [IntPtr]::Zero
$events = @()
try {
    $env:LOCALAPPDATA = $stateDirectory
    $pipeName = "AmdMobilePower.ConsentFlow.$([Guid]::NewGuid().ToString('N'))"
    $process = Start-Process -FilePath $GuiExecutable `
        -WorkingDirectory (Split-Path -Parent $GuiExecutable) `
        -ArgumentList @("--ui-fixture", "preset-success", "--dpi-fixture", "125", "--pipe-name", $pipeName) `
        -PassThru
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    while ([DateTime]::UtcNow -lt $deadline -and $window -eq [IntPtr]::Zero) {
        $process.Refresh()
        if ($process.HasExited) { throw "Fixture GUI exited before creating its window." }
        $window = $process.MainWindowHandle
        Start-Sleep -Milliseconds 50
    }
    if ($window -eq [IntPtr]::Zero) { throw "Fixture GUI did not create a window." }
    if (-not [AmdConsentFlowCapture]::SetWindowText($window, "AMD Mobile Power")) {
        throw "Could not sanitize the isolated fixture title."
    }
    [void][AmdConsentFlowCapture]::SetForegroundWindow($window)
    Start-Sleep -Milliseconds 500
    [void][AmdConsentFlowCapture]::PostMessage($window, 0x0111, [UIntPtr]::new(111), [IntPtr]::Zero)
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    while ([DateTime]::UtcNow -lt $deadline -and $dialog -eq [IntPtr]::Zero) {
        $dialog = [AmdConsentFlowCapture]::FindWindow("AmdMobilePower.UnlockConsent.v1", "启用写入之前")
        Start-Sleep -Milliseconds 50
    }
    if ($dialog -eq [IntPtr]::Zero) { throw "Consent dialog did not open." }
    $initialConfirm = Get-ControlPoint -Window $dialog -Id 402
    if ($initialConfirm.Enabled) { throw "Confirm must start disabled." }
    [void][AmdConsentFlowCapture]::SetForegroundWindow($dialog)

    $timeline = @(
        @{ At = 2.0; Action = "check"; Control = 401 },
        @{ At = 5.0; Action = "confirm"; Control = 402 }
    )
    foreach ($step in $timeline) {
        $point = Get-ControlPoint -Window $dialog -Id $step.Control
        $step.ClickX = $point.X
        $step.ClickY = $point.Y
    }
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $frames = [Collections.Generic.List[object]]::new()
    $nextFrameAt = 0.0
    $frameIndex = 0
    $checkedSeen = $false
    $unlockedSeen = $false
    $dialogClosedAt = $null
    while ($watch.Elapsed.TotalSeconds -lt $DurationSeconds) {
        $elapsed = $watch.Elapsed.TotalSeconds
        foreach ($step in $timeline) {
            if (-not $step.ContainsKey("Done") -and $elapsed -ge $step.At) {
                if ($step.Action -eq "confirm") {
                    $confirm = Get-ControlPoint -Window $dialog -Id 402
                    if (-not $confirm.Enabled) { throw "Confirm did not enable after consent." }
                }
                $control = [AmdConsentFlowCapture]::GetDlgItem($dialog, [int]$step.Control)
                if ($step.Action -eq "check") {
                    # A real auto-checkbox click changes its check state and
                    # notifies the parent. BM_CLICK exercises that path;
                    # BM_SETCHECK alone would leave the confirm button disabled.
                    [void][AmdConsentFlowCapture]::SendMessage(
                        $control, 0x00F5, [UIntPtr]::Zero, [IntPtr]::Zero)
                } else {
                    [void][AmdConsentFlowCapture]::PostMessage(
                        $dialog, 0x0111, [UIntPtr]::new([uint32]$step.Control), [IntPtr]::Zero)
                }
                $step.Done = $true
                $step.ActualAt = $elapsed
            }
        }
        if ($elapsed -ge $nextFrameAt) {
            $confirmHandle = if ($dialog -ne [IntPtr]::Zero) {
                [AmdConsentFlowCapture]::GetDlgItem($dialog, 402)
            } else { [IntPtr]::Zero }
            $dialogAlive = ($dialog -ne [IntPtr]::Zero -and
                [AmdConsentFlowCapture]::IsWindow($dialog) -and
                $confirmHandle -ne [IntPtr]::Zero -and
                [AmdConsentFlowCapture]::IsWindow($confirmHandle))
            if (-not $dialogAlive -and $null -eq $dialogClosedAt) {
                $dialogClosedAt = $elapsed
            }
            # The modal disables its parent while alive. Switch surfaces only
            # after Windows re-enables the main window; IsWindow alone can lag
            # behind DestroyWindow and make PrintWindow race modal teardown.
            $mainEnabled = [AmdConsentFlowCapture]::IsWindowEnabled($window)
            $captureWindow = if ($dialogAlive -and -not $mainEnabled -and
                -not $timeline[1].ContainsKey("Done")) {
                $dialog
            } else {
                $window
            }
            $path = Join-Path $frameDirectory ("frame-{0:d4}.png" -f $frameIndex)
            Save-ClientFrame -Window $captureWindow -Path $path
            $frames.Add([pscustomobject]@{
                Index = $frameIndex; At = $elapsed
                Path = [IO.Path]::GetFileName($path)
                Surface = if ($captureWindow -eq $dialog) { "consent" } else { "main" }
            })
            if ($captureWindow -eq $dialog -and $dialogAlive) {
                $confirm = Get-ControlPoint -Window $dialog -Id 402
                if ($confirm.Enabled -and -not $checkedSeen) {
                    $checkedSeen = $true
                    $timeline[0].VisualFrameIndex = $frameIndex
                    $timeline[0].VisualAt = $elapsed
                }
            } elseif ($captureWindow -eq $window -and -not $unlockedSeen) {
                $apply = Get-ControlPoint -Window $window -Id 317
                if ($apply.Enabled) {
                    $unlockedSeen = $true
                    $timeline[1].VisualFrameIndex = $frameIndex
                    $timeline[1].VisualAt = $elapsed
                }
            }
            $frameIndex++
            $nextFrameAt += 1.0 / $Fps
        }
        Start-Sleep -Milliseconds 15
    }
    if (-not $checkedSeen -or -not $unlockedSeen) {
        throw "Consent flow did not produce both visible completion states."
    }
    $manifest = [ordered]@{
        SchemaVersion = 1
        SimulatedData = $true
        HardwareAccess = $false
        Fixture = "preset-success"
        Flow = "consent-unlock"
        GuiSha256 = (Get-FileHash -LiteralPath $GuiExecutable -Algorithm SHA256).Hash.ToLowerInvariant()
        DurationSeconds = $DurationSeconds
        RequestedFps = $Fps
        FrameCount = $frames.Count
        FrameDirectory = $frameDirectory
        Frames = @($frames)
        Events = @($timeline | ForEach-Object {
            [ordered]@{
                Action = $_.Action; Control = $_.Control; ScheduledAt = $_.At
                ActualAt = $_.ActualAt; Completed = [bool]$_.Done
                VisualFrameIndex = $_.VisualFrameIndex; VisualAt = $_.VisualAt
                ClickX = $_.ClickX; ClickY = $_.ClickY
            }
        })
        RecordedAt = (Get-Date).ToString("o")
    }
    if (-not $EvidencePath) {
        $EvidencePath = Join-Path $OutputDirectory "flow-manifest.json"
    }
    [IO.File]::WriteAllText($EvidencePath, ($manifest | ConvertTo-Json -Depth 8),
        [Text.UTF8Encoding]::new($false))
    $manifest | ConvertTo-Json -Depth 8
} finally {
    if ($dialog -ne [IntPtr]::Zero -and [AmdConsentFlowCapture]::IsWindow($dialog)) {
        [void][AmdConsentFlowCapture]::PostMessage($dialog, 0x0010, [UIntPtr]::Zero, [IntPtr]::Zero)
    }
    if ($window -ne [IntPtr]::Zero) {
        [void][AmdConsentFlowCapture]::PostMessage($window, 0x0111, [UIntPtr]::new(2), [IntPtr]::Zero)
    }
    if ($process) {
        try {
            if (-not $process.WaitForExit(5000)) {
                $process.Kill($true)
                [void]$process.WaitForExit(5000)
            }
        } finally { $process.Dispose() }
    }
    $env:LOCALAPPDATA = $previousLocalAppData
    if ($stateDirectory.StartsWith(
        $artifactsRoot + [IO.Path]::DirectorySeparatorChar,
        [StringComparison]::OrdinalIgnoreCase) -and
        (Test-Path -LiteralPath $stateDirectory)) {
        Remove-Item -LiteralPath $stateDirectory -Recurse -Force
    }
}
