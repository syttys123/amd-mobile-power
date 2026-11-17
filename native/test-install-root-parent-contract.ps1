$ErrorActionPreference = 'Stop'

# Exercise the real installer with a target whose direct parent is a drive
# root. The target itself stays under artifacts\verify and is removed in
# finally; C:\RyzenAdj and its processes are never touched.
$root = Split-Path -Parent $PSCommandPath
$repositoryRoot = Split-Path -Parent $root
$verifyRoot = [System.IO.Path]::GetFullPath(
    (Join-Path $repositoryRoot 'artifacts\verify'))
$operationId = [Guid]::NewGuid().ToString('N')
$work = Join-Path $verifyRoot "install-root-parent-$operationId"
$package = Join-Path $work 'package'
$driveRoot = [System.IO.Path]::GetPathRoot($work)
$target = Join-Path $driveRoot "AmdMobilePowerRootParentContract-$operationId"
$windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

function Assert-UnderWork([string]$Path) {
    $resolved = [System.IO.Path]::GetFullPath($Path)
    $normalizedWork = $work.TrimEnd('\')
    $prefix = $normalizedWork + '\'
    if (-not [string]::Equals(
        $resolved,
        $normalizedWork,
        [System.StringComparison]::OrdinalIgnoreCase) -and
        -not $resolved.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Unsafe contract path: $resolved"
    }
    return $resolved
}

function Assert-TargetPath([string]$Path) {
    $resolved = [System.IO.Path]::GetFullPath($Path)
    if (-not [string]::Equals(
        [System.IO.Path]::GetFullPath((Split-Path -Parent $resolved)),
        [System.IO.Path]::GetFullPath($driveRoot),
        [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Contract target must be a direct child of the drive root: $resolved"
    }
    if (-not [System.IO.Path]::GetFileName($resolved).StartsWith(
        'AmdMobilePowerRootParentContract-', [System.StringComparison]::Ordinal)) {
        throw "Unexpected contract target name: $resolved"
    }
    if (Test-Path -LiteralPath $resolved) {
        $item = Get-Item -LiteralPath $resolved -Force
        if (-not $item.PSIsContainer -or
            ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Unsafe existing contract target: $resolved"
        }
    }
    return $resolved
}

try {
    New-Item -ItemType Directory -Path $package -Force | Out-Null
    foreach ($name in @(
        'amd-mobile-power-gui.exe',
        'amdmobilepower_native_worker.exe',
        'amd-mobile-power-probe.exe'
    )) {
        [System.IO.File]::WriteAllText(
            (Join-Path $package $name),
            'root-parent contract placeholder',
            [System.Text.Encoding]::ASCII)
    }
    Copy-Item -LiteralPath (Join-Path $root 'install-preview.ps1') -Destination $package
    Copy-Item -LiteralPath (Join-Path $root 'uninstall-preview.ps1') -Destination $package
    [System.IO.File]::WriteAllText(
        (Join-Path $package 'BUILD-INFO.txt'),
        "Version=root-parent-contract`r`nCommit=0000000000000000000000000000000000000000`r`nWorkingTree=Clean`r`n",
        (New-Object System.Text.UTF8Encoding($true)))

    $checkedTarget = Assert-TargetPath $target
    & $windowsPowerShell -NoProfile -ExecutionPolicy Bypass `
        -File (Join-Path $package 'install-preview.ps1') `
        -InstallDirectory $checkedTarget `
        -NoStartup -NoShellIntegration -NoLaunch
    if ($LASTEXITCODE -ne 0) {
        throw "Real installer failed for drive-root parent: exit $LASTEXITCODE"
    }
    if (-not (Test-Path -LiteralPath (Join-Path $checkedTarget 'NATIVE-PREVIEW-INSTALL.txt'))) {
        throw 'Drive-root-parent install marker is missing.'
    }

    & $windowsPowerShell -NoProfile -ExecutionPolicy Bypass `
        -File (Join-Path $package 'uninstall-preview.ps1') `
        -InstallDirectory $checkedTarget `
        -NoStartup -NoShellIntegration
    if ($LASTEXITCODE -ne 0) {
        throw "Real uninstaller failed for drive-root parent: exit $LASTEXITCODE"
    }
    if (Test-Path -LiteralPath $checkedTarget) {
        throw 'Drive-root-parent uninstall left the target behind.'
    }
    Write-Output 'install-root-parent-contract: PASS (real PS 5.1 install/uninstall; isolated target)'
}
finally {
    if (Test-Path -LiteralPath $work) {
        $checkedWork = Assert-UnderWork $work
        Remove-Item -LiteralPath $checkedWork -Recurse -Force
    }
    if (Test-Path -LiteralPath $target) {
        $checkedTarget = Assert-TargetPath $target
        Remove-Item -LiteralPath $checkedTarget -Recurse -Force
    }
}
