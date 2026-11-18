param(
    [Parameter(Mandatory = $true)]
    [string]$GuiExecutable,
    [string]$OutputDirectory,
    [string]$EvidencePath,
    [ValidateRange(6, 15)]
    [double]$DurationSeconds = 7.0
)

$ErrorActionPreference = "Stop"
$repositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$artifactsRoot = [IO.Path]::GetFullPath((Join-Path $repositoryRoot "artifacts"))
if (-not $OutputDirectory) {
    $OutputDirectory = Join-Path $artifactsRoot "media\diagnostics-flow"
}
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
if (-not $OutputDirectory.StartsWith(
    $artifactsRoot + [IO.Path]::DirectorySeparatorChar,
    [StringComparison]::OrdinalIgnoreCase)) {
    throw "Output must stay under artifacts: $OutputDirectory"
}
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$frameDirectory = Join-Path $OutputDirectory ("frames-" + [Guid]::NewGuid().ToString("N"))
$stateDirectory = Join-Path $artifactsRoot ("media\diagnostics-state-" + [Guid]::NewGuid().ToString("N"))
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
public static class AmdDiagnosticsFlowCapture {
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
    [DllImport("user32.dll")] public static extern IntPtr GetDlgItem(IntPtr hwnd, int id);
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr hwnd, out RECT rect);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);
    [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr hwnd, ref POINT point);
    [DllImport("user32.dll", SetLastError=true)] public static extern bool PrintWindow(IntPtr hwnd, IntPtr hdc, uint flags);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hwnd, uint msg, UIntPtr w, IntPtr l);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hwnd);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern bool SetWindowText(IntPtr hwnd, string text);
    public delegate bool ChildCallback(IntPtr hwnd, IntPtr parameter);
    [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr hwnd, ChildCallback callback, IntPtr parameter);
    [DllImport("user32.dll", CharSet=CharSet.Unicode, EntryPoint="SendMessageW")]
    public static extern IntPtr ReadText(IntPtr hwnd, uint msg, UIntPtr capacity, System.Text.StringBuilder text);
    public struct RECT { public int Left, Top, Right, Bottom; }
    public struct POINT { public int X, Y; }
}
"@
[void][AmdDiagnosticsFlowCapture]::SetProcessDpiAwarenessContext([IntPtr](-4))

function Save-ClientFrame {
    param([IntPtr]$Window, [string]$Path)
    $rect = New-Object AmdDiagnosticsFlowCapture+RECT
    [void][AmdDiagnosticsFlowCapture]::GetClientRect($Window, [ref]$rect)
    $bitmap = New-Object Drawing.Bitmap ([Math]::Max(1, $rect.Right)), ([Math]::Max(1, $rect.Bottom))
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    try {
        $hdc = $graphics.GetHdc()
        try {
            if (-not [AmdDiagnosticsFlowCapture]::PrintWindow($Window, $hdc, 3)) {
                throw "PrintWindow failed for the isolated diagnostics flow."
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
try {
    $env:LOCALAPPDATA = $stateDirectory
    $pipeName = "AmdMobilePower.DiagnosticsFlow.$([Guid]::NewGuid().ToString('N'))"
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
    [void][AmdDiagnosticsFlowCapture]::SetWindowText($window, "AMD Mobile Power")
    [void][AmdDiagnosticsFlowCapture]::SetForegroundWindow($window)
    Start-Sleep -Milliseconds 500
    $button = [AmdDiagnosticsFlowCapture]::GetDlgItem($window, 107)
    if ($button -eq [IntPtr]::Zero) { throw "Diagnostics button was not created." }
    $buttonRect = New-Object AmdDiagnosticsFlowCapture+RECT
    [void][AmdDiagnosticsFlowCapture]::GetWindowRect($button, [ref]$buttonRect)
    $origin = New-Object AmdDiagnosticsFlowCapture+POINT
    [void][AmdDiagnosticsFlowCapture]::ClientToScreen($window, [ref]$origin)
    $client = New-Object AmdDiagnosticsFlowCapture+RECT
    [void][AmdDiagnosticsFlowCapture]::GetClientRect($window, [ref]$client)
    $clickX = ((($buttonRect.Left + $buttonRect.Right) / 2.0) - $origin.X) / $client.Right
    $clickY = ((($buttonRect.Top + $buttonRect.Bottom) / 2.0) - $origin.Y) / $client.Bottom
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $frames = [Collections.Generic.List[object]]::new()
    $frameIndex = 0
    $nextFrameAt = 0.0
    $dispatched = $false
    $actualAt = $null
    $visualAt = $null
    $visualFrameIndex = $null
    $exportStatus = $null
    while ($watch.Elapsed.TotalSeconds -lt $DurationSeconds) {
        $elapsed = $watch.Elapsed.TotalSeconds
        if (-not $dispatched -and $elapsed -ge 2.0) {
            [void][AmdDiagnosticsFlowCapture]::PostMessage(
                $window, 0x0111, [UIntPtr]::new(107), [IntPtr]::Zero)
            $dispatched = $true
            $actualAt = $elapsed
        }
        if ($elapsed -ge $nextFrameAt) {
            $path = Join-Path $frameDirectory ("frame-{0:d4}.png" -f $frameIndex)
            Save-ClientFrame -Window $window -Path $path
            $frames.Add([pscustomobject]@{
                Index = $frameIndex; At = $elapsed
                Path = [IO.Path]::GetFileName($path)
            })
            if ($dispatched -and $null -eq $visualAt) {
                $script:foundStatus = $null
                $callback = [AmdDiagnosticsFlowCapture+ChildCallback] {
                    param($child, $parameter)
                    $text = [Text.StringBuilder]::new(2048)
                    [void][AmdDiagnosticsFlowCapture]::ReadText(
                        $child, 0x000D, [UIntPtr]::new($text.Capacity), $text)
                    if ($text.ToString().StartsWith("诊断已导出")) {
                        $script:foundStatus = $text.ToString()
                    }
                    return $true
                }
                [void][AmdDiagnosticsFlowCapture]::EnumChildWindows(
                    $window, $callback, [IntPtr]::Zero)
                if ($script:foundStatus) {
                    $visualAt = $elapsed
                    $visualFrameIndex = $frameIndex
                    $exportStatus = $script:foundStatus
                }
            }
            $frameIndex++
            $nextFrameAt += 0.04
        }
        Start-Sleep -Milliseconds 15
    }
    if ($null -eq $visualAt) { throw "Diagnostics export did not show a visible success state." }
    $exportDirectory = Join-Path $stateFileDirectory "diagnostics"
    $exports = @(Get-ChildItem -LiteralPath $exportDirectory -Filter "*.json" -File)
    if ($exports.Count -ne 1) { throw "Expected exactly one isolated diagnostics export." }
    $document = Get-Content -LiteralPath $exports[0].FullName -Raw | ConvertFrom-Json
    if ($document.privacy.containsLocalPaths -or $document.privacy.containsProcessIds -or
        $document.privacy.containsAccountNames -or $document.privacy.uploaded) {
        throw "Diagnostics privacy contract failed."
    }
    $manifest = [ordered]@{
        SchemaVersion = 1
        SimulatedData = $true
        HardwareAccess = $false
        Fixture = "preset-success"
        Flow = "diagnostics-export"
        GuiSha256 = (Get-FileHash -LiteralPath $GuiExecutable -Algorithm SHA256).Hash.ToLowerInvariant()
        DurationSeconds = $DurationSeconds
        FrameCount = $frames.Count
        FrameDirectory = $frameDirectory
        ClientWidth = $client.Right
        ClientHeight = $client.Bottom
        Frames = @($frames)
        Event = [ordered]@{
            Action = "command"; Control = 107; ScheduledAt = 2.0
            ActualAt = $actualAt; Completed = $true
            VisualFrameIndex = $visualFrameIndex; VisualAt = $visualAt
            ClickX = $clickX; ClickY = $clickY
            Status = "诊断已导出"
        }
        ExportFileName = $exports[0].Name
        ExportSha256 = (Get-FileHash -LiteralPath $exports[0].FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        Privacy = $document.privacy
        RecordedAt = (Get-Date).ToString("o")
    }
    if (-not $EvidencePath) { $EvidencePath = Join-Path $OutputDirectory "flow-manifest.json" }
    [IO.File]::WriteAllText($EvidencePath, ($manifest | ConvertTo-Json -Depth 8),
        [Text.UTF8Encoding]::new($false))
    $manifest | ConvertTo-Json -Depth 8
} finally {
    if ($window -ne [IntPtr]::Zero) {
        [void][AmdDiagnosticsFlowCapture]::PostMessage(
            $window, 0x0111, [UIntPtr]::new(2), [IntPtr]::Zero)
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
