<#
.SYNOPSIS
Promotes a verified native package to the stable deployment directory.

.DESCRIPTION
Dry-run by default. Apply validates the package identity before stopping any
target-owned process or moving directories, expands the ZIP, installs it, and
verifies every SHA256SUMS payload after installation. The target must be
C:\RyzenAdj or an isolated directory under artifacts\verify.

.PARAMETER ExpectedPackageSHA256
Optional 64-hex SHA256 of the ZIP. Strongly recommended. When supplied,
ExpectedSourceCommit must also be supplied.

.PARAMETER ExpectedSourceCommit
Optional 40-hex source commit. When supplied, ExpectedPackageSHA256 must also
be supplied.
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$PackagePath,
    [string]$TargetDirectory = "C:\RyzenAdj",
    [string]$BackupDirectory,
    [string]$EvidencePath,
    [ValidatePattern("^[0-9a-fA-F]{64}$")]
    [string]$ExpectedPackageSHA256,
    [ValidatePattern("^[0-9a-fA-F]{40}$")]
    [string]$ExpectedSourceCommit,
    [switch]$Apply,
    [switch]$NoLaunch,
    [switch]$SkipShellIntegration,
    [string]$GuiArguments
)

$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSCommandPath
$repositoryRoot = Split-Path -Parent $root
$artifactsRoot = [System.IO.Path]::GetFullPath(
    (Join-Path $repositoryRoot "artifacts"))
$isolatedTargetRoot = [System.IO.Path]::GetFullPath(
    (Join-Path $artifactsRoot "verify"))
$stagingParentRoot = [System.IO.Path]::GetFullPath(
    (Join-Path $artifactsRoot "deployment-backups"))
$stableTargetRoot = [System.IO.Path]::GetFullPath("C:\RyzenAdj")
$guiArgumentContractPath = Join-Path $root "gui-cli-contract.json"

if (-not ("PromotionPathNative" -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

public static class PromotionPathNative
{
    private const uint FileFlagBackupSemantics = 0x02000000;

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern SafeFileHandle CreateFile(
        string fileName,
        uint desiredAccess,
        uint shareMode,
        IntPtr securityAttributes,
        uint creationDisposition,
        uint flagsAndAttributes,
        IntPtr templateFile);

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern uint GetFinalPathNameByHandle(
        SafeFileHandle file,
        StringBuilder path,
        uint pathLength,
        uint flags);

    public static string GetFinalPath(string path)
    {
        using (SafeFileHandle handle = CreateFile(
            path,
            0,
            7,
            IntPtr.Zero,
            3,
            FileFlagBackupSemantics,
            IntPtr.Zero))
        {
            if (handle.IsInvalid)
            {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }

            StringBuilder buffer = new StringBuilder(32768);
            uint length = GetFinalPathNameByHandle(handle, buffer, (uint)buffer.Capacity, 0);
            if (length == 0)
            {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            if (length >= buffer.Capacity)
            {
                buffer = new StringBuilder((int)length + 1);
                length = GetFinalPathNameByHandle(handle, buffer, (uint)buffer.Capacity, 0);
                if (length == 0 || length >= buffer.Capacity)
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                }
            }

            string resolved = buffer.ToString();
            if (resolved.StartsWith(@"\\?\UNC\", StringComparison.OrdinalIgnoreCase))
            {
                return @"\\" + resolved.Substring(8);
            }
            if (resolved.StartsWith(@"\\?\", StringComparison.OrdinalIgnoreCase))
            {
                return resolved.Substring(4);
            }
            return resolved;
        }
    }
}
"@
}

function Get-NormalizedPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $full = [System.IO.Path]::GetFullPath($Path)
    $pathRoot = [System.IO.Path]::GetPathRoot($full)
    if ($full.Length -le $pathRoot.Length) {
        return $full
    }
    return $full.TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar)
}

function Test-SamePath {
    param(
        [Parameter(Mandatory = $true)][string]$Left,
        [Parameter(Mandatory = $true)][string]$Right
    )

    return [string]::Equals(
        (Get-NormalizedPath $Left),
        (Get-NormalizedPath $Right),
        [System.StringComparison]::OrdinalIgnoreCase)
}

function Test-PathWithinOrEqual {
    param(
        [Parameter(Mandatory = $true)][string]$Child,
        [Parameter(Mandatory = $true)][string]$Parent
    )

    $childPath = Get-NormalizedPath $Child
    $parentPath = Get-NormalizedPath $Parent
    if (Test-SamePath $childPath $parentPath) {
        return $true
    }
    $prefix = $parentPath.TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar) +
        [System.IO.Path]::DirectorySeparatorChar
    return $childPath.StartsWith(
        $prefix,
        [System.StringComparison]::OrdinalIgnoreCase)
}

function Test-PathStrictlyWithin {
    param(
        [Parameter(Mandatory = $true)][string]$Child,
        [Parameter(Mandatory = $true)][string]$Parent
    )

    return (Test-PathWithinOrEqual $Child $Parent) -and
        -not (Test-SamePath $Child $Parent)
}

function Assert-DisjointPaths {
    param(
        [Parameter(Mandatory = $true)][string]$Left,
        [Parameter(Mandatory = $true)][string]$Right,
        [Parameter(Mandatory = $true)][string]$Label
    )

    if ((Test-PathWithinOrEqual $Left $Right) -or
        (Test-PathWithinOrEqual $Right $Left)) {
        throw "Unsafe path overlap for ${Label}: $Left <-> $Right"
    }
}

function Get-FinalExistingPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $normalized = Get-NormalizedPath $Path
    if (-not (Test-Path -LiteralPath $normalized)) {
        return $normalized
    }
    return Get-NormalizedPath ([PromotionPathNative]::GetFinalPath($normalized))
}

function Get-FileSha256Hex {
    param([Parameter(Mandatory = $true)][string]$Path)

    $stream = [System.IO.File]::Open(
        $Path,
        [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::Read,
        [System.IO.FileShare]::ReadWrite)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $sha.ComputeHash($stream)
        return ([System.BitConverter]::ToString($bytes)).Replace("-", "").ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
        $stream.Dispose()
    }
}

function Assert-NotFilesystemRoot {
    param([Parameter(Mandatory = $true)][string]$Path)

    $normalized = Get-NormalizedPath $Path
    $pathRoot = [System.IO.Path]::GetPathRoot($normalized)
    if ([string]::IsNullOrWhiteSpace($pathRoot)) {
        throw "Path has no filesystem root: $normalized"
    }
    if (Test-SamePath $normalized $pathRoot) {
        throw "Refusing to use a filesystem root: $normalized"
    }
    return $normalized
}

function Assert-AllowedTargetPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $resolved = Assert-NotFilesystemRoot $Path
    $scope = $null
    if (Test-SamePath $resolved $stableTargetRoot) {
        $scope = "Stable"
    }
    elseif (Test-PathStrictlyWithin $resolved $isolatedTargetRoot) {
        $scope = "IsolatedTest"
    }
    else {
        throw ("TargetDirectory must be $stableTargetRoot or an isolated " +
            "test directory under $isolatedTargetRoot : $resolved")
    }

    if (Test-Path -LiteralPath $resolved) {
        $final = Get-FinalExistingPath $resolved
        if (-not (Test-SamePath $final $resolved)) {
            throw "TargetDirectory resolves through a link or junction: $resolved -> $final"
        }
        if (-not (Test-Path -LiteralPath $resolved -PathType Container)) {
            throw "TargetDirectory is not a directory: $resolved"
        }
    }
    return [pscustomobject]@{
        Path = $resolved
        Scope = $scope
    }
}

function Assert-AllowedBackupPath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Target
    )

    $resolved = Assert-NotFilesystemRoot $Path
    if (Test-SamePath $resolved $Target) {
        throw "Backup directory must differ from the target: $resolved"
    }
    $targetParent = Split-Path -Parent (Get-NormalizedPath $Target)
    $backupParent = Split-Path -Parent $resolved
    if (-not (Test-SamePath $backupParent $targetParent)) {
        throw ("Backup directory must be a direct sibling of the target. " +
            "Expected parent: $targetParent ; actual: $backupParent")
    }
    if (Test-Path -LiteralPath $resolved) {
        throw "Backup path already exists: $resolved"
    }
    return $resolved
}

function Resolve-ArtifactPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $resolved = Get-NormalizedPath $Path
    if (-not (Test-PathStrictlyWithin $resolved $artifactsRoot)) {
        throw "Path must stay under $artifactsRoot : $resolved"
    }
    return $resolved
}

function Assert-AllowedEvidencePath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][string]$Backup
    )

    $resolved = Resolve-ArtifactPath $Path
    if (Test-PathWithinOrEqual $resolved $Target) {
        throw "Evidence path must not be inside the target: $resolved"
    }
    if (Test-PathWithinOrEqual $resolved $Backup) {
        throw "Evidence path must not be inside the backup: $resolved"
    }
    if (Test-Path -LiteralPath $resolved) {
        throw "Evidence path already exists: $resolved"
    }
    return $resolved
}

function Assert-AllowedStagingPath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][string]$Backup
    )

    $resolved = Assert-NotFilesystemRoot $Path
    if (-not (Test-PathStrictlyWithin $resolved $stagingParentRoot)) {
        throw "Staging path must stay under $stagingParentRoot : $resolved"
    }
    Assert-DisjointPaths $resolved $Target "staging/target"
    Assert-DisjointPaths $resolved $Backup "staging/backup"
    return $resolved
}

function Remove-VerifiedDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ExpectedPath,
        [string]$AllowedRoot
    )

    $resolved = Assert-NotFilesystemRoot $Path
    $expected = Assert-NotFilesystemRoot $ExpectedPath
    if (-not (Test-SamePath $resolved $expected)) {
        throw "Refusing to remove an unexpected path: $resolved != $expected"
    }
    if ($AllowedRoot -and
        -not (Test-PathStrictlyWithin $resolved $AllowedRoot)) {
        throw "Refusing to remove a path outside $AllowedRoot : $resolved"
    }
    if (-not (Test-Path -LiteralPath $resolved)) {
        return
    }

    $item = Get-Item -LiteralPath $resolved -Force
    if (-not $item.PSIsContainer) {
        throw "Refusing to recursively remove a non-directory: $resolved"
    }
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Refusing to recursively remove a reparse point: $resolved"
    }
    $final = Get-FinalExistingPath $resolved
    if (-not (Test-SamePath $final $expected)) {
        throw "Resolved cleanup path no longer matches: $resolved -> $final"
    }

    Remove-Item -LiteralPath $resolved -Recurse -Force
    if (Test-Path -LiteralPath $resolved) {
        throw "Directory still exists after cleanup: $resolved"
    }
}

function Get-GuiArgumentContract {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "GUI argument contract is missing: $Path"
    }
    $contractText = [System.IO.File]::ReadAllText(
        $Path,
        [System.Text.Encoding]::UTF8)
    $contract = $contractText | ConvertFrom-Json
    if ($null -eq $contract.arguments) {
        throw "GUI argument contract has no arguments map: $Path"
    }
    return $contract
}

# The native GUI has its own parser. Legacy .NET shortcuts carry flags such as
# --simple-mode; keeping unknown flags verbatim is what made the desktop
# shortcut exit immediately with "unknown argument".
function Resolve-SupportedGuiArguments {
    param(
        [AllowEmptyString()]
        [string]$Arguments,
        [Parameter(Mandatory = $true)]
        $Contract
    )

    $kept = New-Object System.Collections.Generic.List[string]
    $dropped = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($Arguments)) {
        $tokens = @(
            $Arguments -split "\s+" |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $index = 0
        while ($index -lt $tokens.Count) {
            $token = $tokens[$index]
            $entry = $Contract.arguments.PSObject.Properties[$token]
            if ($null -eq $entry) {
                $dropped.Add($token)
                $index += 1
                continue
            }
            $kept.Add($token)
            if ([bool]$entry.Value.takesValue) {
                if ($index + 1 -ge $tokens.Count) {
                    throw "Argument $token requires a value. Fix the shortcut before promoting."
                }
                $kept.Add($tokens[$index + 1])
                $index += 2
                continue
            }
            $index += 1
        }
    }
    return [pscustomobject]@{
        Arguments = ($kept -join " ")
        Dropped = @($dropped)
    }
}

# Launches the promoted GUI with the exact shortcut arguments under an
# isolated LOCALAPPDATA and a unique worker pipe. That proves the shortcut
# really starts a window without touching the user's saved power policy.
function Test-PromotedGuiLaunch {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Executable,
        [AllowEmptyString()]
        [string]$Arguments
    )

    if (-not (Test-Path -LiteralPath $Executable -PathType Leaf)) {
        throw "Promoted GUI is missing: $Executable"
    }
    $isolatedLocalAppData = Resolve-ArtifactPath (
        Join-Path $artifactsRoot "promotion-launch-$([Guid]::NewGuid().ToString('N'))")
    $pipeName = "AmdMobilePower.Worker.promote.$([Guid]::NewGuid().ToString('N').Substring(0, 8))"
    $previousLocalAppData = $env:LOCALAPPDATA
    $argumentList = @()
    if (-not [string]::IsNullOrWhiteSpace($Arguments)) {
        $argumentList += @(
            $Arguments -split "\s+" |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }
    $argumentList += @("--pipe-name", $pipeName)
    $process = $null
    try {
        New-Item -ItemType Directory -Path $isolatedLocalAppData -Force | Out-Null
        $env:LOCALAPPDATA = $isolatedLocalAppData
        $process = Start-Process `
            -FilePath $Executable `
            -WorkingDirectory (Split-Path -Parent $Executable) `
            -ArgumentList $argumentList `
            -PassThru
        $deadline = [DateTime]::UtcNow.AddSeconds(20)
        while ([DateTime]::UtcNow -lt $deadline) {
            $process.Refresh()
            if ($process.HasExited) {
                throw "Promoted GUI exited with code $($process.ExitCode). Arguments: $($argumentList -join ' ')"
            }
            if ($process.MainWindowHandle -ne [IntPtr]::Zero -and
                $process.MainWindowTitle -like "AMD Mobile Power*") {
                return [pscustomobject]@{
                    Result = "PASS"
                    Arguments = ($argumentList -join " ")
                    WindowTitle = $process.MainWindowTitle
                }
            }
            Start-Sleep -Milliseconds 250
        }
        throw "Promoted GUI did not create a window. Arguments: $($argumentList -join ' ')"
    }
    finally {
        if ($null -ne $process) {
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        }
        Get-CimInstance Win32_Process `
            -Filter "Name = 'amdmobilepower_native_worker.exe'" `
            -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -like "*$pipeName*" } |
            ForEach-Object {
                Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
            }
        $env:LOCALAPPDATA = $previousLocalAppData
        if (Test-Path -LiteralPath $isolatedLocalAppData) {
            try {
                Remove-VerifiedDirectory `
                    -Path $isolatedLocalAppData `
                    -ExpectedPath $isolatedLocalAppData `
                    -AllowedRoot $artifactsRoot
            }
            catch {
                Write-Warning "Launch fixture cleanup failed: $($_.Exception.Message)"
            }
        }
    }
}

function Get-ShortcutTargets {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,
        [Parameter(Mandatory = $true)]
        [string[]]$LegacyTargets
    )

    $items = @()
    if (-not (Test-Path -LiteralPath $Root)) {
        return $items
    }
    $shell = New-Object -ComObject WScript.Shell
    foreach ($shortcutFile in Get-ChildItem `
        -LiteralPath $Root `
        -Recurse `
        -Filter "*.lnk" `
        -ErrorAction SilentlyContinue) {
        $shortcut = $shell.CreateShortcut($shortcutFile.FullName)
        $matchesTarget = $false
        foreach ($candidate in $LegacyTargets) {
            if ($shortcut.TargetPath.Equals(
                $candidate,
                [System.StringComparison]::OrdinalIgnoreCase)) {
                $matchesTarget = $true
                break
            }
        }
        if ($matchesTarget) {
            $items += [pscustomobject]@{
                Path = $shortcutFile.FullName
                Target = $shortcut.TargetPath
                Arguments = $shortcut.Arguments
                WorkingDirectory = $shortcut.WorkingDirectory
                IconLocation = $shortcut.IconLocation
            }
        }
    }
    return $items
}

function Update-ShortcutTargets {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Shortcuts,
        [Parameter(Mandatory = $true)]
        [string]$NewTarget
    )

    $shell = New-Object -ComObject WScript.Shell
    foreach ($item in $Shortcuts) {
        $shortcut = $shell.CreateShortcut($item.Path)
        $shortcut.TargetPath = $NewTarget
        if ($null -ne $item.PSObject.Properties["ResolvedArguments"]) {
            $shortcut.Arguments = [string]$item.ResolvedArguments
        }
        $shortcut.WorkingDirectory = Split-Path -Parent $NewTarget
        $shortcut.IconLocation = "$NewTarget,0"
        $shortcut.Save()
    }
}

function Restore-ShortcutTargets {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Shortcuts
    )

    if ($Shortcuts.Count -eq 0) {
        return
    }
    $shell = New-Object -ComObject WScript.Shell
    foreach ($item in $Shortcuts) {
        if (-not (Test-Path -LiteralPath $item.Path)) {
            continue
        }
        $shortcut = $shell.CreateShortcut($item.Path)
        $shortcut.TargetPath = $item.Target
        $shortcut.Arguments = $item.Arguments
        $shortcut.WorkingDirectory = $item.WorkingDirectory
        $shortcut.IconLocation = $item.IconLocation
        $shortcut.Save()
    }
}

function Stop-TargetOwners {
    param([Parameter(Mandatory = $true)][string]$Target)

    $targetRoot = Get-NormalizedPath $Target
    $names = @(
        "amd-mobile-power-gui.exe",
        "amdmobilepower_native_worker.exe",
        "AmdMobilePower.exe",
        "AmdMobilePower.Worker.exe",
        "RyzenPower.exe",
        "ryzenadj.exe"
    )
    $filter = ($names | ForEach-Object { "Name='$_'" }) -join " OR "
    $candidates = @(
        Get-CimInstance `
            -ClassName Win32_Process `
            -Filter $filter `
            -ErrorAction SilentlyContinue)
    $stopped = @()
    foreach ($candidate in $candidates) {
        if ([string]::IsNullOrWhiteSpace($candidate.ExecutablePath)) {
            continue
        }
        $executable = Get-NormalizedPath $candidate.ExecutablePath
        if (-not (Test-PathWithinOrEqual $executable $targetRoot)) {
            continue
        }
        $record = [pscustomobject]@{
            ProcessId = [int]$candidate.ProcessId
            Name = [string]$candidate.Name
            ExecutablePath = $executable
        }
        Stop-Process `
            -Id $record.ProcessId `
            -Force `
            -ErrorAction SilentlyContinue
        $stopped += $record
    }

    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    do {
        $remaining = @(
            Get-CimInstance `
                -ClassName Win32_Process `
                -Filter $filter `
                -ErrorAction SilentlyContinue |
                Where-Object {
                    -not [string]::IsNullOrWhiteSpace($_.ExecutablePath) -and
                    (Test-PathWithinOrEqual `
                        (Get-NormalizedPath $_.ExecutablePath) `
                        $targetRoot)
                })
        if ($remaining.Count -eq 0) {
            break
        }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    if ($remaining.Count -gt 0) {
        $pids = ($remaining | ForEach-Object { $_.ProcessId }) -join ", "
        throw "Target-owned processes did not stop: $pids"
    }

    return [pscustomobject]@{
        Scope = "TargetDirectoryTreeOnly"
        Target = $targetRoot
        Stopped = @($stopped)
    }
}

function Read-ZipEntryText {
    param([Parameter(Mandatory = $true)]$Entry)

    $stream = $Entry.Open()
    try {
        $reader = [System.IO.StreamReader]::new(
            $stream,
            [System.Text.Encoding]::UTF8,
            $true)
        try {
            return $reader.ReadToEnd()
        }
        finally {
            $reader.Dispose()
        }
    }
    finally {
        $stream.Dispose()
    }
}

function Get-ZipEntrySha256 {
    param([Parameter(Mandatory = $true)]$Entry)

    $stream = $Entry.Open()
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $sha.ComputeHash($stream)
        return ([System.BitConverter]::ToString($bytes)).Replace("-", "").ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
        $stream.Dispose()
    }
}

function ConvertFrom-BuildInfoText {
    param(
        [AllowEmptyString()][string]$Text,
        [switch]$Required
    )

    $values = @{}
    foreach ($rawLine in ($Text -split "`r?`n")) {
        $line = $rawLine.TrimStart([char]0xFEFF)
        if ([string]::IsNullOrWhiteSpace($line) -or
            $line.TrimStart().StartsWith("#")) {
            continue
        }
        $separator = $line.IndexOf("=")
        if ($separator -le 0) {
            if ($Required) {
                throw "Invalid BUILD-INFO line: $line"
            }
            continue
        }
        $key = $line.Substring(0, $separator).Trim()
        $value = $line.Substring($separator + 1).Trim()
        if ($values.ContainsKey($key)) {
            if ($Required) {
                throw "Duplicate BUILD-INFO field: $key"
            }
            continue
        }
        $values[$key] = $value
    }

    $version = if ($values.ContainsKey("Version")) { [string]$values["Version"] } else { $null }
    $commit = if ($values.ContainsKey("Commit")) { [string]$values["Commit"] } else { $null }
    $workingTree = if ($values.ContainsKey("WorkingTree")) {
        [string]$values["WorkingTree"]
    }
    else {
        $null
    }

    if ($Required) {
        if ([string]::IsNullOrWhiteSpace($version) -or
            $version.Length -gt 128 -or
            $version -match "[\s/\\]") {
            throw "Package BUILD-INFO has an invalid Version."
        }
        if ($commit -notmatch "^[0-9a-fA-F]{40}$") {
            throw "Package BUILD-INFO has an invalid commit: $commit"
        }
        if (-not [string]::Equals(
            $workingTree,
            "Clean",
            [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Package BUILD-INFO WorkingTree must be Clean: $workingTree"
        }
    }

    return [pscustomobject]@{
        Version = $version
        Commit = $commit
        WorkingTree = $workingTree
        Values = $values
    }
}

function Get-PackageIdentity {
    param(
        [Parameter(Mandatory = $true)][string]$Package,
        [AllowNull()][string]$ExpectedHash,
        [AllowNull()][string]$ExpectedCommit
    )

    $packageHash = Get-FileSha256Hex -Path $Package
    if ($ExpectedHash -and $packageHash -ne $ExpectedHash.ToLowerInvariant()) {
        throw "Package SHA256 mismatch: actual=$packageHash expected=$($ExpectedHash.ToLowerInvariant())"
    }

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead($Package)
    try {
        $seen = New-Object `
            'System.Collections.Generic.HashSet[string]' `
            ([System.StringComparer]::OrdinalIgnoreCase)
        $allEntries = @()
        foreach ($entry in $archive.Entries) {
            $name = $entry.FullName.Replace("\", "/")
            if ([string]::IsNullOrWhiteSpace($name)) {
                throw "Package contains an empty ZIP entry name."
            }
            if (-not $seen.Add($name)) {
                throw "Package contains a duplicate ZIP entry: $name"
            }
            $allEntries += [pscustomobject]@{
                Name = $name
                Entry = $entry
                IsDirectory = $name.EndsWith("/")
            }
        }

        $fileEntries = @($allEntries | Where-Object { -not $_.IsDirectory })
        if ($fileEntries.Count -eq 0) {
            throw "Package ZIP contains no files."
        }

        $rootName = $null
        $entryByName = @{}
        foreach ($item in $fileEntries) {
            if ($item.Name.StartsWith("/") -or
                $item.Name -match "^[A-Za-z]:" -or
                $item.Name.Split("/") -contains "..") {
                throw "Package contains an unsafe ZIP path: $($item.Name)"
            }
            $segments = $item.Name.Split("/")
            if ($segments.Count -lt 2) {
                throw "Every package file must be under one top-level directory: $($item.Name)"
            }
            if ($null -eq $rootName) {
                $rootName = $segments[0]
            }
            elseif (-not [string]::Equals(
                $rootName,
                $segments[0],
                [System.StringComparison]::OrdinalIgnoreCase)) {
                throw "Package ZIP must have exactly one top-level directory."
            }
            $entryByName[$item.Name] = $item.Entry
        }
        if ([string]::IsNullOrWhiteSpace($rootName) -or
            $rootName -eq "." -or
            $rootName -eq "..") {
            throw "Package ZIP has an invalid top-level directory."
        }

        $buildInfoName = "$rootName/BUILD-INFO.txt"
        $buildInfoEntries = @(
            $fileEntries |
                Where-Object {
                    [string]::Equals(
                        $_.Name,
                        $buildInfoName,
                        [System.StringComparison]::OrdinalIgnoreCase)
                })
        $anyBuildInfoEntries = @(
            $fileEntries |
                Where-Object {
                    [string]::Equals(
                        [System.IO.Path]::GetFileName($_.Name),
                        "BUILD-INFO.txt",
                        [System.StringComparison]::OrdinalIgnoreCase)
                })
        if ($buildInfoEntries.Count -ne 1 -or
            $anyBuildInfoEntries.Count -ne 1) {
            throw "Package ZIP must contain exactly one top-level BUILD-INFO.txt."
        }
        $buildInfo = ConvertFrom-BuildInfoText `
            -Text (Read-ZipEntryText -Entry $buildInfoEntries[0].Entry) `
            -Required
        if ($ExpectedCommit -and
            -not [string]::Equals(
                $buildInfo.Commit,
                $ExpectedCommit,
                [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Package source commit mismatch: actual=$($buildInfo.Commit) expected=$ExpectedCommit"
        }

        $checksumName = "$rootName/SHA256SUMS.txt"
        $checksumEntries = @(
            $fileEntries |
                Where-Object {
                    [string]::Equals(
                        $_.Name,
                        $checksumName,
                        [System.StringComparison]::OrdinalIgnoreCase)
                })
        if ($checksumEntries.Count -ne 1) {
            throw "Package ZIP must contain exactly one top-level SHA256SUMS.txt."
        }

        $payloadHashes = @{}
        $checksumText = Read-ZipEntryText -Entry $checksumEntries[0].Entry
        foreach ($rawLine in ($checksumText -split "`r?`n")) {
            $line = $rawLine.TrimStart([char]0xFEFF)
            if ([string]::IsNullOrWhiteSpace($line)) {
                continue
            }
            if ($line -notmatch "^([0-9a-fA-F]{64}) [ *](.+)$") {
                throw "Invalid SHA256SUMS entry: $line"
            }
            $expected = $Matches[1].ToLowerInvariant()
            $relative = $Matches[2].Trim().Replace("\", "/")
            while ($relative.StartsWith("./")) {
                $relative = $relative.Substring(2)
            }
            if ([string]::IsNullOrWhiteSpace($relative) -or
                $relative.StartsWith("/") -or
                $relative -match "^[A-Za-z]:" -or
                $relative.Split("/") -contains ".." -or
                $relative.Split("/") -contains ".") {
                throw "Unsafe SHA256SUMS path: $relative"
            }
            if ([string]::Equals(
                $relative,
                "SHA256SUMS.txt",
                [System.StringComparison]::OrdinalIgnoreCase)) {
                continue
            }
            if ($payloadHashes.ContainsKey($relative)) {
                throw "Duplicate SHA256SUMS entry: $relative"
            }

            $zipName = "$rootName/$relative"
            if (-not $entryByName.ContainsKey($zipName)) {
                throw "SHA256SUMS target is missing from ZIP: $relative"
            }
            $actual = Get-ZipEntrySha256 -Entry $entryByName[$zipName]
            if ($actual -ne $expected) {
                throw "Package checksum mismatch for ${relative}: $actual != $expected"
            }
            $payloadHashes[$relative] = $actual
        }
        if ($payloadHashes.Count -eq 0) {
            throw "Package SHA256SUMS.txt is empty."
        }

        foreach ($item in $fileEntries) {
            if ([string]::Equals(
                $item.Name,
                $checksumName,
                [System.StringComparison]::OrdinalIgnoreCase)) {
                continue
            }
            $relative = $item.Name.Substring($rootName.Length + 1)
            if (-not $payloadHashes.ContainsKey($relative)) {
                throw "SHA256SUMS.txt does not cover payload file: $relative"
            }
        }

        $coreNames = @(
            "amd-mobile-power-gui.exe",
            "amdmobilepower_native_worker.exe",
            "amd-mobile-power-probe.exe"
        )
        foreach ($coreName in $coreNames) {
            if (-not $payloadHashes.ContainsKey($coreName)) {
                throw "SHA256SUMS.txt is missing core binary: $coreName"
            }
        }

        $coreHashes = [ordered]@{
            Gui = $payloadHashes["amd-mobile-power-gui.exe"]
            Worker = $payloadHashes["amdmobilepower_native_worker.exe"]
            Probe = $payloadHashes["amd-mobile-power-probe.exe"]
        }
        return [pscustomobject]@{
            PackageSHA256 = $packageHash
            RootName = $rootName
            Version = $buildInfo.Version
            SourceCommit = $buildInfo.Commit.ToLowerInvariant()
            WorkingTree = $buildInfo.WorkingTree
            PayloadHashes = $payloadHashes
            PayloadEntryCount = $payloadHashes.Count
            CoreHashes = $coreHashes
            IdentityBound = [bool]($ExpectedHash -and $ExpectedCommit)
        }
    }
    finally {
        $archive.Dispose()
    }
}

function Get-DirectoryBuildInfo {
    param([Parameter(Mandatory = $true)][string]$Directory)

    $path = Join-Path $Directory "BUILD-INFO.txt"
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return [pscustomobject]@{
            Present = $false
            Version = $null
            Commit = $null
            WorkingTree = $null
            ParseError = $null
            SHA256 = $null
        }
    }
    $text = [System.IO.File]::ReadAllText(
        $path,
        [System.Text.Encoding]::UTF8)
    $parseError = $null
    try {
        $info = ConvertFrom-BuildInfoText -Text $text
    }
    catch {
        $parseError = $_.Exception.Message
        $info = [pscustomobject]@{
            Version = $null
            Commit = $null
            WorkingTree = $null
        }
    }
    return [pscustomobject]@{
        Present = $true
        Version = $info.Version
        Commit = if ($info.Commit) { $info.Commit.ToLowerInvariant() } else { $null }
        WorkingTree = $info.WorkingTree
        ParseError = $parseError
        SHA256 = Get-FileSha256Hex -Path $path
    }
}

function Verify-InstalledPayload {
    param(
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)]$PayloadHashes
    )

    $verified = [ordered]@{}
    foreach ($relative in @($PayloadHashes.Keys | Sort-Object)) {
        $installedPath = Join-Path $Target ($relative.Replace("/", "\"))
        if (-not (Test-Path -LiteralPath $installedPath -PathType Leaf)) {
            throw "Installed payload is missing: $relative"
        }
        $actual = Get-FileSha256Hex -Path $installedPath
        $expected = [string]$PayloadHashes[$relative]
        if ($actual -ne $expected) {
            throw "Installed checksum mismatch for ${relative}: $actual != $expected"
        }
        $verified[$relative] = $actual
    }
    return [pscustomobject]@{
        Gui = $verified["amd-mobile-power-gui.exe"]
        Worker = $verified["amdmobilepower_native_worker.exe"]
        Probe = $verified["amd-mobile-power-probe.exe"]
        Payload = $verified
    }
}

$expectedHashProvided = -not [string]::IsNullOrWhiteSpace($ExpectedPackageSHA256)
$expectedCommitProvided = -not [string]::IsNullOrWhiteSpace($ExpectedSourceCommit)
if ($expectedHashProvided -xor $expectedCommitProvided) {
    throw "ExpectedPackageSHA256 and ExpectedSourceCommit must be supplied together."
}
if ($expectedHashProvided -and $ExpectedPackageSHA256 -notmatch "^[0-9a-fA-F]{64}$") {
    throw "ExpectedPackageSHA256 must be exactly 64 hexadecimal characters."
}
if ($expectedCommitProvided -and $ExpectedSourceCommit -notmatch "^[0-9a-fA-F]{40}$") {
    throw "ExpectedSourceCommit must be exactly 40 hexadecimal characters."
}
if ($expectedHashProvided) {
    $ExpectedPackageSHA256 = $ExpectedPackageSHA256.ToLowerInvariant()
}
if ($expectedCommitProvided) {
    $ExpectedSourceCommit = $ExpectedSourceCommit.ToLowerInvariant()
}

$resolvedPackage = (Resolve-Path -LiteralPath $PackagePath).Path
if (-not $resolvedPackage.EndsWith(
    ".zip",
    [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "PackagePath must point to a ZIP: $resolvedPackage"
}

$packageIdentity = Get-PackageIdentity `
    -Package $resolvedPackage `
    -ExpectedHash $(if ($expectedHashProvided) { $ExpectedPackageSHA256 } else { $null }) `
    -ExpectedCommit $(if ($expectedCommitProvided) { $ExpectedSourceCommit } else { $null })

$targetInfo = Assert-AllowedTargetPath $TargetDirectory
$resolvedTarget = $targetInfo.Path
$targetExists = Test-Path -LiteralPath $resolvedTarget -PathType Container
$previousBuildInfo = if ($targetExists) {
    Get-DirectoryBuildInfo -Directory $resolvedTarget
}
else {
    [pscustomobject]@{
        Present = $false
        Version = $null
        Commit = $null
        WorkingTree = $null
        ParseError = $null
        SHA256 = $null
    }
}
$isSameVersion = [bool](
    $targetExists -and
    $previousBuildInfo.Version -and
    [string]::Equals(
        $previousBuildInfo.Version,
        $packageIdentity.Version,
        [System.StringComparison]::OrdinalIgnoreCase))
$isSameCommit = [bool](
    $targetExists -and
    $previousBuildInfo.Commit -and
    [string]::Equals(
        $previousBuildInfo.Commit,
        $packageIdentity.SourceCommit,
        [System.StringComparison]::OrdinalIgnoreCase))
$backupKind = if (-not $targetExists) {
    "None"
}
elseif ($isSameVersion) {
    "SameVersion"
}
elseif ($previousBuildInfo.Present) {
    "PreviousStable"
}
else {
    "UnknownPrevious"
}

if (-not $BackupDirectory) {
    $versionSuffix = if ($previousBuildInfo.Version) {
        "-v$($previousBuildInfo.Version -replace '[^0-9A-Za-z._-]', '_')"
    }
    else {
        ""
    }
    $commitSuffix = if ($previousBuildInfo.Commit) {
        "-$($previousBuildInfo.Commit.Substring(0, 7))"
    }
    else {
        ""
    }
    $sameSuffix = if ($isSameVersion) { "-same" } else { "" }
    $BackupDirectory = "$resolvedTarget.before-" +
        "$(Get-Date -Format 'yyyyMMdd-HHmmssfff')" +
        "$versionSuffix$commitSuffix$sameSuffix"
}
$resolvedBackup = Assert-AllowedBackupPath `
    -Path $BackupDirectory `
    -Target $resolvedTarget

$packageLeaf = [System.IO.Path]::GetFileNameWithoutExtension($resolvedPackage)
if (-not $EvidencePath) {
    $EvidencePath = Join-Path `
        $artifactsRoot `
        "deployment-backups\promote-$packageLeaf-$(Get-Date -Format 'yyyyMMdd-HHmmssfff').json"
}
$resolvedEvidence = Assert-AllowedEvidencePath `
    -Path $EvidencePath `
    -Target $resolvedTarget `
    -Backup $resolvedBackup

$stagingRoot = Assert-AllowedStagingPath `
    -Path (Join-Path `
        $stagingParentRoot `
        "promotion-staging-$([Guid]::NewGuid().ToString('N'))") `
    -Target $resolvedTarget `
    -Backup $resolvedBackup

function Protect-PublicPath([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $Value
    }
    return [regex]::Replace(
        $Value,
        '(?i)C:[\\/]+Users[\\/]+(?!Public(?:[\\/]|$))[A-Za-z0-9._-]+',
        '%USERPROFILE%')
}

$desktopRoots = @(
    [Environment]::GetFolderPath("Desktop"),
    "C:\Users\Public\Desktop"
) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique
$programsRoot = [Environment]::GetFolderPath("Programs")
$legacyGui = Join-Path $resolvedTarget "AmdMobilePower.exe"
$nativeGui = Join-Path $resolvedTarget "amd-mobile-power-gui.exe"
$shortcutTargets = @($legacyGui, $nativeGui)
$shortcutSnapshots = @()
if (-not $SkipShellIntegration) {
    foreach ($rootPath in $desktopRoots) {
        $shortcutSnapshots += @(Get-ShortcutTargets `
            -Root $rootPath `
            -LegacyTargets $shortcutTargets)
    }
    if ($programsRoot) {
        $shortcutSnapshots += @(Get-ShortcutTargets `
            -Root $programsRoot `
            -LegacyTargets $shortcutTargets)
    }
}

$guiContract = $null
$explicitArguments = $null
if ($GuiArguments -or $shortcutSnapshots.Count -gt 0) {
    $guiContract = Get-GuiArgumentContract -Path $guiArgumentContractPath
    if ($GuiArguments) {
        $parsed = Resolve-SupportedGuiArguments `
            -Arguments $GuiArguments `
            -Contract $guiContract
        if (@($parsed.Dropped).Count -gt 0) {
            throw ("GuiArguments contains arguments the GUI rejects: " +
                (@($parsed.Dropped) -join ", "))
        }
        $explicitArguments = $parsed.Arguments
    }
}
if ($shortcutSnapshots.Count -gt 0) {
    foreach ($snapshot in $shortcutSnapshots) {
        $sourceArguments = $snapshot.Arguments
        if ($null -ne $explicitArguments) {
            $sourceArguments = $explicitArguments
        }
        $resolved = Resolve-SupportedGuiArguments `
            -Arguments $sourceArguments `
            -Contract $guiContract
        $snapshot | Add-Member `
            -NotePropertyName ResolvedArguments `
            -NotePropertyValue $resolved.Arguments `
            -Force
        $snapshot | Add-Member `
            -NotePropertyName DroppedArguments `
            -NotePropertyValue @($resolved.Dropped) `
            -Force
    }
}

$plan = [ordered]@{
    Package = $resolvedPackage
    PackageSHA256 = $packageIdentity.PackageSHA256
    ExpectedPackageSHA256 = if ($expectedHashProvided) { $ExpectedPackageSHA256 } else { $null }
    ExpectedSourceCommit = if ($expectedCommitProvided) { $ExpectedSourceCommit } else { $null }
    IdentityBound = $packageIdentity.IdentityBound
    PackageVersion = $packageIdentity.Version
    SourceCommit = $packageIdentity.SourceCommit
    WorkingTree = $packageIdentity.WorkingTree
    PayloadChecksumEntries = $packageIdentity.PayloadEntryCount
    CoreHashes = $packageIdentity.CoreHashes
    Target = $resolvedTarget
    TargetScope = $targetInfo.Scope
    PreviousVersion = $previousBuildInfo.Version
    PreviousCommit = $previousBuildInfo.Commit
    PreviousWorkingTree = $previousBuildInfo.WorkingTree
    PreviousBuildInfoStatus = if (-not $previousBuildInfo.Present) {
        "Missing"
    }
    elseif ($previousBuildInfo.ParseError) {
        "Invalid"
    }
    else {
        "Present"
    }
    Backup = $resolvedBackup
    BackupKind = $backupKind
    IsSameVersion = $isSameVersion
    IsSameCommit = $isSameCommit
    Evidence = $resolvedEvidence
    Staging = $stagingRoot
    ProcessStopScope = "TargetDirectoryTreeOnly"
    GuiArguments = $GuiArguments
    LegacyShortcuts = @($shortcutSnapshots | ForEach-Object {
        Protect-PublicPath $_.Path
    })
    ShortcutArguments = @($shortcutSnapshots | ForEach-Object {
        [pscustomobject]@{
            Path = Protect-PublicPath $_.Path
            Before = $_.Arguments
            After = $_.ResolvedArguments
            Dropped = @($_.DroppedArguments)
        }
    })
    Apply = [bool]$Apply
    NoLaunch = [bool]$NoLaunch
}
if (-not $Apply) {
    [pscustomobject]$plan | Format-List
    Write-Output "Dry run only. Re-run with -Apply to replace the target."
    return
}

$targetMoved = $false
$installStarted = $false
$shortcutsTouched = $false
$stagingCreated = $false
$stoppedProcesses = @()
$deployedHashes = $null
$launchResult = "Skipped"

try {
    $stopResult = Stop-TargetOwners -Target $resolvedTarget
    $stoppedProcesses = @($stopResult.Stopped)

    New-Item -ItemType Directory -Path $stagingRoot -Force | Out-Null
    $stagingCreated = $true
    Expand-Archive -LiteralPath $resolvedPackage -DestinationPath $stagingRoot
    $topLevelDirectories = @(
        Get-ChildItem -LiteralPath $stagingRoot -Directory -Force)
    if ($topLevelDirectories.Count -ne 1) {
        throw "Expanded package must contain exactly one top-level directory."
    }
    $packageDirectory = $topLevelDirectories[0].FullName
    $expectedPackageDirectory = Join-Path $stagingRoot $packageIdentity.RootName
    if (-not (Test-SamePath $packageDirectory $expectedPackageDirectory)) {
        throw "Expanded package root does not match BUILD-INFO identity: $packageDirectory"
    }

    if (Test-Path -LiteralPath $resolvedTarget) {
        if (Test-Path -LiteralPath $resolvedBackup) {
            throw "Backup path already exists: $resolvedBackup"
        }
        $targetFinal = Get-FinalExistingPath $resolvedTarget
        if (-not (Test-SamePath $targetFinal $resolvedTarget)) {
            throw "Target changed to a link or junction before move: $targetFinal"
        }
        Move-Item `
            -LiteralPath $resolvedTarget `
            -Destination $resolvedBackup
        $targetMoved = $true
    }

    $installerPath = Join-Path $packageDirectory "install-preview.ps1"
    if (-not (Test-Path -LiteralPath $installerPath -PathType Leaf)) {
        throw "Package install-preview.ps1 is missing: $installerPath"
    }
    $installStarted = $true
    $windowsPowerShell = Join-Path `
        $env:SystemRoot `
        "System32\WindowsPowerShell\v1.0\powershell.exe"
    & $windowsPowerShell `
        -NoProfile `
        -ExecutionPolicy Bypass `
        -File $installerPath `
        -InstallDirectory $resolvedTarget `
        -NoStartup `
        -NoShellIntegration `
        -NoLaunch
    if ($LASTEXITCODE -ne 0) {
        throw "install-preview.ps1 failed with exit code $LASTEXITCODE."
    }

    $deployedHashes = Verify-InstalledPayload `
        -Target $resolvedTarget `
        -PayloadHashes $packageIdentity.PayloadHashes
    $installedBuildInfo = Get-DirectoryBuildInfo -Directory $resolvedTarget
    if (-not $installedBuildInfo.Present) {
        throw "Installed target is missing BUILD-INFO.txt."
    }
    if (-not [string]::Equals(
        $installedBuildInfo.Version,
        $packageIdentity.Version,
        [System.StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals(
            $installedBuildInfo.Commit,
            $packageIdentity.SourceCommit,
            [System.StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals(
            $installedBuildInfo.WorkingTree,
            "Clean",
            [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Installed BUILD-INFO does not match the verified package identity."
    }

    if (-not $SkipShellIntegration -and $shortcutSnapshots.Count -gt 0) {
        $shortcutsTouched = $true
        Update-ShortcutTargets `
            -Shortcuts $shortcutSnapshots `
            -NewTarget (Join-Path $resolvedTarget "amd-mobile-power-gui.exe")
    }

    $primaryShortcutArguments = ""
    if ($shortcutSnapshots.Count -gt 0) {
        $primaryShortcutArguments = [string]$shortcutSnapshots[0].ResolvedArguments
    }
    if (-not $NoLaunch) {
        $launch = Test-PromotedGuiLaunch `
            -Executable (Join-Path $resolvedTarget "amd-mobile-power-gui.exe") `
            -Arguments $primaryShortcutArguments
        $launchResult = $launch.Result
    }

    $evidenceDirectory = Split-Path -Parent $resolvedEvidence
    if ($evidenceDirectory) {
        New-Item -ItemType Directory -Path $evidenceDirectory -Force | Out-Null
    }
    if (Test-Path -LiteralPath $resolvedEvidence) {
        throw "Evidence path was created concurrently: $resolvedEvidence"
    }
    $evidence = [ordered]@{
        Verification = "PASS"
        Package = $resolvedPackage
        PackageSHA256 = $packageIdentity.PackageSHA256
        ExpectedPackageSHA256 = if ($expectedHashProvided) { $ExpectedPackageSHA256 } else { $null }
        ExpectedSourceCommit = if ($expectedCommitProvided) { $ExpectedSourceCommit } else { $null }
        IdentityBound = $packageIdentity.IdentityBound
        PackageVersion = $packageIdentity.Version
        SourceCommit = $packageIdentity.SourceCommit
        WorkingTree = $packageIdentity.WorkingTree
        PayloadChecksumEntries = $packageIdentity.PayloadEntryCount
        DeployedHashes = [ordered]@{
            Gui = $deployedHashes.Gui
            Worker = $deployedHashes.Worker
            Probe = $deployedHashes.Probe
            Payload = $deployedHashes.Payload
        }
        Target = $resolvedTarget
        TargetScope = $targetInfo.Scope
        ProcessStopScope = "TargetDirectoryTreeOnly"
        StoppedProcesses = @($stoppedProcesses | ForEach-Object {
            [ordered]@{
                ProcessId = $_.ProcessId
                Name = $_.Name
                ExecutablePath = Protect-PublicPath $_.ExecutablePath
            }
        })
        PreviousVersion = $previousBuildInfo.Version
        PreviousCommit = $previousBuildInfo.Commit
        PreviousWorkingTree = $previousBuildInfo.WorkingTree
        PreviousBuildInfoStatus = if (-not $previousBuildInfo.Present) {
            "Missing"
        }
        elseif ($previousBuildInfo.ParseError) {
            "Invalid"
        }
        else {
            "Present"
        }
        Backup = $resolvedBackup
        BackupKind = $backupKind
        IsSameVersion = $isSameVersion
        IsSameCommit = $isSameCommit
        GuiArguments = $GuiArguments
        ShortcutsUpdated = @($shortcutSnapshots | ForEach-Object {
            Protect-PublicPath $_.Path
        })
        ShortcutArguments = @($shortcutSnapshots | ForEach-Object {
            [pscustomobject]@{
                Path = Protect-PublicPath $_.Path
                Before = $_.Arguments
                After = $_.ResolvedArguments
                Dropped = @($_.DroppedArguments)
            }
        })
        LaunchVerification = $launchResult
        Launched = (-not $NoLaunch)
        RecordedAt = (Get-Date).ToString("o")
    }
    [System.IO.File]::WriteAllText(
        $resolvedEvidence,
        ($evidence | ConvertTo-Json -Depth 10),
        (New-Object System.Text.UTF8Encoding($false)))
    [System.IO.File]::ReadAllText(
        $resolvedEvidence,
        [System.Text.Encoding]::UTF8)
}
catch {
    $failure = $_
    $rollbackErrors = @()
    $failureRollbackState = "Failed"
    try {
        $rollbackStop = Stop-TargetOwners -Target $resolvedTarget
        if (@($rollbackStop.Stopped).Count -gt 0) {
            $stoppedProcesses += @($rollbackStop.Stopped)
        }
        if ($shortcutsTouched) {
            Restore-ShortcutTargets -Shortcuts $shortcutSnapshots
            $shortcutsTouched = $false
        }
        if (($targetMoved -or $installStarted) -and
            (Test-Path -LiteralPath $resolvedTarget)) {
            Remove-VerifiedDirectory `
                -Path $resolvedTarget `
                -ExpectedPath $resolvedTarget
        }
        if ($targetMoved) {
            if (-not (Test-Path -LiteralPath $resolvedBackup -PathType Container)) {
                throw "Backup is missing during rollback: $resolvedBackup"
            }
            $backupFinal = Get-FinalExistingPath $resolvedBackup
            if (-not (Test-SamePath $backupFinal $resolvedBackup)) {
                throw "Backup resolves through a link or junction: $backupFinal"
            }
            Move-Item `
                -LiteralPath $resolvedBackup `
                -Destination $resolvedTarget
            $targetMoved = $false
        }
        if ($previousBuildInfo.SHA256) {
            $restoredBuildInfo = Get-DirectoryBuildInfo -Directory $resolvedTarget
            if ($restoredBuildInfo.SHA256 -ne $previousBuildInfo.SHA256) {
                throw "Restored target BUILD-INFO hash does not match the pre-move snapshot."
            }
        }
        $failureRollbackState = if ($installStarted -or $previousBuildInfo.SHA256) {
            "Completed"
        }
        else {
            "NotNeeded"
        }
    }
    catch {
        $failureRollbackState = "Failed"
        $rollbackErrors += $_.Exception.Message
    }

    Write-Error (
        "Deployment failed. Rollback=$failureRollbackState. " +
        "Original error: $($failure.Exception.Message)") `
        -ErrorAction Continue
    if ($rollbackErrors.Count -gt 0) {
        Write-Error (
            "Rollback errors: " + ($rollbackErrors -join " | ")) `
            -ErrorAction Continue
    }
    try {
        $failureEvidenceDirectory = Split-Path -Parent $resolvedEvidence
        if ($failureEvidenceDirectory) {
            New-Item -ItemType Directory -Path $failureEvidenceDirectory -Force | Out-Null
        }
        if (-not (Test-Path -LiteralPath $resolvedEvidence)) {
            $failureEvidence = [ordered]@{
                Verification = "FAIL"
                Package = $resolvedPackage
                PackageSHA256 = $packageIdentity.PackageSHA256
                ExpectedPackageSHA256 = if ($expectedHashProvided) { $ExpectedPackageSHA256 } else { $null }
                ExpectedSourceCommit = if ($expectedCommitProvided) { $ExpectedSourceCommit } else { $null }
                IdentityBound = $packageIdentity.IdentityBound
                PackageVersion = $packageIdentity.Version
                SourceCommit = $packageIdentity.SourceCommit
                Target = $resolvedTarget
                PreviousVersion = $previousBuildInfo.Version
                PreviousCommit = $previousBuildInfo.Commit
                Backup = $resolvedBackup
                BackupKind = $backupKind
                Rollback = $failureRollbackState
                RollbackErrors = @($rollbackErrors)
                Error = $failure.Exception.Message
                RecordedAt = (Get-Date).ToString("o")
            }
            [System.IO.File]::WriteAllText(
                $resolvedEvidence,
                ($failureEvidence | ConvertTo-Json -Depth 8),
                (New-Object System.Text.UTF8Encoding($false)))
        }
    }
    catch {
        Write-Warning "Deployment failure evidence could not be written: $($_.Exception.Message)"
    }
    throw $failure
}
finally {
    if ($stagingCreated -and (Test-Path -LiteralPath $stagingRoot)) {
        try {
            Remove-VerifiedDirectory `
                -Path $stagingRoot `
                -ExpectedPath $stagingRoot `
                -AllowedRoot $stagingParentRoot
        }
        catch {
            Write-Warning "Staging cleanup failed: $($_.Exception.Message)"
        }
    }
}
