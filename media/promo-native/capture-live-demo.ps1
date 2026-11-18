param(
    [Parameter(Mandatory = $true)]
    [string]$GuiExecutable,
    [string]$OutputDirectory,
    [string]$ClipPath,
    [ValidateSet("firmware-clamp", "preset-success")]
    [string]$UiFixture = "firmware-clamp",
    [int]$DpiFixture = 125,
    [ValidateSet("advanced", "simple")]
    [string]$Mode = "advanced",
    [ValidateRange(10, 60)]
    [double]$DurationSeconds = 13.5,
    [ValidateRange(1, 30)]
    [int]$Fps = 25,
    [ValidateSet("auto", "legacy", "presets", "policy")]
    [string]$DemoType = "auto",
    [ValidateRange(0.25, 10.0)]
    [double]$VisualChangeTimeoutSeconds = 3.0,
    [ValidateRange(1, 16)]
    [int]$VisualSampleStep = 2,
    [ValidateRange(1, 100000)]
    [int]$VisualChangeMinPixels = 24,
    [switch]$ContractOnly
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent (
    Split-Path -Parent (Split-Path -Parent $PSCommandPath))
$artifactsRoot = [System.IO.Path]::GetFullPath((Join-Path $root "artifacts"))

Add-Type -AssemblyName System.Drawing
if (-not ("AmdMobilePowerLiveDemo" -as [type])) {
    Add-Type @"
using System;
using System.Runtime.InteropServices;

public static class AmdMobilePowerLiveDemo {
    [DllImport("user32.dll")]
    public static extern bool SetProcessDpiAwarenessContext(IntPtr value);

    [DllImport("user32.dll")]
    public static extern bool GetClientRect(IntPtr hwnd, out RECT rect);

    [DllImport("user32.dll")]
    public static extern bool PrintWindow(IntPtr hwnd, IntPtr hdc, uint flags);

    [DllImport("user32.dll")]
    public static extern IntPtr SendMessage(
        IntPtr hwnd, uint message, UIntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "SendMessageW")]
    public static extern IntPtr SendMessageText(
        IntPtr hwnd, uint message, UIntPtr wParam, string lParam);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern bool SetWindowTextW(IntPtr hwnd, string text);

    [DllImport("user32.dll")]
    public static extern IntPtr GetDlgItem(IntPtr hwnd, int id);

    [DllImport("user32.dll")]
    public static extern bool PostMessage(
        IntPtr hwnd, uint message, UIntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hwnd);

    [DllImport("user32.dll")]
    public static extern bool AdjustWindowRectExForDpi(
        ref RECT rect, int style, int menu, int exStyle, uint dpi);

    [DllImport("user32.dll")]
    public static extern uint GetDpiForWindow(IntPtr hwnd);

    [DllImport("user32.dll")]
    public static extern bool SetWindowPos(
        IntPtr hwnd, IntPtr after, int x, int y, int width, int height, uint flags);

    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);

    [DllImport("user32.dll")]
    public static extern bool ClientToScreen(IntPtr hwnd, ref POINT point);

    public static int CountChangedPixels(
        byte[] baseline,
        byte[] current,
        int width,
        int height,
        int stride,
        int sampleStep,
        int channelTolerance) {
        if (baseline == null || current == null ||
            baseline.Length != current.Length ||
            width <= 0 || height <= 0 || stride < width * 4 ||
            baseline.Length < stride * height) {
            throw new ArgumentException("Invalid bitmap snapshot bounds.");
        }
        int changed = 0;
        int step = Math.Max(1, sampleStep);
        for (int y = 0; y < height; y += step) {
            int row = y * stride;
            for (int x = 0; x < width; x += step) {
                int index = row + x * 4;
                if (Math.Abs(baseline[index] - current[index]) > channelTolerance ||
                    Math.Abs(baseline[index + 1] - current[index + 1]) > channelTolerance ||
                    Math.Abs(baseline[index + 2] - current[index + 2]) > channelTolerance) {
                    changed++;
                }
            }
        }
        return changed;
    }

    public static int CountNonBlankPixels(
        byte[] pixels,
        int width,
        int height,
        int stride,
        int sampleStep) {
        if (pixels == null || width <= 0 || height <= 0 ||
            stride < width * 4 || pixels.Length < stride * height) {
            throw new ArgumentException("Invalid bitmap snapshot bounds.");
        }
        int visible = 0;
        int step = Math.Max(1, sampleStep);
        for (int y = 0; y < height; y += step) {
            int row = y * stride;
            for (int x = 0; x < width; x += step) {
                int index = row + x * 4;
                if (pixels[index] != 0 ||
                    pixels[index + 1] != 0 ||
                    pixels[index + 2] != 0 ||
                    pixels[index + 3] != 0) {
                    visible++;
                }
            }
        }
        return visible;
    }

    public struct RECT {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    public struct POINT {
        public int X;
        public int Y;
    }
}
"@
}

function Resolve-LiveDemoType {
    param(
        [ValidateSet("advanced", "simple")]
        [string]$Mode,
        [ValidateSet("auto", "legacy", "presets", "policy")]
        [string]$DemoType
    )

    if ($Mode -eq "simple") {
        if ($DemoType -notin @("auto", "legacy")) {
            throw "Simple mode only supports the legacy demo contract."
        }
        return "legacy"
    }
    if ($DemoType -eq "auto") {
        return "presets"
    }
    return $DemoType
}

function Get-LiveDemoTimeline {
    param(
        [ValidateSet("advanced", "simple")]
        [string]$Mode,
        [ValidateSet("auto", "legacy", "presets", "policy")]
        [string]$DemoType
    )

    $resolved = Resolve-LiveDemoType -Mode $Mode -DemoType $DemoType
    switch ($resolved) {
        "legacy" {
            if ($Mode -eq "simple") {
                return @(
                    @{
                        At = 1.6; Action = "command"; Command = 102
                        ControlId = 102; PresetIndex = 1; ExpectedWatts = 25
                        Label = "应用 25 W 预设"
                    },
                    @{
                        At = 4.6; Action = "command"; Command = 103
                        ControlId = 103; PresetIndex = 2; ExpectedWatts = 45
                        Label = "应用 45 W 预设"
                    },
                    @{
                        At = 7.6; Action = "command"; Command = 101
                        ControlId = 101; PresetIndex = 0; ExpectedWatts = 10
                        Label = "应用 10 W 预设"
                    }
                )
            }
            return @(
                @{
                    At = 1.2; Action = "command"; Command = 102
                    ControlId = 102; Label = "选择快捷预设 2"
                },
                @{
                    At = 4.0; Action = "command"; Command = 101
                    ControlId = 101; Label = "选择快捷预设 1"
                },
                @{
                    At = 6.6; Action = "command"; Command = 103
                    ControlId = 103; Label = "选择快捷预设 3"
                },
                @{
                    At = 9.2; Action = "set_text"; ControlId = 301
                    Text = "12"; Label = "编辑快捷预设 1 为 12 W"
                },
                @{
                    At = 10.0; Action = "set_text"; ControlId = 301
                    Text = "10"; Label = "恢复快捷预设 1 为 10 W"
                },
                @{
                    At = 10.8; Action = "command"; Command = 106
                    ControlId = 106; Label = "保存快捷预设"
                }
            )
        }
        "presets" {
            return @(
                @{
                    At = 1.2; Action = "set_text"; ControlId = 301
                    Text = "12"; Label = "编辑快捷预设 1 为 12 W"
                },
                @{
                    At = 2.8; Action = "command"; Command = 106
                    ControlId = 106; Label = "保存快捷预设"
                },
                @{
                    At = 4.5; Action = "command"; Command = 101
                    ControlId = 101; PresetIndex = 0; ExpectedWatts = 12
                    Label = "应用 12 W 预设"
                },
                @{
                    At = 6.3; Action = "set_text"; ControlId = 301
                    Text = "10"; Label = "把快捷预设 1 改回 10 W"
                },
                @{
                    At = 7.9; Action = "command"; Command = 106
                    ControlId = 106; Label = "再次保存快捷预设"
                },
                @{
                    At = 9.6; Action = "command"; Command = 101
                    ControlId = 101; PresetIndex = 0; ExpectedWatts = 10
                    Label = "应用 10 W 预设"
                }
            )
        }
        "policy" {
            return @(
                @{
                    At = 1.0; Action = "set_text"; ControlId = 312
                    Text = "25"; Label = "设置电池目标 25 W"
                },
                @{
                    At = 2.2; Action = "set_text"; ControlId = 314
                    Text = "45"; Label = "设置外接目标 45 W"
                },
                @{
                    At = 3.4; Action = "command"; Command = 315
                    ControlId = 315; Label = "启用自动策略"
                },
                @{
                    At = 4.6; Action = "command"; Command = 105
                    ControlId = 105; Label = "保存双线路策略"
                },
                @{
                    At = 6.4; Action = "command"; Command = 318
                    ControlId = 318; Label = "切换为仅电池策略"
                },
                @{
                    At = 7.6; Action = "command"; Command = 105
                    ControlId = 105; Label = "保存仅电池策略"
                },
                @{
                    At = 9.4; Action = "command"; Command = 318
                    ControlId = 318; Label = "恢复双线路策略"
                },
                @{
                    At = 10.6; Action = "command"; Command = 105
                    ControlId = 105; Label = "保存恢复后的双线路策略"
                }
            )
        }
        default {
            throw "Unsupported demo type: $resolved"
        }
    }
}

function Get-LiveDemoWindowTitle {
    # Fixture-only privacy title. It deliberately contains neither a GUID nor
    # the worker pipe name used to isolate this capture instance.
    return "AMD Mobile Power - 演示片段"
}

function Assert-LiveDemoArtifactsPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$ArtifactsRoot
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $fullRoot = [System.IO.Path]::GetFullPath($ArtifactsRoot).TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar)
    $prefix = $fullRoot + [System.IO.Path]::DirectorySeparatorChar
    if (-not $fullPath.StartsWith(
        $prefix,
        [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Capture path must stay under artifacts: $fullPath"
    }
    return $fullPath
}

function Test-LiveDemoOwnedStateDirectoryPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$StateDirectory,
        [Parameter(Mandatory = $true)]
        [string]$ArtifactsRoot
    )

    $fullPath = [System.IO.Path]::GetFullPath($StateDirectory)
    $fullRoot = [System.IO.Path]::GetFullPath($ArtifactsRoot).TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar)
    $mediaRoot = [System.IO.Path]::GetFullPath(
        (Join-Path $fullRoot "media")).TrimEnd(
            [System.IO.Path]::DirectorySeparatorChar,
            [System.IO.Path]::AltDirectorySeparatorChar)
    $parent = [System.IO.Path]::GetDirectoryName($fullPath)
    $leaf = [System.IO.Path]::GetFileName($fullPath)
    return (
        $null -ne $parent -and
        $parent.Equals(
            $mediaRoot,
            [System.StringComparison]::OrdinalIgnoreCase) -and
        $leaf -match '^live-demo-state-[0-9a-fA-F]{32}$'
    )
}

function Assert-LiveDemoOwnedStateDirectory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$StateDirectory,
        [Parameter(Mandatory = $true)]
        [string]$ArtifactsRoot
    )

    if (-not (Test-LiveDemoOwnedStateDirectoryPath `
            -StateDirectory $StateDirectory `
            -ArtifactsRoot $ArtifactsRoot)) {
        throw "Refusing to clean an unowned capture state directory: $StateDirectory"
    }
    return [System.IO.Path]::GetFullPath($StateDirectory)
}

function Get-LiveDemoOwnedTreePlan {
    param(
        [Parameter(Mandatory = $true)]
        [string]$StateDirectory,
        [Parameter(Mandatory = $true)]
        [string]$ArtifactsRoot
    )

    $root = Assert-LiveDemoOwnedStateDirectory `
        -StateDirectory $StateDirectory `
        -ArtifactsRoot $ArtifactsRoot
    $files = [System.Collections.Generic.List[string]]::new()
    $directories = [System.Collections.Generic.List[string]]::new()
    if (-not (Test-Path -LiteralPath $root)) {
        return [pscustomobject]@{
            Root = $root
            Files = @()
            Directories = @()
        }
    }

    $rootAttributes = [System.IO.File]::GetAttributes($root)
    if (($rootAttributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Refusing to clean a reparse-point state directory: $root"
    }
    $rootPrefix = $root.TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar) +
        [System.IO.Path]::DirectorySeparatorChar
    $stack = [System.Collections.Generic.Stack[string]]::new()
    $stack.Push($root)
    while ($stack.Count -gt 0) {
        $current = $stack.Pop()
        foreach ($entry in [System.IO.Directory]::EnumerateFileSystemEntries(
                $current)) {
            $fullPath = [System.IO.Path]::GetFullPath($entry)
            if (-not $fullPath.StartsWith(
                    $rootPrefix,
                    [System.StringComparison]::OrdinalIgnoreCase)) {
                throw "Refusing to clean a descendant outside the owned root: $fullPath"
            }
            $attributes = [System.IO.File]::GetAttributes($fullPath)
            if (($attributes -band
                    [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Refusing to clean a reparse-point descendant: $fullPath"
            }
            if (($attributes -band
                    [System.IO.FileAttributes]::Directory) -ne 0) {
                $directories.Add($fullPath)
                $stack.Push($fullPath)
            }
            else {
                $files.Add($fullPath)
            }
        }
    }
    return [pscustomobject]@{
        Root = $root
        Files = @($files)
        Directories = @($directories)
    }
}

function Remove-LiveDemoStateDirectory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$StateDirectory,
        [Parameter(Mandatory = $true)]
        [string]$ArtifactsRoot
    )

    $plan = Get-LiveDemoOwnedTreePlan `
        -StateDirectory $StateDirectory `
        -ArtifactsRoot $ArtifactsRoot
    $rootPrefix = $plan.Root.TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar) +
        [System.IO.Path]::DirectorySeparatorChar

    # The complete tree was validated before this first mutation. Re-check
    # each path immediately before deletion so a concurrent replacement
    # cannot redirect cleanup outside the owned root.
    foreach ($file in $plan.Files) {
        $fullPath = [System.IO.Path]::GetFullPath($file)
        if (-not $fullPath.StartsWith(
                $rootPrefix,
                [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to delete a file outside the owned root: $fullPath"
        }
        if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
            continue
        }
        $attributes = [System.IO.File]::GetAttributes($fullPath)
        if (($attributes -band
                [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Refusing to delete a reparse-point file: $fullPath"
        }
        [System.IO.File]::Delete($fullPath)
    }

    $deepestFirst = @($plan.Directories | Sort-Object Length -Descending)
    foreach ($directory in $deepestFirst) {
        $fullPath = [System.IO.Path]::GetFullPath($directory)
        if (-not $fullPath.StartsWith(
                $rootPrefix,
                [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to delete a directory outside the owned root: $fullPath"
        }
        if (-not (Test-Path -LiteralPath $fullPath -PathType Container)) {
            continue
        }
        $attributes = [System.IO.File]::GetAttributes($fullPath)
        if (($attributes -band
                [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Refusing to delete a reparse-point directory: $fullPath"
        }
        [System.IO.Directory]::Delete($fullPath, $false)
    }
    if (Test-Path -LiteralPath $plan.Root -PathType Container) {
        $rootAttributes = [System.IO.File]::GetAttributes($plan.Root)
        if (($rootAttributes -band
                [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Refusing to delete a reparse-point state root: $($plan.Root)"
        }
        [System.IO.Directory]::Delete($plan.Root, $false)
    }
}

function New-LiveDemoStateSeed {
    param(
        [ValidateSet("advanced", "simple")]
        [string]$Mode,
        [ValidateSet("legacy", "presets", "policy")]
        [string]$ResolvedDemoType
    )

    $seed = [ordered]@{
        presets = @(10, 25, 45)
        mode = $Mode
        topMost = $false
    }
    if ($ResolvedDemoType -eq "policy") {
        # Non-final seed values make both edits in the policy clip visibly
        # change the form. The fixture applies these settings only in memory.
        $seed.powerPolicy = [ordered]@{
            enabled = $false
            batteryEnabled = $true
            acEnabled = $true
            batteryTarget = [ordered]@{
                stapmWatts = 12
                fastWatts = 12
                slowWatts = 12
            }
            acTarget = [ordered]@{
                stapmWatts = 35
                fastWatts = 35
                slowWatts = 35
            }
        }
    }
    return $seed
}

function Measure-LiveDemoVisualChange {
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Baseline,
        [Parameter(Mandatory = $true)]
        [psobject]$Current,
        [ValidateRange(1, 16)]
        [int]$SampleStep = 2,
        [ValidateRange(0, 255)]
        [int]$ChannelTolerance = 8
    )

    if ($Baseline.Width -ne $Current.Width -or
        $Baseline.Height -ne $Current.Height -or
        $Baseline.Stride -ne $Current.Stride) {
        throw "Cannot compare bitmap snapshots with different dimensions."
    }
    return [AmdMobilePowerLiveDemo]::CountChangedPixels(
        $Baseline.Bytes,
        $Current.Bytes,
        [int]$Baseline.Width,
        [int]$Baseline.Height,
        [int]$Baseline.Stride,
        $SampleStep,
        $ChannelTolerance)
}

function Measure-LiveDemoNonBlankPixels {
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Snapshot,
        [ValidateRange(1, 16)]
        [int]$SampleStep = 2
    )

    return [AmdMobilePowerLiveDemo]::CountNonBlankPixels(
        $Snapshot.Bytes,
        [int]$Snapshot.Width,
        [int]$Snapshot.Height,
        [int]$Snapshot.Stride,
        $SampleStep)
}

function Test-LiveDemoSnapshotNonBlank {
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Snapshot,
        [ValidateRange(1, 16)]
        [int]$SampleStep = 2
    )

    return (Measure-LiveDemoNonBlankPixels `
        -Snapshot $Snapshot `
        -SampleStep $SampleStep) -gt 0
}

function Test-LiveDemoVisualChange {
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Baseline,
        [Parameter(Mandatory = $true)]
        [psobject]$Current,
        [ValidateRange(1, 16)]
        [int]$SampleStep = 2,
        [ValidateRange(1, 100000)]
        [int]$MinChangedPixels = 24
    )

    $changed = Measure-LiveDemoVisualChange `
        -Baseline $Baseline `
        -Current $Current `
        -SampleStep $SampleStep
    return $changed -ge $MinChangedPixels
}

function ConvertTo-LiveDemoManifestEvent {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Step,
        [ValidateRange(1, 16)]
        [int]$SampleStep = 2,
        [ValidateRange(1, 100000)]
        [int]$MinChangedPixels = 24,
        [double]$VisualTimeoutSeconds = 3.0
    )

    $event = [ordered]@{
        Action = $Step.Action
        ScheduledAt = $Step.At
        ActualAt = $Step.ActualAt
        DispatchCompleted = [bool]$Step.DispatchCompleted
        Completed = [bool]$Step.Completed
        CompletionStatus = $Step.CompletionStatus
        ControlId = $Step.ControlId
        ClickX = $Step.ClickX
        ClickY = $Step.ClickY
        VisualChangedPixels = $Step.VisualChangedPixels
        BaselineNonBlankPixels = $Step.BaselineNonBlankPixels
        VisualFrameIndex = $Step.VisualFrameIndex
        VisualAt = $Step.VisualAt
        VisualDetectionMethod = "sampled-client-pixels"
        VisualSampleStep = $SampleStep
        VisualChangeMinPixels = $MinChangedPixels
        VisualTimeoutSeconds = $VisualTimeoutSeconds
    }
    if ($Step.ContainsKey("Command")) { $event.Command = $Step.Command }
    if ($Step.ContainsKey("Text")) { $event.Text = $Step.Text }
    if ($Step.ContainsKey("Label")) { $event.Label = $Step.Label }
    if ($Step.ContainsKey("PresetIndex")) { $event.PresetIndex = $Step.PresetIndex }
    if ($Step.ContainsKey("ExpectedWatts")) { $event.ExpectedWatts = $Step.ExpectedWatts }
    return $event
}

if ($ContractOnly) {
    return
}

$resolvedDemoType = Resolve-LiveDemoType -Mode $Mode -DemoType $DemoType
if (-not $OutputDirectory) {
    $OutputDirectory = Join-Path $root "artifacts\media\live-demo"
}
$resolvedOutput = Assert-LiveDemoArtifactsPath `
    -Path $OutputDirectory `
    -ArtifactsRoot $artifactsRoot
if (-not $ClipPath) {
    $ClipPath = if ($Mode -eq "simple") {
        Join-Path $resolvedOutput "presets-demo.mp4"
    }
    else {
        Join-Path $resolvedOutput "advanced-$resolvedDemoType-demo.mp4"
    }
}
$resolvedClip = Assert-LiveDemoArtifactsPath `
    -Path $ClipPath `
    -ArtifactsRoot $artifactsRoot
New-Item -ItemType Directory -Path $resolvedOutput -Force | Out-Null
$frameDirectory = Join-Path `
    $resolvedOutput `
    ("frames-" + [Guid]::NewGuid().ToString("N"))
$frameDirectory = Assert-LiveDemoArtifactsPath `
    -Path $frameDirectory `
    -ArtifactsRoot $artifactsRoot
New-Item -ItemType Directory -Path $frameDirectory -Force | Out-Null

# The capture process must be per-monitor DPI aware, otherwise every
# GetClientRect measurement comes back virtualized to 96 DPI and PrintWindow
# renders only the top-left fraction of the real window.
[AmdMobilePowerLiveDemo]::SetProcessDpiAwarenessContext([IntPtr](-4)) | Out-Null

function Get-ControlCenterPoint {
    param([IntPtr]$Window, [int]$ControlId)

    $control = [AmdMobilePowerLiveDemo]::GetDlgItem($Window, $ControlId)
    if ($control -eq [IntPtr]::Zero) {
        throw "Capture control $ControlId was not created."
    }
    $controlRect = New-Object AmdMobilePowerLiveDemo+RECT
    if (-not [AmdMobilePowerLiveDemo]::GetWindowRect(
            $control, [ref]$controlRect)) {
        throw "GetWindowRect failed for control $ControlId."
    }
    $origin = New-Object AmdMobilePowerLiveDemo+POINT
    $origin.X = 0
    $origin.Y = 0
    if (-not [AmdMobilePowerLiveDemo]::ClientToScreen(
            $Window, [ref]$origin)) {
        throw "ClientToScreen failed for the fixture window."
    }
    $clientRect = New-Object AmdMobilePowerLiveDemo+RECT
    if (-not [AmdMobilePowerLiveDemo]::GetClientRect(
            $Window, [ref]$clientRect)) {
        throw "GetClientRect failed for the fixture window."
    }
    $clientWidth = [Math]::Max(1, $clientRect.Right - $clientRect.Left)
    $clientHeight = [Math]::Max(1, $clientRect.Bottom - $clientRect.Top)
    $centerX = (($controlRect.Left + $controlRect.Right) / 2.0) - $origin.X
    $centerY = (($controlRect.Top + $controlRect.Bottom) / 2.0) - $origin.Y
    $normalizedX = $centerX / $clientWidth
    $normalizedY = $centerY / $clientHeight
    if ($normalizedX -lt 0 -or $normalizedX -gt 1 -or
        $normalizedY -lt 0 -or $normalizedY -gt 1) {
        throw "Control $ControlId center lies outside the fixture client."
    }
    return [pscustomobject]@{
        AbsoluteX = $centerX
        AbsoluteY = $centerY
        X = $normalizedX
        Y = $normalizedY
    }
}

function New-ClientBitmap {
    param([IntPtr]$Window)

    $rect = New-Object AmdMobilePowerLiveDemo+RECT
    if (-not [AmdMobilePowerLiveDemo]::GetClientRect(
            $Window, [ref]$rect)) {
        throw "GetClientRect failed while creating a capture bitmap."
    }
    $width = [Math]::Max(1, $rect.Right - $rect.Left)
    $height = [Math]::Max(1, $rect.Bottom - $rect.Top)
    return [System.Drawing.Bitmap]::new($width, $height)
}

function Get-LiveDemoBitmapSnapshot {
    param([System.Drawing.Bitmap]$Bitmap)

    $rect = [System.Drawing.Rectangle]::new(
        0, 0, $Bitmap.Width, $Bitmap.Height)
    $data = $Bitmap.LockBits(
        $rect,
        [System.Drawing.Imaging.ImageLockMode]::ReadOnly,
        [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    try {
        if ($data.Stride -le 0) {
            throw "Unexpected negative bitmap stride: $($data.Stride)"
        }
        $length = $data.Stride * $data.Height
        $bytes = [byte[]]::new($length)
        [System.Runtime.InteropServices.Marshal]::Copy(
            $data.Scan0, $bytes, 0, $length)
        return [pscustomobject]@{
            Width = $Bitmap.Width
            Height = $Bitmap.Height
            Stride = $data.Stride
            Bytes = $bytes
        }
    }
    finally {
        $Bitmap.UnlockBits($data)
    }
}

function New-CapturedClientBitmap {
    param([IntPtr]$Window)

    $bitmap = New-ClientBitmap -Window $Window
    try {
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        try {
            $hdc = $graphics.GetHdc()
            try {
                # PW_CLIENTONLY | PW_RENDERFULLCONTENT: render just the client
                # area into a client-sized bitmap. Recording frames and
                # pre-dispatch baselines share this production capture path.
                if (-not [AmdMobilePowerLiveDemo]::PrintWindow(
                        $Window, $hdc, 3)) {
                    throw "PrintWindow failed while capturing the fixture."
                }
            }
            finally {
                $graphics.ReleaseHdc($hdc)
            }
        }
        finally {
            $graphics.Dispose()
        }
        return $bitmap
    }
    catch {
        $bitmap.Dispose()
        throw
    }
}

function Get-LiveDemoClientSnapshot {
    param([IntPtr]$Window)

    $bitmap = New-CapturedClientBitmap -Window $Window
    try {
        $snapshot = Get-LiveDemoBitmapSnapshot -Bitmap $bitmap
        if (-not (Test-LiveDemoSnapshotNonBlank `
                -Snapshot $snapshot `
                -SampleStep $VisualSampleStep)) {
            throw "Captured client baseline is blank."
        }
        return $snapshot
    }
    finally {
        $bitmap.Dispose()
    }
}

function Save-Frame {
    param([IntPtr]$Window, [string]$Path)

    $bitmap = New-CapturedClientBitmap -Window $Window
    try {
        $snapshot = Get-LiveDemoBitmapSnapshot -Bitmap $bitmap
        $bitmap.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
        return [pscustomobject]@{
            Path = $Path
            Snapshot = $snapshot
        }
    }
    finally {
        $bitmap.Dispose()
    }
}

$stateDirectory = Join-Path `
    $artifactsRoot `
    ("media\live-demo-state-" + [Guid]::NewGuid().ToString("N"))
$stateDirectory = Assert-LiveDemoOwnedStateDirectory `
    -StateDirectory $stateDirectory `
    -ArtifactsRoot $artifactsRoot
$stateFileDirectory = Join-Path $stateDirectory "AmdMobilePower"
New-Item -ItemType Directory -Path $stateFileDirectory -Force | Out-Null

# Seed the same simple-mode state used by the verified screenshot capture.
# The advanced clip then switches through the GUI's own mode command so its
# layout is resized through the production code path.
$stateSeed = New-LiveDemoStateSeed `
    -Mode $Mode `
    -ResolvedDemoType $resolvedDemoType
[System.IO.File]::WriteAllText(
    (Join-Path $stateFileDirectory "rust-ui-state.json"),
    ($stateSeed | ConvertTo-Json -Depth 8),
    [System.Text.UTF8Encoding]::new($false))
$previousLocalAppData = $env:LOCALAPPDATA
$env:LOCALAPPDATA = $stateDirectory
$process = $null
$window = $null

try {
    $process = Start-Process `
        -FilePath $GuiExecutable `
        -WorkingDirectory (Split-Path -Parent $GuiExecutable) `
        -ArgumentList @(
            "--enable-write-controls",
            "--ui-fixture", $UiFixture,
            "--dpi-fixture", "$DpiFixture",
            "--pipe-name", "AmdMobilePower.Worker.livedemo.$([Guid]::NewGuid().ToString('N'))"
        ) `
        -PassThru
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    while ([DateTime]::UtcNow -lt $deadline) {
        $process.Refresh()
        if ($process.HasExited) {
            throw "GUI exited before creating a window."
        }
        if ($process.MainWindowHandle -ne [IntPtr]::Zero) {
            $window = $process.MainWindowHandle
            break
        }
        Start-Sleep -Milliseconds 100
    }
    if ($null -eq $window -or $window -eq [IntPtr]::Zero) {
        throw "GUI did not create a window."
    }
    if (-not [AmdMobilePowerLiveDemo]::SetWindowTextW(
            $window, (Get-LiveDemoWindowTitle))) {
        throw "Unable to apply the privacy title to the fixture window."
    }
    [AmdMobilePowerLiveDemo]::SetForegroundWindow($window) | Out-Null
    Start-Sleep -Milliseconds 400

    if ($Mode -eq "advanced") {
        [AmdMobilePowerLiveDemo]::SendMessage(
            $window, 0x0111,
            [System.UIntPtr]::new(109),
            [IntPtr]::Zero) | Out-Null
        $fixtureScale = $DpiFixture / 100.0
        $minClientWidth = [int][Math]::Round(760 * $fixtureScale)
        $minClientHeight = [int][Math]::Round(660 * $fixtureScale)
        $resizeDeadline = [DateTime]::UtcNow.AddSeconds(5)
        $measured = New-Object AmdMobilePowerLiveDemo+RECT
        do {
            Start-Sleep -Milliseconds 100
            [AmdMobilePowerLiveDemo]::GetClientRect(
                $window, [ref]$measured) | Out-Null
        } while (($measured.Right -lt $minClientWidth -or
                $measured.Bottom -lt $minClientHeight) -and
            [DateTime]::UtcNow -lt $resizeDeadline)
        if ($measured.Right -lt $minClientWidth -or
            $measured.Bottom -lt $minClientHeight) {
            throw ("Advanced client is too small for the demo: " +
                "$($measured.Right)x$($measured.Bottom), need at least " +
                "${minClientWidth}x${minClientHeight}")
        }
        [AmdMobilePowerLiveDemo]::SetForegroundWindow($window) | Out-Null
        Start-Sleep -Milliseconds 400
    }

    $clientSize = New-Object AmdMobilePowerLiveDemo+RECT
    [AmdMobilePowerLiveDemo]::GetClientRect(
        $window, [ref]$clientSize) | Out-Null

    $timeline = @(Get-LiveDemoTimeline -Mode $Mode -DemoType $DemoType)
    foreach ($step in $timeline) {
        $point = Get-ControlCenterPoint `
            -Window $window `
            -ControlId ([int]$step.ControlId)
        $step.ClickX = $point.X
        $step.ClickY = $point.Y
        $step.DispatchCompleted = $false
        $step.Completed = $false
        $step.CompletionStatus = "pending"
        $step.VisualChangedPixels = $null
        $step.BaselineNonBlankPixels = $null
        $step.VisualFrameIndex = $null
        $step.VisualAt = $null
    }

    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $frameIndex = 0
    $capturedFrames = [System.Collections.Generic.List[object]]::new()
    $frameInterval = 1.0 / $Fps
    $nextFrameAt = 0.0
    while ($watch.Elapsed.TotalSeconds -lt $DurationSeconds) {
        $elapsed = $watch.Elapsed.TotalSeconds
        foreach ($step in $timeline) {
            if (-not $step.ContainsKey("Done") -and
                $elapsed -ge [double]$step.At) {
                $step.BaselineSnapshot = Get-LiveDemoClientSnapshot `
                    -Window $window
                $step.BaselineNonBlankPixels =
                    (Measure-LiveDemoNonBlankPixels `
                        -Snapshot $step.BaselineSnapshot `
                        -SampleStep $VisualSampleStep)
                if ($step.BaselineNonBlankPixels -le 0) {
                    throw "Pre-dispatch client baseline contained no pixels."
                }
                try {
                    switch ($step.Action) {
                        "command" {
                            [AmdMobilePowerLiveDemo]::SendMessage(
                                $window, 0x0111,
                                [System.UIntPtr]::new(
                                    [uint32]$step.Command),
                                [IntPtr]::Zero) | Out-Null
                        }
                        "set_text" {
                            $control = [AmdMobilePowerLiveDemo]::GetDlgItem(
                                $window, [int]$step.ControlId)
                            if ($control -eq [IntPtr]::Zero) {
                                throw (
                                    "Text control $($step.ControlId) " +
                                    "was not created.")
                            }
                            [AmdMobilePowerLiveDemo]::SendMessageText(
                                $control, 0x000C,
                                [System.UIntPtr]::Zero,
                                [string]$step.Text) | Out-Null
                        }
                        default {
                            throw "Unsupported capture action: $($step.Action)"
                        }
                    }
                    $step.DispatchCompleted = $true
                    $step.CompletionStatus = "awaiting-visible-change"
                }
                catch {
                    $step.CompletionStatus = "dispatch-failed"
                    throw
                }
                finally {
                    if (-not $step.DispatchCompleted -and
                        $step.CompletionStatus -eq "pending") {
                        $step.CompletionStatus = "dispatch-failed"
                    }
                }
                $step.Done = $true
                $step.ActualAt = $elapsed
                $step.VisualDeadlineAt = (
                    $elapsed + $VisualChangeTimeoutSeconds)
            }
        }
        if ($elapsed -ge $nextFrameAt) {
            $framePath = Join-Path `
                $frameDirectory `
                ("frame-{0:d4}.png" -f $frameIndex)
            $captured = Save-Frame -Window $window -Path $framePath
            foreach ($step in $timeline) {
                if (-not $step.DispatchCompleted -or $step.Completed -or
                    $step.CompletionStatus -eq "timed-out") {
                    continue
                }
                if ($elapsed -gt [double]$step.VisualDeadlineAt) {
                    $step.CompletionStatus = "timed-out"
                    $step.BaselineSnapshot = $null
                    continue
                }
                $changed = Measure-LiveDemoVisualChange `
                    -Baseline $step.BaselineSnapshot `
                    -Current $captured.Snapshot `
                    -SampleStep $VisualSampleStep
                if ($changed -ge $VisualChangeMinPixels) {
                    $step.Completed = $true
                    $step.CompletionStatus = "visible-change-observed"
                    $step.VisualChangedPixels = $changed
                    $step.VisualFrameIndex = $frameIndex
                    $step.VisualAt = $elapsed
                    $step.BaselineSnapshot = $null
                }
            }
            $capturedFrames.Add([pscustomobject]@{
                Path = $captured.Path
                At = $elapsed
            })
            $frameIndex++
            $nextFrameAt += $frameInterval
        }
        Start-Sleep -Milliseconds 25
    }

    foreach ($step in $timeline) {
        if ($step.Completed) { continue }
        $step.BaselineSnapshot = $null
        $step.CompletionStatus = if ($step.DispatchCompleted) {
            "timed-out"
        }
        else {
            "not-dispatched"
        }
    }
    if ($capturedFrames.Count -lt 2) {
        throw "Insufficient captured frames."
    }

    $manifestFrames = for ($i = 0; $i -lt $capturedFrames.Count; $i++) {
        [ordered]@{
            Index = $i
            At = $capturedFrames[$i].At
            Path = [System.IO.Path]::GetFileName($capturedFrames[$i].Path)
        }
    }
    $manifestEvents = @($timeline | ForEach-Object {
        ConvertTo-LiveDemoManifestEvent `
            -Step $_ `
            -SampleStep $VisualSampleStep `
            -MinChangedPixels $VisualChangeMinPixels `
            -VisualTimeoutSeconds $VisualChangeTimeoutSeconds
    })
    $manifest = [ordered]@{
        # Simple mode keeps the original schema version and event fields.
        # Advanced clips add operation metadata without forcing existing
        # desktop-clip consumers onto a new contract.
        SchemaVersion = if ($Mode -eq "simple") { 1 } else { 2 }
        SimulatedData = $true
        Fixture = $UiFixture
        GuiSha256 = (
            Get-FileHash -LiteralPath $GuiExecutable -Algorithm SHA256
        ).Hash.ToLowerInvariant()
        HardwareAccess = $false
        Mode = $Mode
        DemoType = $resolvedDemoType
        DpiFixture = $DpiFixture
        RequestedFps = $Fps
        DurationSeconds = $DurationSeconds
        FrameCount = $frameIndex
        FrameDirectory = $frameDirectory
        ClientWidth = $clientSize.Right - $clientSize.Left
        ClientHeight = $clientSize.Bottom - $clientSize.Top
        FixtureWindowTitle = Get-LiveDemoWindowTitle
        CompletionPolicy = (
            "Completed=true only after a sampled client-pixel change " +
            "meeting the configured threshold within the visual timeout.")
        VisualDetection = [ordered]@{
            Method = "sampled-client-pixels"
            SampleStep = $VisualSampleStep
            MinChangedPixels = $VisualChangeMinPixels
            TimeoutSeconds = $VisualChangeTimeoutSeconds
        }
        Frames = @($manifestFrames)
        Events = $manifestEvents
        RecordedAt = (Get-Date).ToString("o")
    }
    $manifestPath = Join-Path $resolvedOutput "frames-manifest.json"
    [System.IO.File]::WriteAllText(
        $manifestPath,
        ($manifest | ConvertTo-Json -Depth 10),
        [System.Text.UTF8Encoding]::new($false))

    $incomplete = @($timeline | Where-Object {
        -not $_.Completed
    })
    if ($incomplete.Count -gt 0) {
        $details = @($incomplete | ForEach-Object {
            "$($_.Action)@$($_.At)s=$($_.CompletionStatus)"
        }) -join ", "
        throw (
            "Fixture events did not produce a visible change: $details. " +
            "Partial manifest: $manifestPath")
    }

    $ffmpeg = (Get-Command ffmpeg -ErrorAction Stop).Source
    $concat = [System.Collections.Generic.List[string]]::new()
    for ($i = 0; $i -lt $capturedFrames.Count; $i++) {
        $frame = $capturedFrames[$i]
        $end = if ($i + 1 -lt $capturedFrames.Count) {
            $capturedFrames[$i + 1].At
        }
        else {
            $DurationSeconds
        }
        $duration = [Math]::Max(0.001, $end - $frame.At)
        $escapedPath = $frame.Path.Replace("\", "/").Replace("'", "'\''")
        $concat.Add("file '$escapedPath'")
        $concat.Add(
            "duration " +
            $duration.ToString(
                "0.######",
                [Globalization.CultureInfo]::InvariantCulture))
    }
    $lastPath = $capturedFrames[-1].Path.Replace("\", "/").Replace(
        "'", "'\''")
    $concat.Add("file '$lastPath'")
    $concatPath = Join-Path $resolvedOutput "frames.ffconcat"
    $concat | Set-Content -LiteralPath $concatPath -Encoding ascii
    $filter = "scale=trunc(iw/2)*2:trunc(ih/2)*2,format=yuv420p"
    & $ffmpeg `
        -y `
        -f concat -safe 0 `
        -i $concatPath `
        -filter_complex $filter `
        -r $Fps `
        -c:v libx264 `
        -preset medium `
        -crf 18 `
        -movflags +faststart `
        $resolvedClip
    if ($LASTEXITCODE -ne 0) {
        throw "ffmpeg failed with exit code $LASTEXITCODE."
    }

    $hash = (
        Get-FileHash -LiteralPath $resolvedClip -Algorithm SHA256
    ).Hash.ToLowerInvariant()
    [ordered]@{
        Verification = "PASS"
        Clip = $resolvedClip
        ClipSha256 = $hash
        GuiSha256 = (
            Get-FileHash `
                -LiteralPath $GuiExecutable `
                -Algorithm SHA256
        ).Hash.ToLowerInvariant()
        SimulatedData = $true
        DurationSeconds = $DurationSeconds
        Frames = $frameIndex
        Timing = (
            "Per-frame monotonic timestamps; every event completed only " +
            "after its first sampled visible client change")
        Manifest = $manifestPath
        FrameDirectory = $frameDirectory
        Mode = $Mode
        DemoType = $resolvedDemoType
        Events = $manifestEvents
        Fixture = $UiFixture
        DpiFixture = $DpiFixture
        VisualDetection = $manifest.VisualDetection
        RecordedAt = (Get-Date).ToString("o")
    } | ConvertTo-Json -Depth 10
}
finally {
    try {
        if ($null -ne $window -and $window -ne [IntPtr]::Zero) {
            try {
                [AmdMobilePowerLiveDemo]::PostMessage(
                    $window, 0x0111,
                    [System.UIntPtr]::new(2),
                    [IntPtr]::Zero) | Out-Null
            }
            catch {
                # Closing the owned fixture is best effort. The bounded
                # process exit below remains authoritative.
            }
        }
        if ($process) {
            try {
                if (-not $process.WaitForExit(5000)) {
                    $process.Kill()
                    if (-not $process.WaitForExit(5000)) {
                        throw "Capture GUI did not exit."
                    }
                }
            }
            finally {
                $process.Dispose()
            }
        }
    }
    finally {
        $env:LOCALAPPDATA = $previousLocalAppData
        Remove-LiveDemoStateDirectory `
            -StateDirectory $stateDirectory `
            -ArtifactsRoot $artifactsRoot
    }
}
