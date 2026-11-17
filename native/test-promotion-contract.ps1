param([switch]$KeepArtifacts)

$ErrorActionPreference = "Stop"

$nativeRoot = $PSScriptRoot
$repositoryRoot = Split-Path -Parent $nativeRoot
$artifactsRoot = [System.IO.Path]::GetFullPath(
    (Join-Path $repositoryRoot "artifacts"))
$verifyRoot = [System.IO.Path]::GetFullPath(
    (Join-Path $artifactsRoot "verify"))
$contractRoot = [System.IO.Path]::GetFullPath(
    (Join-Path $verifyRoot "promotion-contract-$([Guid]::NewGuid().ToString('N'))"))
$promoteScript = Join-Path $nativeRoot "promote-stable-deployment.ps1"
$windowsPowerShell = Join-Path `
    $env:SystemRoot `
    "System32\WindowsPowerShell\v1.0\powershell.exe"
$stableTarget = [System.IO.Path]::GetFullPath("C:\RyzenAdj")
$results = [ordered]@{}
$fakeProcesses = New-Object System.Collections.Generic.List[System.Diagnostics.Process]
$preStagingNames = @()

function Assert-UnderContractRoot {
    param([Parameter(Mandatory = $true)][string]$Path)

    $resolved = [System.IO.Path]::GetFullPath($Path)
    $prefix = $contractRoot.TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar) +
        [System.IO.Path]::DirectorySeparatorChar
    if (-not [string]::Equals(
        $resolved,
        $contractRoot,
        [System.StringComparison]::OrdinalIgnoreCase) -and
        -not $resolved.StartsWith(
        $prefix,
        [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Unsafe contract path: $resolved"
    }
    return $resolved
}

function Get-RelativePathCompat {
    param(
        [Parameter(Mandatory = $true)][string]$Base,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $baseFull = [System.IO.Path]::GetFullPath($Base).TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar) +
        [System.IO.Path]::DirectorySeparatorChar
    $pathFull = [System.IO.Path]::GetFullPath($Path)
    if (-not $pathFull.StartsWith(
        $baseFull,
        [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Path is not under base: $pathFull"
    }
    return $pathFull.Substring($baseFull.Length).Replace("\", "/")
}

function Add-Result {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][bool]$Pass,
        [AllowEmptyString()][string]$Detail
    )

    $script:results[$Name] = [ordered]@{
        Pass = $Pass
        Detail = $Detail
    }
    Write-Host ("{0} {1} :: {2}" -f (
        $(if ($Pass) { "PASS" } else { "FAIL" })), $Name, $Detail)
}

function Write-AsciiFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Text
    )

    [System.IO.File]::WriteAllText(
        $Path,
        $Text,
        (New-Object System.Text.ASCIIEncoding))
}

function Get-TestFileSha256 {
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

function Write-Utf8BomFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Text
    )

    [System.IO.File]::WriteAllText(
        $Path,
        $Text,
        (New-Object System.Text.UTF8Encoding($true)))
}

function Add-ZipBytes {
    param(
        [Parameter(Mandatory = $true)]$Archive,
        [Parameter(Mandatory = $true)][string]$EntryName,
        [Parameter(Mandatory = $true)][byte[]]$Bytes
    )

    $entry = $Archive.CreateEntry(
        $EntryName,
        [System.IO.Compression.CompressionLevel]::Optimal)
    $stream = $entry.Open()
    try {
        $stream.Write($Bytes, 0, $Bytes.Length)
    }
    finally {
        $stream.Dispose()
    }
}

function New-TestPackage {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Version,
        [Parameter(Mandatory = $true)][string]$Commit,
        [string]$WorkingTree = "Clean",
        [switch]$MissingBuildInfo,
        [switch]$DuplicateBuildInfo,
        [switch]$DuplicateEntry,
        [switch]$CorruptInstalledGui,
        [switch]$InstallFails
    )

    $rootName = "amd-mobile-power-v$Version-contract-$Name"
    $source = Assert-UnderContractRoot (
        Join-Path $contractRoot "packages\$Name\source")
    $zipPath = Assert-UnderContractRoot (
        Join-Path $contractRoot "packages\$Name\$rootName.zip")
    New-Item -ItemType Directory -Path $source -Force | Out-Null

    $fakeInstaller = @'
param(
    [Parameter(Mandatory = $true)][string]$InstallDirectory,
    [switch]$NoStartup,
    [switch]$NoShellIntegration,
    [switch]$NoLaunch
)
$ErrorActionPreference = "Stop"
$target = [System.IO.Path]::GetFullPath($InstallDirectory)
$parent = Split-Path -Parent $target
New-Item -ItemType Directory -Path $parent -Force | Out-Null
New-Item -ItemType Directory -Path $target -Force | Out-Null
Get-ChildItem -LiteralPath $PSScriptRoot -Force |
    Copy-Item -Destination $target -Recurse -Force
if ($__CORRUPT__) {
    [System.IO.File]::WriteAllText(
        (Join-Path $target "amd-mobile-power-gui.exe"),
        "corrupted by promotion contract fixture")
}
if ($__FAIL__) {
    throw "contract installer failure"
}
[System.IO.File]::WriteAllText(
    (Join-Path $target "NATIVE-PREVIEW-INSTALL.txt"),
    "promotion contract fixture")
'@
    $fakeInstaller = $fakeInstaller.Replace(
        '$__CORRUPT__',
        $(if ($CorruptInstalledGui) { '$true' } else { '$false' }))
    $fakeInstaller = $fakeInstaller.Replace(
        '$__FAIL__',
        $(if ($InstallFails) { '$true' } else { '$false' }))

    Write-AsciiFile `
        -Path (Join-Path $source "amd-mobile-power-gui.exe") `
        -Text "gui:$Name"
    Write-AsciiFile `
        -Path (Join-Path $source "amdmobilepower_native_worker.exe") `
        -Text "worker:$Name"
    Write-AsciiFile `
        -Path (Join-Path $source "amd-mobile-power-probe.exe") `
        -Text "probe:$Name"
    Write-AsciiFile `
        -Path (Join-Path $source "install-preview.ps1") `
        -Text $fakeInstaller

    if (-not $MissingBuildInfo) {
        Write-Utf8BomFile `
            -Path (Join-Path $source "BUILD-INFO.txt") `
            -Text (
                "Name=$rootName`r`n" +
                "Version=$Version`r`n" +
                "Commit=$Commit`r`n" +
                "WorkingTree=$WorkingTree`r`n" +
                "Platform=win-x64`r`n" +
                "Native=True`r`n")
    }
    if ($DuplicateBuildInfo) {
        $nested = Join-Path $source "nested"
        New-Item -ItemType Directory -Path $nested -Force | Out-Null
        Write-Utf8BomFile `
            -Path (Join-Path $nested "BUILD-INFO.txt") `
            -Text "Version=duplicate`r`nCommit=$Commit`r`nWorkingTree=Clean`r`n"
    }
    if ($DuplicateEntry) {
        Write-AsciiFile `
            -Path (Join-Path $source "duplicate.txt") `
            -Text "duplicate payload"
    }

    $payloadHashes = @{}
    $checksumLines = @()
    foreach ($file in Get-ChildItem -LiteralPath $source -File -Recurse |
        Sort-Object FullName) {
        $relative = Get-RelativePathCompat -Base $source -Path $file.FullName
        $hash = Get-TestFileSha256 -Path $file.FullName
        $payloadHashes[$relative] = $hash
        $checksumLines += "$hash  $relative"
    }
    Write-AsciiFile `
        -Path (Join-Path $source "SHA256SUMS.txt") `
        -Text (($checksumLines -join "`r`n") + "`r`n")

    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $fileStream = [System.IO.File]::Open(
        $zipPath,
        [System.IO.FileMode]::Create,
        [System.IO.FileAccess]::ReadWrite,
        [System.IO.FileShare]::None)
    try {
        $archive = New-Object `
            System.IO.Compression.ZipArchive `
            $fileStream, `
            ([System.IO.Compression.ZipArchiveMode]::Create)
        try {
            foreach ($file in Get-ChildItem -LiteralPath $source -File -Recurse |
                Sort-Object FullName) {
                $relative = Get-RelativePathCompat -Base $source -Path $file.FullName
                Add-ZipBytes `
                    -Archive $archive `
                    -EntryName "$rootName/$relative" `
                    -Bytes ([System.IO.File]::ReadAllBytes($file.FullName))
            }
            if ($DuplicateEntry) {
                Add-ZipBytes `
                    -Archive $archive `
                    -EntryName "$rootName/duplicate.txt" `
                    -Bytes ([System.Text.Encoding]::ASCII.GetBytes("second copy"))
            }
        }
        finally {
            $archive.Dispose()
        }
    }
    finally {
        $fileStream.Dispose()
    }

    return [pscustomobject]@{
        Name = $Name
        Version = $Version
        Commit = $Commit.ToLowerInvariant()
        ZipPath = $zipPath
        PackageSHA256 = Get-TestFileSha256 -Path $zipPath
        PayloadHashes = $payloadHashes
    }
}

function New-OldTarget {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Version,
        [Parameter(Mandatory = $true)][string]$Commit
    )

    $target = Assert-UnderContractRoot (
        Join-Path $contractRoot "cases\$Name\target")
    New-Item -ItemType Directory -Path $target -Force | Out-Null
    Write-Utf8BomFile `
        -Path (Join-Path $target "BUILD-INFO.txt") `
        -Text (
            "Name=old-$Name`r`n" +
            "Version=$Version`r`n" +
            "Commit=$Commit`r`n" +
            "WorkingTree=Clean`r`n")
    Write-AsciiFile `
        -Path (Join-Path $target "stable.txt") `
        -Text "stable:$Name"
    return [pscustomobject]@{
        Path = $target
        Version = $Version
        Commit = $Commit.ToLowerInvariant()
        BuildInfoSHA256 = Get-TestFileSha256 `
            -Path (Join-Path $target "BUILD-INFO.txt")
    }
}

function Start-FakeOwner {
    param(
        [Parameter(Mandatory = $true)][string]$OwnerExecutable,
        [Parameter(Mandatory = $true)][string]$Directory
    )

    $resolvedDirectory = Assert-UnderContractRoot $Directory
    New-Item -ItemType Directory -Path $resolvedDirectory -Force | Out-Null
    $ownerPath = Join-Path $resolvedDirectory "amd-mobile-power-gui.exe"
    Copy-Item -LiteralPath $OwnerExecutable -Destination $ownerPath -Force
    $process = Start-Process `
        -FilePath $ownerPath `
        -WindowStyle Hidden `
        -PassThru
    $script:fakeProcesses.Add($process)
    Start-Sleep -Milliseconds 300
    return $process
}

function Test-ProcessAlive {
    param($Process)

    if ($null -eq $Process) {
        return $false
    }
    try {
        $Process.Refresh()
        return -not $Process.HasExited
    }
    catch {
        return $false
    }
}

function Stop-FakeProcess {
    param($Process)

    if ($null -eq $Process) {
        return
    }
    try {
        if (-not $Process.HasExited) {
            Stop-Process -Id $Process.Id -Force -ErrorAction SilentlyContinue
        }
    }
    catch {
    }
}

function ConvertTo-ProcessArgument {
    param([AllowEmptyString()][string]$Value)

    return '"' + ($Value -replace '"', '\"') + '"'
}

function Invoke-Promotion {
    param([Parameter(Mandatory = $true)][hashtable]$Parameters)

    $arguments = @(
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        (ConvertTo-ProcessArgument $promoteScript))
    foreach ($key in @($Parameters.Keys | Sort-Object)) {
        $value = $Parameters[$key]
        if ($value -is [bool]) {
            if ($value) {
                $arguments += "-$key"
            }
            continue
        }
        if ($null -ne $value) {
            $arguments += "-$key"
            $arguments += ConvertTo-ProcessArgument ([string]$value)
        }
    }
    $logDirectory = Assert-UnderContractRoot (Join-Path $contractRoot "logs")
    New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
    $operationId = [Guid]::NewGuid().ToString("N")
    $stdoutPath = Join-Path $logDirectory "$operationId.stdout.txt"
    $stderrPath = Join-Path $logDirectory "$operationId.stderr.txt"
    $process = Start-Process `
        -FilePath $windowsPowerShell `
        -ArgumentList $arguments `
        -WindowStyle Hidden `
        -Wait `
        -PassThru `
        -RedirectStandardOutput $stdoutPath `
        -RedirectStandardError $stderrPath
    $stdoutText = if (Test-Path -LiteralPath $stdoutPath) {
        [System.IO.File]::ReadAllText(
            $stdoutPath,
            [System.Text.Encoding]::UTF8)
    }
    else {
        ""
    }
    $stderrText = if (Test-Path -LiteralPath $stderrPath) {
        [System.IO.File]::ReadAllText(
            $stderrPath,
            [System.Text.Encoding]::UTF8)
    }
    else {
        ""
    }
    $text = (@($stdoutText, $stderrText) |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join "`r`n"
    return [pscustomobject]@{
        ExitCode = $process.ExitCode
        Output = $text
    }
}

function Get-ProductProcessIdsUnder {
    param([Parameter(Mandatory = $true)][string]$Root)

    $prefix = [System.IO.Path]::GetFullPath($Root).TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar) +
        [System.IO.Path]::DirectorySeparatorChar
    return @(
        Get-CimInstance `
            -ClassName Win32_Process `
            -Filter (
                "Name='amd-mobile-power-gui.exe' OR " +
                "Name='amdmobilepower_native_worker.exe' OR " +
                "Name='AmdMobilePower.exe' OR " +
                "Name='AmdMobilePower.Worker.exe' OR " +
                "Name='RyzenPower.exe' OR Name='ryzenadj.exe'") `
            -ErrorAction SilentlyContinue |
            Where-Object {
                -not [string]::IsNullOrWhiteSpace($_.ExecutablePath) -and
                [System.IO.Path]::GetFullPath($_.ExecutablePath).StartsWith(
                    $prefix,
                    [System.StringComparison]::OrdinalIgnoreCase)
            } |
            ForEach-Object { [int]$_.ProcessId } |
            Sort-Object)
}

$fatalError = $null
try {
    New-Item -ItemType Directory -Path $contractRoot -Force | Out-Null
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $preStagingNames = @(
        Get-ChildItem `
            -LiteralPath (Join-Path $artifactsRoot "deployment-backups") `
            -Filter "promotion-staging-*" `
            -Force `
            -ErrorAction SilentlyContinue |
            ForEach-Object { $_.Name })
    $stableBefore = @(Get-ProductProcessIdsUnder -Root $stableTarget)

    $ownerSource = Join-Path $contractRoot "tools\fake-owner.cs"
    $ownerExecutable = Join-Path $contractRoot "tools\fake-owner.exe"
    New-Item -ItemType Directory -Path (Split-Path -Parent $ownerSource) -Force |
        Out-Null
    Write-AsciiFile `
        -Path $ownerSource `
        -Text (
            "using System;`r`n" +
            "using System.Threading;`r`n" +
            "static class FakeOwner {`r`n" +
            "  static int Main() { Thread.Sleep(120000); return 0; }`r`n" +
            "}`r`n")
    $csc = Join-Path `
        $env:WINDIR `
        "Microsoft.NET\Framework64\v4.0.30319\csc.exe"
    if (-not (Test-Path -LiteralPath $csc -PathType Leaf)) {
        throw "csc.exe is missing: $csc"
    }
    & $csc /nologo /target:exe "/out:$ownerExecutable" $ownerSource
    if ($LASTEXITCODE -ne 0) {
        throw "Fake owner compilation failed: $LASTEXITCODE"
    }

    $good = New-TestPackage `
        -Name "good" `
        -Version "9.9.9" `
        -Commit ("a" * 40)
    $missingBuild = New-TestPackage `
        -Name "missing-build" `
        -Version "9.9.9" `
        -Commit ("a" * 40) `
        -MissingBuildInfo
    $dirty = New-TestPackage `
        -Name "dirty" `
        -Version "9.9.9" `
        -Commit ("a" * 40) `
        -WorkingTree "Dirty"
    $duplicateEntry = New-TestPackage `
        -Name "duplicate-entry" `
        -Version "9.9.9" `
        -Commit ("a" * 40) `
        -DuplicateEntry
    $duplicateBuild = New-TestPackage `
        -Name "duplicate-build" `
        -Version "9.9.9" `
        -Commit ("a" * 40) `
        -DuplicateBuildInfo
    $corruptInstall = New-TestPackage `
        -Name "corrupt-install" `
        -Version "9.9.8" `
        -Commit ("b" * 40) `
        -CorruptInstalledGui

    try {
        $old = New-OldTarget `
            -Name "dry-run" `
            -Version "9.9.1" `
            -Commit ("c" * 40)
        $owner = Start-FakeOwner `
            -OwnerExecutable $ownerExecutable `
            -Directory $old.Path
        $run = Invoke-Promotion @{
            PackagePath = $good.ZipPath
            TargetDirectory = $old.Path
            ExpectedPackageSHA256 = $good.PackageSHA256
            ExpectedSourceCommit = $good.Commit
            SkipShellIntegration = $true
        }
        $pass = $run.ExitCode -eq 0 -and
            $run.Output -match "IdentityBound\s+:\s+True" -and
            $run.Output -match "PackageSHA256\s+:\s+$($good.PackageSHA256)" -and
            $run.Output -match "SourceCommit\s+:\s+$($good.Commit)" -and
            $run.Output -match "WorkingTree\s+:\s+Clean" -and
            (Test-ProcessAlive $owner)
        Add-Result `
            -Name "dry-run-identity-does-not-stop-owner" `
            -Pass $pass `
            -Detail ("exit={0} ownerAlive={1}" -f $run.ExitCode, (Test-ProcessAlive $owner))
        Stop-FakeProcess $owner
    }
    catch {
        Add-Result `
            -Name "dry-run-identity-does-not-stop-owner" `
            -Pass $false `
            -Detail $_.Exception.Message
    }

    try {
        $contractPath = Join-Path $nativeRoot "gui-cli-contract.json"
        $contractText = [System.IO.File]::ReadAllText(
            $contractPath,
            [System.Text.Encoding]::UTF8)
        $contract = $contractText | ConvertFrom-Json
        $hasNonAscii = @(
            $contractText.ToCharArray() |
                Where-Object { [int]$_ -gt 127 }).Count -gt 0
        $hasSimpleMode = $null -ne
            $contract.arguments.PSObject.Properties["--simple-mode"]
        $old = New-OldTarget `
            -Name "utf8-gui-contract" `
            -Version "9.9.1" `
            -Commit ("c" * 40)
        $run = Invoke-Promotion @{
            PackagePath = $good.ZipPath
            TargetDirectory = $old.Path
            ExpectedPackageSHA256 = $good.PackageSHA256
            ExpectedSourceCommit = $good.Commit
            SkipShellIntegration = $true
            GuiArguments = "--simple-mode --max-target-watts 45"
        }
        $pass = $run.ExitCode -eq 0 -and
            $hasNonAscii -and
            $hasSimpleMode -and
            $run.Output -match "GuiArguments\s+:\s+--simple-mode --max-target-watts 45"
        Add-Result `
            -Name "utf8-gui-contract-ps51-dry-run" `
            -Pass $pass `
            -Detail ("exit={0} nonAscii={1} simpleMode={2}" -f `
                $run.ExitCode, $hasNonAscii, $hasSimpleMode)
    }
    catch {
        Add-Result `
            -Name "utf8-gui-contract-ps51-dry-run" `
            -Pass $false `
            -Detail $_.Exception.Message
    }

    try {
        $old = New-OldTarget `
            -Name "wrong-hash" `
            -Version "9.9.1" `
            -Commit ("c" * 40)
        $owner = Start-FakeOwner `
            -OwnerExecutable $ownerExecutable `
            -Directory $old.Path
        $run = Invoke-Promotion @{
            PackagePath = $good.ZipPath
            TargetDirectory = $old.Path
            ExpectedPackageSHA256 = ("0" * 64)
            ExpectedSourceCommit = $good.Commit
            SkipShellIntegration = $true
        }
        $pass = $run.ExitCode -ne 0 -and
            $run.Output -match "Package SHA256 mismatch" -and
            (Test-ProcessAlive $owner) -and
            (Test-Path -LiteralPath (Join-Path $old.Path "stable.txt"))
        Add-Result `
            -Name "wrong-package-hash-rejected-before-stop" `
            -Pass $pass `
            -Detail ("exit={0} ownerAlive={1}" -f $run.ExitCode, (Test-ProcessAlive $owner))
        Stop-FakeProcess $owner
    }
    catch {
        Add-Result `
            -Name "wrong-package-hash-rejected-before-stop" `
            -Pass $false `
            -Detail $_.Exception.Message
    }

    try {
        $old = New-OldTarget `
            -Name "wrong-commit" `
            -Version "9.9.1" `
            -Commit ("c" * 40)
        $owner = Start-FakeOwner `
            -OwnerExecutable $ownerExecutable `
            -Directory $old.Path
        $run = Invoke-Promotion @{
            PackagePath = $good.ZipPath
            TargetDirectory = $old.Path
            ExpectedPackageSHA256 = $good.PackageSHA256
            ExpectedSourceCommit = ("d" * 40)
            SkipShellIntegration = $true
        }
        $pass = $run.ExitCode -ne 0 -and
            $run.Output -match "source commit mismatch" -and
            (Test-ProcessAlive $owner)
        Add-Result `
            -Name "wrong-source-commit-rejected-before-stop" `
            -Pass $pass `
            -Detail ("exit={0} ownerAlive={1}" -f $run.ExitCode, (Test-ProcessAlive $owner))
        Stop-FakeProcess $owner
    }
    catch {
        Add-Result `
            -Name "wrong-source-commit-rejected-before-stop" `
            -Pass $false `
            -Detail $_.Exception.Message
    }

    foreach ($case in @(
        @{
            Name = "missing-build-info-rejected-before-stop"
            Package = $missingBuild
            Pattern = "exactly one top-level BUILD-INFO"
        },
        @{
            Name = "dirty-tree-rejected-before-stop"
            Package = $dirty
            Pattern = "WorkingTree must be Clean"
        },
        @{
            Name = "duplicate-zip-entry-rejected"
            Package = $duplicateEntry
            Pattern = "duplicate ZIP entry"
        },
        @{
            Name = "duplicate-build-info-rejected"
            Package = $duplicateBuild
            Pattern = "exactly one top-level BUILD-INFO"
        }
    )) {
        try {
            $old = New-OldTarget `
                -Name $case.Name `
                -Version "9.9.1" `
                -Commit ("c" * 40)
            $owner = Start-FakeOwner `
                -OwnerExecutable $ownerExecutable `
                -Directory $old.Path
            $run = Invoke-Promotion @{
                PackagePath = $case.Package.ZipPath
                TargetDirectory = $old.Path
                ExpectedPackageSHA256 = $case.Package.PackageSHA256
                ExpectedSourceCommit = $case.Package.Commit
                SkipShellIntegration = $true
            }
            $pass = $run.ExitCode -ne 0 -and
                $run.Output -match $case.Pattern -and
                (Test-ProcessAlive $owner)
            Add-Result `
                -Name $case.Name `
                -Pass $pass `
                -Detail ("exit={0} ownerAlive={1}" -f $run.ExitCode, (Test-ProcessAlive $owner))
            Stop-FakeProcess $owner
        }
        catch {
            Add-Result `
                -Name $case.Name `
                -Pass $false `
                -Detail $_.Exception.Message
        }
    }

    try {
        $unsafeTarget = "C:\RyzenAdjUnsafe-$([Guid]::NewGuid().ToString('N'))"
        $run = Invoke-Promotion @{
            PackagePath = $good.ZipPath
            TargetDirectory = $unsafeTarget
            ExpectedPackageSHA256 = $good.PackageSHA256
            ExpectedSourceCommit = $good.Commit
            SkipShellIntegration = $true
        }
        $pass = $run.ExitCode -ne 0 -and
            $run.Output -match "TargetDirectory must be"
        Add-Result `
            -Name "unsafe-target-rejected" `
            -Pass $pass `
            -Detail ("exit={0}" -f $run.ExitCode)
    }
    catch {
        Add-Result `
            -Name "unsafe-target-rejected" `
            -Pass $false `
            -Detail $_.Exception.Message
    }

    try {
        $old = New-OldTarget `
            -Name "unsafe-backup" `
            -Version "9.9.1" `
            -Commit ("c" * 40)
        $run = Invoke-Promotion @{
            PackagePath = $good.ZipPath
            TargetDirectory = $old.Path
            BackupDirectory = (Join-Path $old.Path "backup")
            ExpectedPackageSHA256 = $good.PackageSHA256
            ExpectedSourceCommit = $good.Commit
            SkipShellIntegration = $true
        }
        $pass = $run.ExitCode -ne 0 -and
            $run.Output -match "direct sibling"
        Add-Result `
            -Name "backup-inside-target-rejected" `
            -Pass $pass `
            -Detail ("exit={0}" -f $run.ExitCode)
    }
    catch {
        Add-Result `
            -Name "backup-inside-target-rejected" `
            -Pass $false `
            -Detail $_.Exception.Message
    }

    try {
        $old = New-OldTarget `
            -Name "evidence-in-target" `
            -Version "9.9.1" `
            -Commit ("c" * 40)
        $run = Invoke-Promotion @{
            PackagePath = $good.ZipPath
            TargetDirectory = $old.Path
            EvidencePath = (Join-Path $old.Path "deployment.json")
            ExpectedPackageSHA256 = $good.PackageSHA256
            ExpectedSourceCommit = $good.Commit
            SkipShellIntegration = $true
        }
        $pass = $run.ExitCode -ne 0 -and
            $run.Output -match "Evidence path must not be inside"
        Add-Result `
            -Name "evidence-inside-target-rejected" `
            -Pass $pass `
            -Detail ("exit={0}" -f $run.ExitCode)
    }
    catch {
        Add-Result `
            -Name "evidence-inside-target-rejected" `
            -Pass $false `
            -Detail $_.Exception.Message
    }

    try {
        $old = New-OldTarget `
            -Name "existing-backup" `
            -Version "9.9.1" `
            -Commit ("c" * 40)
        $backup = Join-Path (Split-Path -Parent $old.Path) "target.before-existing"
        New-Item -ItemType Directory -Path $backup -Force | Out-Null
        $run = Invoke-Promotion @{
            PackagePath = $good.ZipPath
            TargetDirectory = $old.Path
            BackupDirectory = $backup
            ExpectedPackageSHA256 = $good.PackageSHA256
            ExpectedSourceCommit = $good.Commit
            SkipShellIntegration = $true
        }
        $pass = $run.ExitCode -ne 0 -and
            $run.Output -match "Backup path already exists"
        Add-Result `
            -Name "existing-backup-rejected" `
            -Pass $pass `
            -Detail ("exit={0}" -f $run.ExitCode)
    }
    catch {
        Add-Result `
            -Name "existing-backup-rejected" `
            -Pass $false `
            -Detail $_.Exception.Message
    }

    try {
        $old = New-OldTarget `
            -Name "success" `
            -Version $good.Version `
            -Commit $good.Commit
        $oldBuildHash = $old.BuildInfoSHA256
        $targetOwner = Start-FakeOwner `
            -OwnerExecutable $ownerExecutable `
            -Directory $old.Path
        $unrelatedDirectory = Assert-UnderContractRoot (
            Join-Path $contractRoot "cases\success\unrelated")
        $unrelatedOwner = Start-FakeOwner `
            -OwnerExecutable $ownerExecutable `
            -Directory $unrelatedDirectory
        $caseRoot = Split-Path -Parent $old.Path
        $evidencePath = Join-Path $caseRoot "deployment.json"
        $run = Invoke-Promotion @{
            PackagePath = $good.ZipPath
            TargetDirectory = $old.Path
            EvidencePath = $evidencePath
            ExpectedPackageSHA256 = $good.PackageSHA256
            ExpectedSourceCommit = $good.Commit
            Apply = $true
            NoLaunch = $true
            SkipShellIntegration = $true
        }
        $evidence = if (Test-Path -LiteralPath $evidencePath -PathType Leaf) {
            [System.IO.File]::ReadAllText(
                $evidencePath,
                [System.Text.Encoding]::UTF8) | ConvertFrom-Json
        }
        else {
            $null
        }
        $backup = if ($evidence) { [string]$evidence.Backup } else { $null }
        $pass = $run.ExitCode -eq 0 -and
            $null -ne $evidence -and
            -not (Test-ProcessAlive $targetOwner) -and
            (Test-ProcessAlive $unrelatedOwner) -and
            $evidence.Verification -eq "PASS" -and
            $evidence.IdentityBound -eq $true -and
            $evidence.PackageSHA256 -eq $good.PackageSHA256 -and
            $evidence.SourceCommit -eq $good.Commit -and
            $evidence.WorkingTree -eq "Clean" -and
            $evidence.DeployedHashes.Gui -eq $good.PayloadHashes["amd-mobile-power-gui.exe"] -and
            $evidence.DeployedHashes.Worker -eq $good.PayloadHashes["amdmobilepower_native_worker.exe"] -and
            $evidence.DeployedHashes.Probe -eq $good.PayloadHashes["amd-mobile-power-probe.exe"] -and
            $evidence.PreviousVersion -eq $old.Version -and
            $evidence.PreviousCommit -eq $old.Commit -and
            $evidence.BackupKind -eq "SameVersion" -and
            $evidence.IsSameVersion -eq $true -and
            $evidence.ProcessStopScope -eq "TargetDirectoryTreeOnly" -and
            $backup -and
            (Test-Path -LiteralPath $backup -PathType Container) -and
            (Test-Path -LiteralPath (Join-Path $backup "stable.txt")) -and
            (Get-TestFileSha256 `
                -Path (Join-Path $backup "BUILD-INFO.txt")) -eq $oldBuildHash
        Add-Result `
            -Name "success-evidence-hashes-and-scoped-stop" `
            -Pass $pass `
            -Detail ("exit={0} targetOwnerAlive={1} unrelatedOwnerAlive={2} evidence={3}" -f `
                $run.ExitCode, `
                (Test-ProcessAlive $targetOwner), `
                (Test-ProcessAlive $unrelatedOwner), `
                [bool]$evidence)
        Stop-FakeProcess $targetOwner
        Stop-FakeProcess $unrelatedOwner
    }
    catch {
        Add-Result `
            -Name "success-evidence-hashes-and-scoped-stop" `
            -Pass $false `
            -Detail $_.Exception.Message
    }

    try {
        $old = New-OldTarget `
            -Name "rollback" `
            -Version "9.9.7" `
            -Commit ("c" * 40)
        $oldBuildHash = $old.BuildInfoSHA256
        $caseRoot = Split-Path -Parent $old.Path
        $evidencePath = Join-Path $caseRoot "deployment.json"
        $run = Invoke-Promotion @{
            PackagePath = $corruptInstall.ZipPath
            TargetDirectory = $old.Path
            EvidencePath = $evidencePath
            ExpectedPackageSHA256 = $corruptInstall.PackageSHA256
            ExpectedSourceCommit = $corruptInstall.Commit
            Apply = $true
            NoLaunch = $true
            SkipShellIntegration = $true
        }
        $backupDirectories = @(
            Get-ChildItem `
                -LiteralPath $caseRoot `
                -Directory `
                -Filter "target.before-*" `
                -ErrorAction SilentlyContinue)
        $restoredBuildHash = Get-TestFileSha256 `
            -Path (Join-Path $old.Path "BUILD-INFO.txt")
        $failureEvidence = $null
        if (Test-Path -LiteralPath $evidencePath -PathType Leaf) {
            $failureEvidence = [System.IO.File]::ReadAllText(
                $evidencePath,
                [System.Text.Encoding]::UTF8) | ConvertFrom-Json
        }
        $pass = $run.ExitCode -ne 0 -and
            $run.Output -match "Installed checksum mismatch" -and
            $run.Output -match "Rollback=Completed" -and
            ([System.IO.File]::ReadAllText(
                (Join-Path $old.Path "stable.txt"),
                [System.Text.Encoding]::UTF8)) -eq "stable:rollback" -and
            $restoredBuildHash -eq $oldBuildHash -and
            -not (Test-Path -LiteralPath (Join-Path $old.Path "amd-mobile-power-gui.exe")) -and
            $backupDirectories.Count -eq 0 -and
            $null -ne $failureEvidence -and
            $failureEvidence.Verification -eq "FAIL" -and
            $failureEvidence.Rollback -eq "Completed" -and
            $failureEvidence.Error -match "Installed checksum mismatch"
        Add-Result `
            -Name "installed-checksum-mismatch-rolls-back" `
            -Pass $pass `
            -Detail ("exit={0} backups={1} failureEvidence={2}" -f `
                $run.ExitCode, `
                $backupDirectories.Count, `
                $(if ($failureEvidence) { $failureEvidence.Rollback } else { "missing" }))
    }
    catch {
        Add-Result `
            -Name "installed-checksum-mismatch-rolls-back" `
            -Pass $false `
            -Detail $_.Exception.Message
    }

    try {
        $postStagingNames = @(
            Get-ChildItem `
                -LiteralPath (Join-Path $artifactsRoot "deployment-backups") `
                -Filter "promotion-staging-*" `
                -Force `
                -ErrorAction SilentlyContinue |
                ForEach-Object { $_.Name })
        $newStaging = @($postStagingNames | Where-Object {
            $preStagingNames -notcontains $_
        })
        Add-Result `
            -Name "staging-cleanup" `
            -Pass ($newStaging.Count -eq 0) `
            -Detail ("newStaging={0}" -f ($newStaging -join ","))
    }
    catch {
        Add-Result `
            -Name "staging-cleanup" `
            -Pass $false `
            -Detail $_.Exception.Message
    }

    try {
        $stableAfter = @(Get-ProductProcessIdsUnder -Root $stableTarget)
        $beforeText = $stableBefore -join ","
        $afterText = $stableAfter -join ","
        Add-Result `
            -Name "stable-tray-untouched" `
            -Pass ($beforeText -eq $afterText) `
            -Detail ("before={0} after={1}" -f $beforeText, $afterText)
    }
    catch {
        Add-Result `
            -Name "stable-tray-untouched" `
            -Pass $false `
            -Detail $_.Exception.Message
    }
}
catch {
    $fatalError = $_
    Add-Result `
        -Name "harness-error" `
        -Pass $false `
        -Detail $_.Exception.Message
}
finally {
    foreach ($process in $fakeProcesses) {
        Stop-FakeProcess $process
    }
    if (-not $KeepArtifacts -and (Test-Path -LiteralPath $contractRoot)) {
        try {
            $resolvedContract = Assert-UnderContractRoot $contractRoot
            Remove-Item -LiteralPath $resolvedContract -Recurse -Force
        }
        catch {
            Add-Result `
                -Name "contract-cleanup" `
                -Pass $false `
                -Detail $_.Exception.Message
        }
    }
}

$failed = @($results.Keys | Where-Object { -not $results[$_].Pass })
$record = [ordered]@{
    Verification = if ($failed.Count -eq 0 -and $null -eq $fatalError) {
        "PASS"
    }
    else {
        "FAIL"
    }
    HardwareEnabled = $false
    StableTargetStopped = $false
    ContractRoot = if ($KeepArtifacts) { $contractRoot } else { $null }
    Checks = $results
    Failed = $failed
    RecordedAt = (Get-Date).ToString("o")
}
$record | ConvertTo-Json -Depth 8
if ($failed.Count -gt 0 -or $null -ne $fatalError) {
    exit 1
}
