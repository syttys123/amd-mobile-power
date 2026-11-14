param(
    [string]$GuiExecutable,
    [string]$WorkerExecutable,
    [string]$OutputDirectory,
    [string]$EvidencePath,
    [string]$FilePrefix = "native-redesign",
    [string]$FileDate = "2026-11-11",
    [ValidateSet("worker-offline", "firmware-clamp", "unsupported-platform", "long-error", "high-contrast")]
    [string]$Fixture,
    [ValidateSet("100", "125", "150", "200")]
    [string]$DpiFixture,
    [ValidateRange(5, 60)]
    [int]$UniformTargetWatts,
    [ValidateRange(0, 60)]
    [int]$PolicyBatteryWatts,
    [ValidateRange(0, 60)]
    [int]$PolicyAcWatts,
    [ValidateCount(3, 3)]
    [int[]]$PresetWatts = @(12, 25, 45),
    [switch]$BatteryOnly,
    [int]$FocusControlId,
    [switch]$ApplyFixtureTarget,
    [switch]$ForcePrintWindow,
    [switch]$CaptureConsent,
    [switch]$ReadOnly
)

$ErrorActionPreference = "Stop"
if ($CaptureConsent -and (-not $ReadOnly -or -not $Fixture)) {
    throw 'Consent capture requires a read-only isolated fixture.'
}
if ($ApplyFixtureTarget -and ($Fixture -ne 'firmware-clamp' -or $ReadOnly)) {
    throw 'ApplyFixtureTarget requires a writable firmware-clamp fixture.'
}
Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;

public static class AmdMobilePowerUiCapture {
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern IntPtr FindWindow(string className, string title);
    public delegate bool ChildCallback(IntPtr hwnd, IntPtr parameter);
    [DllImport("user32.dll")]
    public static extern bool EnumChildWindows(IntPtr hwnd, ChildCallback callback, IntPtr parameter);
    [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "SendMessageW")]
    public static extern IntPtr ReadText(IntPtr hwnd, uint message, UIntPtr capacity,
        System.Text.StringBuilder text);
    [DllImport("user32.dll")]
    public static extern bool SetProcessDpiAwarenessContext(IntPtr value);

    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);

    [DllImport("user32.dll")]
    public static extern bool GetClientRect(IntPtr hwnd, out RECT rect);

    [DllImport("user32.dll")]
    public static extern IntPtr GetDlgItem(IntPtr hwnd, int id);

    [DllImport("user32.dll")]
    public static extern IntPtr SendMessage(
        IntPtr hwnd,
        uint message,
        UIntPtr wParam,
        IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern bool PostMessage(
        IntPtr hwnd,
        uint message,
        UIntPtr wParam,
        IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern bool ShowWindowAsync(IntPtr hwnd, int command);

    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hwnd);

    [DllImport("user32.dll")]
    public static extern bool SetFocus(IntPtr hwnd);

    [DllImport("user32.dll")]
    public static extern IntPtr GetFocus();

    [DllImport("user32.dll")]
    public static extern bool BringWindowToTop(IntPtr hwnd);

    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr hwnd);

    [DllImport("user32.dll")]
    public static extern bool IsWindowEnabled(IntPtr hwnd);

    [DllImport("user32.dll")]
    public static extern bool PrintWindow(IntPtr hwnd, IntPtr hdc, uint flags);

    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint processId);

    [DllImport("kernel32.dll")]
    public static extern uint GetCurrentThreadId();

    [DllImport("user32.dll")]
    public static extern bool AttachThreadInput(uint attach, uint attachTo, bool value);

    [DllImport("user32.dll")]
    public static extern bool GetGUIThreadInfo(
        uint idThread,
        ref GUITHREADINFO value);

    [DllImport("user32.dll")]
    public static extern bool SetWindowPos(
        IntPtr hwnd,
        IntPtr insertAfter,
        int x,
        int y,
        int width,
        int height,
        uint flags);

    [DllImport("dwmapi.dll")]
    public static extern int DwmGetWindowAttribute(
        IntPtr hwnd,
        uint attribute,
        out RECT value,
        int valueSize);

    public struct RECT {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    public struct GUITHREADINFO {
        public uint cbSize;
        public uint flags;
        public IntPtr hwndActive;
        public IntPtr hwndFocus;
        public IntPtr hwndCapture;
        public IntPtr hwndMenuOwner;
        public IntPtr hwndMoveSize;
        public IntPtr hwndCaret;
        public RECT rcCaret;
    }
}
"@

function Save-WindowImage {
    param(
        [IntPtr]$Window,
        [string]$Path
    )

    $rect = New-Object AmdMobilePowerUiCapture+RECT
    $dwmResult = [AmdMobilePowerUiCapture]::DwmGetWindowAttribute(
        $Window,
        9,
        [ref]$rect,
        [System.Runtime.InteropServices.Marshal]::SizeOf($rect))
    if ($dwmResult -ne 0 -or
        $rect.Right -le $rect.Left -or
        $rect.Bottom -le $rect.Top) {
        [AmdMobilePowerUiCapture]::GetWindowRect($Window, [ref]$rect) | Out-Null
    }
    $width = $rect.Right - $rect.Left
    $height = $rect.Bottom - $rect.Top
    $bitmap = New-Object System.Drawing.Bitmap $width, $height
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $captureMethod = $null
    try {
        if (-not $ForcePrintWindow -and [AmdMobilePowerUiCapture]::GetForegroundWindow() -eq $Window) {
            $graphics.CopyFromScreen(
                $rect.Left,
                $rect.Top,
                0,
                0,
                $bitmap.Size)
            $captureMethod = "CopyFromScreen(foreground-verified)"
        }
        else {
            $windowRect = New-Object AmdMobilePowerUiCapture+RECT
            if (-not [AmdMobilePowerUiCapture]::GetWindowRect($Window, [ref]$windowRect)) {
                throw 'GetWindowRect failed for PrintWindow capture.'
            }
            $windowWidth = $windowRect.Right - $windowRect.Left
            $windowHeight = $windowRect.Bottom - $windowRect.Top
            $offsetX = $rect.Left - $windowRect.Left
            $offsetY = $rect.Top - $windowRect.Top
            if ($offsetX -lt 0 -or $offsetY -lt 0 -or
                ($offsetX + $width) -gt $windowWidth -or
                ($offsetY + $height) -gt $windowHeight) {
                throw 'Visible frame lies outside the PrintWindow surface.'
            }
            $surface = [System.Drawing.Bitmap]::new($windowWidth, $windowHeight)
            try {
                $surfaceGraphics = [System.Drawing.Graphics]::FromImage($surface)
                try {
                    $surfaceGraphics.Clear([System.Drawing.Color]::White)
                    $graphicsHdc = $surfaceGraphics.GetHdc()
                    try {
                        $rendered = [AmdMobilePowerUiCapture]::PrintWindow(
                            $Window,
                            $graphicsHdc,
                            2)
                    }
                    finally {
                        $surfaceGraphics.ReleaseHdc($graphicsHdc)
                    }
                    if (-not $rendered) {
                        throw "Neither foreground capture nor PrintWindow fallback succeeded."
                    }
                    $graphics.DrawImage($surface,
                        [System.Drawing.Rectangle]::new(0, 0, $width, $height),
                        [System.Drawing.Rectangle]::new($offsetX, $offsetY, $width, $height),
                        [System.Drawing.GraphicsUnit]::Pixel)
                }
                finally { $surfaceGraphics.Dispose() }
            }
            finally { $surface.Dispose() }
            $captureMethod = "PrintWindow(exact-frame-crop)"
        }
        $bitmap.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    }
    finally {
        $graphics.Dispose()
        $bitmap.Dispose()
    }
    return [pscustomobject]@{
        Path = $Path
        Width = $width
        Height = $height
        CaptureMethod = $captureMethod
        SHA256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}

function Focus-CaptureWindow {
    param(
        [IntPtr]$Window,
        [int]$FocusControlId = 0
    )

    $processId = [uint32]0
    $targetThread = [AmdMobilePowerUiCapture]::GetWindowThreadProcessId(
        $Window,
        [ref]$processId)
    $currentThread = [AmdMobilePowerUiCapture]::GetCurrentThreadId()
    $attached = $false
    try {
        if ($targetThread -ne $currentThread) {
            $attached = [AmdMobilePowerUiCapture]::AttachThreadInput(
                $currentThread,
                $targetThread,
                $true)
        }
        $deadline = [DateTime]::UtcNow.AddSeconds(2)
        while ([DateTime]::UtcNow -lt $deadline) {
            [AmdMobilePowerUiCapture]::ShowWindowAsync($Window, 9) | Out-Null
            [AmdMobilePowerUiCapture]::BringWindowToTop($Window) | Out-Null
            [AmdMobilePowerUiCapture]::SetForegroundWindow($Window) | Out-Null
            [AmdMobilePowerUiCapture]::SetFocus($Window) | Out-Null
            if ([AmdMobilePowerUiCapture]::GetForegroundWindow() -eq $Window) {
                if ($FocusControlId -gt 0) {
                    $control = [AmdMobilePowerUiCapture]::GetDlgItem(
                        $Window,
                        $FocusControlId)
                    if ($control -eq [IntPtr]::Zero) {
                        throw "Focus control $FocusControlId was not found."
                    }
                    [AmdMobilePowerUiCapture]::SendMessage(
                        $Window,
                        0x0028,
                        [UIntPtr]$control.ToInt64(),
                        [IntPtr]1) | Out-Null
                    [AmdMobilePowerUiCapture]::SetFocus($control) | Out-Null
                    $threadInfo = New-Object `
                        AmdMobilePowerUiCapture+GUITHREADINFO
                    $threadInfo.cbSize = [uint32](
                        [System.Runtime.InteropServices.Marshal]::SizeOf(
                            $threadInfo))
                    [AmdMobilePowerUiCapture]::GetGUIThreadInfo(
                        $targetThread,
                        [ref]$threadInfo) | Out-Null
                    $attachedFocus =
                        [AmdMobilePowerUiCapture]::GetFocus()
                    if ($threadInfo.hwndFocus -ne $control -and
                        $attachedFocus -ne $control) {
                        throw "Focus control $FocusControlId did not receive focus."
                    }
                }
                return
            }
            Start-Sleep -Milliseconds 50
        }
        return $false
    }
    finally {
        if ($attached) {
            [AmdMobilePowerUiCapture]::AttachThreadInput(
                $currentThread,
                $targetThread,
                $false) | Out-Null
        }
    }
}

function Get-WindowSize {
    param([IntPtr]$Window)

    $rect = New-Object AmdMobilePowerUiCapture+RECT
    [AmdMobilePowerUiCapture]::GetWindowRect($Window, [ref]$rect) | Out-Null
    return [pscustomobject]@{
        Width = $rect.Right - $rect.Left
        Height = $rect.Bottom - $rect.Top
    }
}

function Get-ClientSize {
    param([IntPtr]$Window)

    $rect = New-Object AmdMobilePowerUiCapture+RECT
    [AmdMobilePowerUiCapture]::GetClientRect($Window, [ref]$rect) | Out-Null
    return [pscustomobject]@{
        Width = $rect.Right - $rect.Left
        Height = $rect.Bottom - $rect.Top
    }
}

function Assert-FixtureClientSize {
    param(
        [IntPtr]$Window,
        [string]$Scale,
        [int]$LogicalWidth,
        [int]$LogicalHeight,
        [string]$Description
    )

    if ([string]::IsNullOrWhiteSpace($Scale)) {
        return
    }
    $percent = [int]$Scale
    $expectedWidth = [int][Math]::Floor(($LogicalWidth * $percent + 50) / 100.0)
    $expectedHeight = [int][Math]::Floor(($LogicalHeight * $percent + 50) / 100.0)
    $actual = Get-ClientSize -Window $Window
    if ($actual.Width -ne $expectedWidth -or $actual.Height -ne $expectedHeight) {
        throw (
            "$Description client size mismatch at ${Scale}%: " +
            "$($actual.Width)x$($actual.Height), expected " +
            "${expectedWidth}x${expectedHeight}."
        )
    }
    return $actual
}

function Wait-ForWindowHeight {
    param(
        [IntPtr]$Window,
        [scriptblock]$Condition,
        [string]$Description
    )

    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    while ([DateTime]::UtcNow -lt $deadline) {
        $size = Get-WindowSize -Window $Window
        if (& $Condition $size.Height) {
            return
        }
        Start-Sleep -Milliseconds 50
    }
    throw "Timed out waiting for $Description."
}

$root = Split-Path -Parent $PSCommandPath
$repositoryRoot = Split-Path -Parent $root
$artifactsRoot = [System.IO.Path]::GetFullPath(
    (Join-Path $repositoryRoot "artifacts"))
if (-not $GuiExecutable) {
    $GuiExecutable = Join-Path $root "rust-gui\target\release\amd-mobile-power-gui.exe"
}
$GuiExecutable = (Resolve-Path -LiteralPath $GuiExecutable).Path
if (-not $WorkerExecutable) {
    $WorkerExecutable = Join-Path `
        $artifactsRoot `
        "native-build\worker-runtime\amdmobilepower_native_worker.exe"
}
$WorkerExecutable = (Resolve-Path -LiteralPath $WorkerExecutable).Path
if (-not $OutputDirectory) {
    $OutputDirectory = Join-Path $artifactsRoot "verify"
}
$OutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)
if (-not $OutputDirectory.StartsWith(
    $artifactsRoot + [System.IO.Path]::DirectorySeparatorChar,
    [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Capture output must stay under artifacts: $OutputDirectory"
}
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null

$stateDirectory = [System.IO.Path]::GetFullPath(
    (Join-Path $artifactsRoot "native-build\capture-state-$([Guid]::NewGuid().ToString('N'))"))
New-Item -ItemType Directory -Path $stateDirectory -Force | Out-Null
if ($BatteryOnly -and $UniformTargetWatts -gt 0) {
    throw "BatteryOnly and UniformTargetWatts cannot be combined."
}
if (($PolicyBatteryWatts -gt 0) -xor ($PolicyAcWatts -gt 0)) {
    throw "PolicyBatteryWatts and PolicyAcWatts must be provided together."
}
$hasCustomPolicy = (
    $BatteryOnly -or
    $UniformTargetWatts -gt 0 -or
    ($PolicyBatteryWatts -gt 0 -and $PolicyAcWatts -gt 0)
)
if ($hasCustomPolicy) {
    $stateFileDirectory = Join-Path $stateDirectory "AmdMobilePower"
    New-Item -ItemType Directory -Path $stateFileDirectory -Force | Out-Null
    $batteryWatts = if ($UniformTargetWatts -gt 0) {
        $UniformTargetWatts
    }
    elseif ($PolicyBatteryWatts -gt 0) {
        $PolicyBatteryWatts
    }
    else {
        10
    }
    $acWatts = if ($UniformTargetWatts -gt 0) {
        $UniformTargetWatts
    }
    elseif ($PolicyAcWatts -gt 0) {
        $PolicyAcWatts
    }
    else {
        45
    }
    $presets = if ($UniformTargetWatts -gt 0) {
        @($UniformTargetWatts, $UniformTargetWatts, $UniformTargetWatts)
    }
    else {
        $PresetWatts
    }
    [ordered]@{
        powerPolicy = [ordered]@{
            enabled = $true
            batteryEnabled = $true
            acEnabled = -not $BatteryOnly
            batteryTarget = [ordered]@{
                stapmWatts = $batteryWatts
                fastWatts = $batteryWatts
                slowWatts = $batteryWatts
            }
            acTarget = [ordered]@{
                stapmWatts = $acWatts
                fastWatts = $acWatts
                slowWatts = $acWatts
            }
        }
        presets = $presets
        mode = "simple"
        topMost = $false
        maxTargetWatts = if ($UniformTargetWatts -gt 0) {
            $UniformTargetWatts
        }
        else {
            $null
        }
    } |
        ConvertTo-Json -Depth 8 |
        Set-Content -LiteralPath (Join-Path $stateFileDirectory "rust-ui-state.json") -Encoding UTF8
}
else {
    $stateFileDirectory = Join-Path $stateDirectory "AmdMobilePower"
    New-Item -ItemType Directory -Path $stateFileDirectory -Force | Out-Null
    [ordered]@{
        presets = $PresetWatts
        mode = "simple"
        topMost = $false
    } | ConvertTo-Json | Set-Content -LiteralPath (
        Join-Path $stateFileDirectory "rust-ui-state.json") -Encoding UTF8
}
$previousLocalAppData = $env:LOCALAPPDATA
$env:LOCALAPPDATA = $stateDirectory
$pipeName = "AmdMobilePower.RedesignCapture.$([Guid]::NewGuid().ToString('N'))"
$process = $null
$window = [IntPtr]::Zero
$simpleCapture = $null
$advancedCapture = $null

try {
    [AmdMobilePowerUiCapture]::SetProcessDpiAwarenessContext(
        [IntPtr](-4)) | Out-Null
    $guiArguments = @(
        "--worker-executable", $WorkerExecutable,
        "--pipe-name", $pipeName
    )
    if (-not $ReadOnly) {
        $guiArguments += "--enable-write-controls"
    }
    if ($Fixture) {
        $guiArguments += @("--ui-fixture", $Fixture)
    }
    if ($DpiFixture) {
        $guiArguments += @("--dpi-fixture", $DpiFixture)
    }
    $process = Start-Process `
        -FilePath $GuiExecutable `
        -WorkingDirectory (Split-Path -Parent $GuiExecutable) `
        -ArgumentList $guiArguments `
        -PassThru
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    while ([DateTime]::UtcNow -lt $deadline) {
        $process.Refresh()
        if ($process.HasExited) {
            throw "Rust GUI exited before creating the redesign window."
        }
        if ($process.MainWindowHandle -ne [IntPtr]::Zero) {
            $window = $process.MainWindowHandle
            break
        }
        Start-Sleep -Milliseconds 100
    }
    if ($window -eq [IntPtr]::Zero) {
        throw "Rust GUI did not create the redesign window in time."
    }

    [void](Focus-CaptureWindow -Window $window -FocusControlId $FocusControlId)
    [AmdMobilePowerUiCapture]::SetWindowPos(
        $window,
        [IntPtr](-1),
        40,
        40,
        0,
        0,
        0x0001) | Out-Null
    Start-Sleep -Seconds 1
    [void](Focus-CaptureWindow -Window $window -FocusControlId $FocusControlId)
    Start-Sleep -Milliseconds 500
    if ($ApplyFixtureTarget) {
        [AmdMobilePowerUiCapture]::PostMessage(
            $window, 0x0111, [UIntPtr]::new(104), [IntPtr]::Zero) | Out-Null
        $applyDeadline = [DateTime]::UtcNow.AddSeconds(5)
        $fixtureApplyStatus = ''
        do {
            Start-Sleep -Milliseconds 50
            if ($process.HasExited) { throw 'Fixture exited before apply completion.' }
            $script:completedFixtureStatus = ''
            $statusCallback = [AmdMobilePowerUiCapture+ChildCallback] {
                param($child, $parameter)
                $text = [System.Text.StringBuilder]::new(1024)
                [AmdMobilePowerUiCapture]::ReadText(
                    $child, 0x000D, [UIntPtr]::new($text.Capacity), $text) | Out-Null
                if ($text.ToString() -match '^(已应用 |固件限制：)') {
                    $script:completedFixtureStatus = $text.ToString()
                }
                return $true
            }
            [AmdMobilePowerUiCapture]::EnumChildWindows($window, $statusCallback, [IntPtr]::Zero) | Out-Null
            $fixtureApplyStatus = $script:completedFixtureStatus
        } while ($fixtureApplyStatus -notmatch '^(已应用 |固件限制：)' -and [DateTime]::UtcNow -lt $applyDeadline)
        if ($fixtureApplyStatus -notmatch '^(已应用 |固件限制：)') {
            throw "Fixture did not report completed application: $fixtureApplyStatus"
        }
    }
    $consentCapture = $null
    if ($CaptureConsent) {
        [AmdMobilePowerUiCapture]::PostMessage($window, 0x0111, [UIntPtr]111, [IntPtr]::Zero) | Out-Null
        $deadline = [DateTime]::UtcNow.AddSeconds(5)
        $dialog = [IntPtr]::Zero
        do {
            Start-Sleep -Milliseconds 50
            $dialog = [AmdMobilePowerUiCapture]::FindWindow('AmdMobilePower.UnlockConsent.v1', '启用写入之前')
        } while ($dialog -eq [IntPtr]::Zero -and [DateTime]::UtcNow -lt $deadline)
        if ($dialog -eq [IntPtr]::Zero) { throw 'Consent dialog did not open.' }
        try {
            $confirm = [AmdMobilePowerUiCapture]::GetDlgItem($dialog, 402)
            if ($confirm -eq [IntPtr]::Zero -or [AmdMobilePowerUiCapture]::IsWindowEnabled($confirm)) {
                throw 'Consent confirm must remain disabled before agreement.'
            }
            [void](Focus-CaptureWindow -Window $dialog)
            $consentCapture = Save-WindowImage -Window $dialog -Path (Join-Path $OutputDirectory "$FilePrefix-consent-$FileDate.png")
        } finally {
            [AmdMobilePowerUiCapture]::PostMessage($dialog, 0x0010, [UIntPtr]::Zero, [IntPtr]::Zero) | Out-Null
        }
        Start-Sleep -Milliseconds 150
    }
    $advancedButton = [AmdMobilePowerUiCapture]::GetDlgItem($window, 109)
    if ($advancedButton -eq [IntPtr]::Zero) {
        throw "Advanced-mode control was not found."
    }
    $simpleSize = Get-WindowSize -Window $window
    [AmdMobilePowerUiCapture]::SendMessage(
        $advancedButton,
        0x00F5,
        [UIntPtr]109,
        [IntPtr]::Zero) | Out-Null
    Wait-ForWindowHeight `
        -Window $window `
        -Description "advanced layout" `
        -Condition { param($height) $height -gt $simpleSize.Height }
    $advancedClientSize = Assert-FixtureClientSize `
        -Window $window `
        -Scale $DpiFixture `
        -LogicalWidth 780 `
        -LogicalHeight 680 `
        -Description "advanced"
    Start-Sleep -Milliseconds 400
    [void](Focus-CaptureWindow -Window $window -FocusControlId $FocusControlId)
    $advancedCapture = Save-WindowImage `
        -Window $window `
        -Path (Join-Path $OutputDirectory "$FilePrefix-advanced-$FileDate.png")
    $advancedHeight = (Get-WindowSize -Window $window).Height
    $simpleButton = [AmdMobilePowerUiCapture]::GetDlgItem($window, 108)
    if ($simpleButton -eq [IntPtr]::Zero) {
        throw "Simple-mode control was not found."
    }
    [AmdMobilePowerUiCapture]::SendMessage(
        $simpleButton,
        0x00F5,
        [UIntPtr]108,
        [IntPtr]::Zero) | Out-Null
    Wait-ForWindowHeight `
        -Window $window `
        -Description "simple layout" `
        -Condition { param($height) $height -lt $advancedHeight }
    $simpleClientSize = Assert-FixtureClientSize `
        -Window $window `
        -Scale $DpiFixture `
        -LogicalWidth 600 `
        -LogicalHeight 360 `
        -Description "simple"
    Start-Sleep -Milliseconds 400
    [void](Focus-CaptureWindow -Window $window -FocusControlId $FocusControlId)
    $simpleCapture = Save-WindowImage `
        -Window $window `
        -Path (Join-Path $OutputDirectory "$FilePrefix-simple-$FileDate.png")

    $controlChecks = $null
    if ($ReadOnly -or $Fixture) {
        $applyButton = [AmdMobilePowerUiCapture]::GetDlgItem($window, 317)
        $presetButton = [AmdMobilePowerUiCapture]::GetDlgItem($window, 101)
        $diagnosticsButton = [AmdMobilePowerUiCapture]::GetDlgItem($window, 107)
        if ($applyButton -eq [IntPtr]::Zero -or
            $presetButton -eq [IntPtr]::Zero -or
            $diagnosticsButton -eq [IntPtr]::Zero) {
            throw "Expected fixture controls were not found."
        }
        $expectedWritesEnabled = (
            -not $ReadOnly -and
            $Fixture -in @("firmware-clamp", "high-contrast")
        )
        $actualWritesEnabled = (
            [AmdMobilePowerUiCapture]::IsWindowEnabled($applyButton) -and
            [AmdMobilePowerUiCapture]::IsWindowEnabled($presetButton)
        )
        if ($actualWritesEnabled -ne $expectedWritesEnabled) {
            throw (
                "Unexpected write-control state for fixture '$Fixture' " +
                "and ReadOnly=$ReadOnly."
            )
        }
        $diagnosticsEnabled =
            [AmdMobilePowerUiCapture]::IsWindowEnabled($diagnosticsButton)
        if (-not $diagnosticsEnabled) {
            throw "Diagnostics must remain enabled in this UI state."
        }
        $controlChecks = [ordered]@{
            TargetAndPresetEnabled = $actualWritesEnabled
            DiagnosticsEnabled = $diagnosticsEnabled
        }
        if ($BatteryOnly) {
            $batteryOnlyButton = [AmdMobilePowerUiCapture]::GetDlgItem($window, 318)
            if ($batteryOnlyButton -eq [IntPtr]::Zero -or
                -not [AmdMobilePowerUiCapture]::IsWindowEnabled($batteryOnlyButton)) {
                throw "Battery-only policy control is not available for capture."
            }
            $controlChecks.BatteryOnlyVisible = $true
        }
    }

    if ($EvidencePath) {
        $evidenceDirectory = Split-Path -Parent $EvidencePath
        if ($evidenceDirectory) {
            New-Item -ItemType Directory -Path $evidenceDirectory -Force | Out-Null
        }
        [ordered]@{
            SchemaVersion = 1
            CaptureMode = if ($hasCustomPolicy) {
                "write-controls-visible-policy-seeded"
            }
            elseif ($ReadOnly) {
                "read-only-no-write-controls"
            }
            else {
                "write-controls-visible-no-write-requested"
            }
            Fixture = if ($Fixture) { $Fixture } else { $null }
            FixtureApplyRequested = [bool]$ApplyFixtureTarget
            Consent = $consentCapture
            FixtureApplyStatus = if ($ApplyFixtureTarget) { $fixtureApplyStatus } else { $null }
            DpiFixture = if ($DpiFixture) { [int]$DpiFixture } else { $null }
            UniformTargetWatts = if ($UniformTargetWatts -gt 0) {
                $UniformTargetWatts
            }
            else {
                $null
            }
            PolicyBatteryWatts = if ($PolicyBatteryWatts -gt 0) {
                $PolicyBatteryWatts
            }
            else {
                $null
            }
            PolicyAcWatts = if ($PolicyAcWatts -gt 0) {
                $PolicyAcWatts
            }
            else {
                $null
            }
            PolicySeeded = [bool]$hasCustomPolicy
            BatteryOnly = [bool]$BatteryOnly
            FocusControlId = if ($FocusControlId -gt 0) { $FocusControlId } else { $null }
            ControlChecks = $controlChecks
            Simple = $simpleCapture
            Advanced = $advancedCapture
            SimpleClientSize = if ($simpleClientSize) {
                "$($simpleClientSize.Width)x$($simpleClientSize.Height)"
            }
            else {
                $null
            }
            AdvancedClientSize = if ($advancedClientSize) {
                "$($advancedClientSize.Width)x$($advancedClientSize.Height)"
            }
            else {
                $null
            }
            RecordedAt = (Get-Date).ToString("o")
        } |
            ConvertTo-Json -Depth 6 |
            Set-Content -LiteralPath $EvidencePath -Encoding UTF8
    }
}
finally {
    try {
    if ($window -ne [IntPtr]::Zero) {
        [AmdMobilePowerUiCapture]::PostMessage(
            $window,
            0x0111,
            [UIntPtr]::new(2),
            [IntPtr]::Zero) | Out-Null
    }
    if ($process) {
        try {
            if (-not $process.WaitForExit(5000)) {
                $process.Kill($true)
                if (-not $process.WaitForExit(5000)) { throw "Capture GUI did not exit." }
            }
        }
        finally { $process.Dispose() }
    }
    }
    finally {
    $env:LOCALAPPDATA = $previousLocalAppData
    if (Test-Path -LiteralPath $stateDirectory) {
        Remove-Item -LiteralPath $stateDirectory -Recurse -Force
    }
    }
}

[pscustomobject]@{
    Simple = $simpleCapture.Path
    SimpleSize = "$($simpleCapture.Width)x$($simpleCapture.Height)"
    Advanced = $advancedCapture.Path
    AdvancedSize = "$($advancedCapture.Width)x$($advancedCapture.Height)"
    CaptureMethod = @(
        $simpleCapture.CaptureMethod,
        $advancedCapture.CaptureMethod
    ) -join ", "
    Fixture = if ($Fixture) { $Fixture } else { "none" }
    DpiFixture = if ($DpiFixture) { $DpiFixture } else { "native" }
    UniformTargetWatts = if ($UniformTargetWatts -gt 0) {
        $UniformTargetWatts
    }
    else {
        "none"
    }
    BatteryOnly = [bool]$BatteryOnly
    FocusControlId = if ($FocusControlId -gt 0) { $FocusControlId } else { "none" }
    ControlChecks = if ($controlChecks) { $controlChecks | ConvertTo-Json -Compress } else { "not requested" }
} | Format-List
