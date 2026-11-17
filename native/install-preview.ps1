param(
    [string]$InstallDirectory = (
        Join-Path $env:LOCALAPPDATA "Programs\AmdMobilePowerNativePreview"
    ),
    [switch]$NoStartup,
    [switch]$NoShellIntegration,
    [switch]$NoLaunch
)

$ErrorActionPreference = "Stop"

$sourceDirectory = $PSCommandPath | Split-Path -Parent
$nativePreviewVersion = "0.5.0-native-preview.1"
$buildInfoPath = Join-Path $sourceDirectory "BUILD-INFO.txt"
if (Test-Path -LiteralPath $buildInfoPath) {
    $buildInfoText = [System.IO.File]::ReadAllText(
        $buildInfoPath,
        [System.Text.Encoding]::UTF8)
    foreach ($line in ($buildInfoText -split "`r?`n")) {
        $line = $line.TrimStart([char]0xFEFF)
        if ($line -match "^Version=(.+)$") {
            $nativePreviewVersion = $Matches[1].Trim()
            break
        }
    }
}

$guiExecutable = Join-Path $sourceDirectory "amd-mobile-power-gui.exe"
$workerExecutable = Join-Path $sourceDirectory "amdmobilepower_native_worker.exe"
if (-not (Test-Path -LiteralPath $guiExecutable) -or
    -not (Test-Path -LiteralPath $workerExecutable)) {
    throw "Run this script from an extracted native preview package."
}

$resolvedSource = [System.IO.Path]::GetFullPath($sourceDirectory)
$resolvedInstall = [System.IO.Path]::GetFullPath($InstallDirectory)
if ($resolvedInstall.Equals(
    $resolvedSource,
    [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "InstallDirectory must differ from the package directory."
}
$pathRoot = [System.IO.Path]::GetPathRoot($resolvedInstall)
if ([string]::IsNullOrWhiteSpace($pathRoot) -or
    $resolvedInstall.TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar) -eq
    $pathRoot.TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar)) {
    throw "InstallDirectory must not be a filesystem root: $resolvedInstall"
}

function Stop-ProcessesUnderInstallDirectory {
    param([Parameter(Mandatory = $true)][string]$Root)

    $prefix = [System.IO.Path]::GetFullPath($Root).TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar) +
        [System.IO.Path]::DirectorySeparatorChar
    Get-CimInstance `
        -ClassName Win32_Process `
        -Filter "Name='amd-mobile-power-gui.exe' OR Name='amdmobilepower_native_worker.exe'" `
        -ErrorAction SilentlyContinue |
        ForEach-Object {
            $candidate = $_.ExecutablePath
            if ([string]::IsNullOrWhiteSpace($candidate)) {
                return
            }
            $candidate = [System.IO.Path]::GetFullPath($candidate)
            if ($candidate.StartsWith(
                $prefix,
                [System.StringComparison]::OrdinalIgnoreCase)) {
                Stop-Process `
                    -Id ([int]$_.ProcessId) `
                    -Force `
                    -ErrorAction SilentlyContinue
            }
        }
}

Stop-ProcessesUnderInstallDirectory -Root $resolvedInstall

$installParent = Split-Path -Parent $resolvedInstall
if ([string]::IsNullOrWhiteSpace($installParent)) {
    throw "InstallDirectory has no parent directory: $resolvedInstall"
}

function Assert-ExpectedCleanupDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ExpectedPath,
        [Parameter(Mandatory = $true)][string]$Parent,
        [string]$LeafPrefix
    )

    $resolvedPath = [System.IO.Path]::GetFullPath($Path)
    $resolvedExpected = [System.IO.Path]::GetFullPath($ExpectedPath)
    if (-not [string]::Equals(
        $resolvedPath,
        $resolvedExpected,
        [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to clean an unexpected path: $resolvedPath != $resolvedExpected"
    }
    $resolvedParent = [System.IO.Path]::GetFullPath($Parent)
    if (-not [string]::Equals(
        [System.IO.Path]::GetFullPath((Split-Path -Parent $resolvedPath)),
        $resolvedParent,
        [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Cleanup path must be a direct child of $resolvedParent : $resolvedPath"
    }
    if ($LeafPrefix -and
        -not [System.IO.Path]::GetFileName($resolvedPath).StartsWith(
            $LeafPrefix,
            [System.StringComparison]::Ordinal)) {
        throw "Cleanup path has an unexpected name: $resolvedPath"
    }
    if (Test-Path -LiteralPath $resolvedPath) {
        $item = Get-Item -LiteralPath $resolvedPath -Force
        if (-not $item.PSIsContainer) {
            throw "Cleanup path is not a directory: $resolvedPath"
        }
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Refusing to clean a reparse point: $resolvedPath"
        }
    }
    return $resolvedPath
}

New-Item -ItemType Directory -Path $installParent -Force | Out-Null

$operationId = [Guid]::NewGuid().ToString("N")
$stagingDirectory = Join-Path `
    $installParent `
    ".AmdMobilePowerNativePreview.install-$operationId"
$backupDirectory = Join-Path `
    $installParent `
    ".AmdMobilePowerNativePreview.backup-$operationId"
try {
    Assert-ExpectedCleanupDirectory `
        -Path $stagingDirectory `
        -ExpectedPath $stagingDirectory `
        -Parent $installParent `
        -LeafPrefix ".AmdMobilePowerNativePreview.install-" | Out-Null
    Assert-ExpectedCleanupDirectory `
        -Path $backupDirectory `
        -ExpectedPath $backupDirectory `
        -Parent $installParent `
        -LeafPrefix ".AmdMobilePowerNativePreview.backup-" | Out-Null
    if ((Test-Path -LiteralPath $stagingDirectory) -or
        (Test-Path -LiteralPath $backupDirectory)) {
        throw "Installer staging or backup path already exists."
    }

    New-Item -ItemType Directory -Path $stagingDirectory | Out-Null
    Copy-Item `
        -Path (Join-Path $resolvedSource "*") `
        -Destination $stagingDirectory `
        -Recurse `
        -Force
    "Native preview install marker" |
        Set-Content `
            -LiteralPath (Join-Path $stagingDirectory "NATIVE-PREVIEW-INSTALL.txt") `
            -Encoding ascii
    if (-not (Test-Path -LiteralPath (Join-Path $stagingDirectory "amd-mobile-power-gui.exe"))) {
        throw "Staged native preview is missing the GUI executable."
    }

    if (Test-Path -LiteralPath $resolvedInstall) {
        Assert-ExpectedCleanupDirectory `
            -Path $resolvedInstall `
            -ExpectedPath $resolvedInstall `
            -Parent $installParent | Out-Null
        $existingMarker = Join-Path $resolvedInstall "NATIVE-PREVIEW-INSTALL.txt"
        $existingEntries = @(Get-ChildItem -LiteralPath $resolvedInstall -Force)
        if (-not (Test-Path -LiteralPath $existingMarker) -and $existingEntries.Count -gt 0) {
            throw "Refusing to overwrite an unmarked non-empty install directory: $resolvedInstall"
        }
        Move-Item -LiteralPath $resolvedInstall -Destination $backupDirectory
    }

    try {
        Move-Item -LiteralPath $stagingDirectory -Destination $resolvedInstall
        if (Test-Path -LiteralPath $backupDirectory) {
            $cleanupBackup = Assert-ExpectedCleanupDirectory `
                -Path $backupDirectory `
                -ExpectedPath $backupDirectory `
                -Parent $installParent `
                -LeafPrefix ".AmdMobilePowerNativePreview.backup-"
            Remove-Item -LiteralPath $cleanupBackup -Recurse -Force
        }
    }
    catch {
        if (Test-Path -LiteralPath $resolvedInstall) {
            $cleanupInstall = Assert-ExpectedCleanupDirectory `
                -Path $resolvedInstall `
                -ExpectedPath $resolvedInstall `
                -Parent $installParent
            Remove-Item -LiteralPath $cleanupInstall -Recurse -Force
        }
        if (Test-Path -LiteralPath $backupDirectory) {
            Move-Item -LiteralPath $backupDirectory -Destination $resolvedInstall
        }
        throw
    }
}
finally {
    if (Test-Path -LiteralPath $stagingDirectory) {
        $cleanupStaging = Assert-ExpectedCleanupDirectory `
            -Path $stagingDirectory `
            -ExpectedPath $stagingDirectory `
            -Parent $installParent `
            -LeafPrefix ".AmdMobilePowerNativePreview.install-"
        Remove-Item -LiteralPath $cleanupStaging -Recurse -Force
    }
    if (Test-Path -LiteralPath $backupDirectory) {
        $cleanupBackup = Assert-ExpectedCleanupDirectory `
            -Path $backupDirectory `
            -ExpectedPath $backupDirectory `
            -Parent $installParent `
            -LeafPrefix ".AmdMobilePowerNativePreview.backup-"
        Remove-Item -LiteralPath $cleanupBackup -Recurse -Force
    }
}

$installedGui = Join-Path $resolvedInstall "amd-mobile-power-gui.exe"
$startMenuShortcut = $null
$startupShortcut = $null
$uninstallKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\AmdMobilePowerNativePreview"

if (-not $NoShellIntegration) {
    $shell = New-Object -ComObject WScript.Shell
    $programs = [Environment]::GetFolderPath("Programs")
    $startMenuDirectory = Join-Path $programs "AMD Mobile Power Native Preview"
    New-Item -ItemType Directory -Path $startMenuDirectory -Force | Out-Null
    $startMenuShortcut = Join-Path `
        $startMenuDirectory `
        "AMD Mobile Power Native Preview.lnk"
    $shortcut = $shell.CreateShortcut($startMenuShortcut)
    $shortcut.TargetPath = $installedGui
    $shortcut.WorkingDirectory = $resolvedInstall
    $shortcut.IconLocation = "$installedGui,0"
    $shortcut.Description = "AMD Mobile Power native preview"
    $shortcut.Save()

    $uninstallScript = Join-Path $resolvedInstall "uninstall-preview.ps1"
    New-Item -Path $uninstallKey -Force | Out-Null
    New-ItemProperty `
        -Path $uninstallKey `
        -Name "DisplayName" `
        -Value "AMD Mobile Power Native Preview" `
        -PropertyType String `
        -Force | Out-Null
    New-ItemProperty `
        -Path $uninstallKey `
        -Name "DisplayVersion" `
        -Value $nativePreviewVersion `
        -PropertyType String `
        -Force | Out-Null
    New-ItemProperty `
        -Path $uninstallKey `
        -Name "InstallLocation" `
        -Value $resolvedInstall `
        -PropertyType String `
        -Force | Out-Null
    New-ItemProperty `
        -Path $uninstallKey `
        -Name "UninstallString" `
        -Value "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$uninstallScript`"" `
        -PropertyType String `
        -Force | Out-Null
}

if (-not $NoStartup) {
    $shell = New-Object -ComObject WScript.Shell
    $startup = [Environment]::GetFolderPath("Startup")
    $startupShortcut = Join-Path `
        $startup `
        "AMD Mobile Power Native Preview.lnk"
    $shortcut = $shell.CreateShortcut($startupShortcut)
    $shortcut.TargetPath = $installedGui
    $shortcut.Arguments = "--tray"
    $shortcut.WorkingDirectory = $resolvedInstall
    $shortcut.IconLocation = "$installedGui,0"
    $shortcut.Description = "Start AMD Mobile Power native preview in read-only mode"
    $shortcut.Save()
}

if (-not $NoLaunch) {
    Start-Process `
        -FilePath $installedGui `
        -WorkingDirectory $resolvedInstall
}

[pscustomobject]@{
    Version = $nativePreviewVersion
    InstallDirectory = $resolvedInstall
    StartMenuShortcut = $startMenuShortcut
    StartupShortcut = $startupShortcut
    Launched = (-not $NoLaunch)
} | Format-List
