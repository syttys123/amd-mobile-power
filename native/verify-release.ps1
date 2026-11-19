param(
    [Parameter(Mandatory = $true)]
    [string]$Version,
    [switch]$NoBuild,
    [switch]$ExecuteNoChangePolicy,
    [switch]$VerifyShellIntegration,
    [switch]$VerifyWorkerHang,
    [switch]$VerifyReproducibility,
    [switch]$AllowDirty,
    [switch]$AllowBatteryWriteGuard,
    [string]$EvidencePath
)

$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSCommandPath
$repositoryRoot = Split-Path -Parent $root
$packageEvidence = Join-Path `
    $repositoryRoot `
    "docs\evidence\packaging\v$Version-clean-$(Get-Date -Format 'yyyy-MM-dd').json"
$shellEvidence = Join-Path `
    $repositoryRoot `
    "docs\evidence\packaging\v$Version-shell-integration-$(Get-Date -Format 'yyyy-MM-dd').json"
$policyEvidence = Join-Path `
    $repositoryRoot `
    "docs\evidence\hardware\v$Version-power-policy-no-change-$(Get-Date -Format 'yyyy-MM-dd').json"
$workerHangEvidence = Join-Path `
    $repositoryRoot `
    "docs\evidence\hardware\v$Version-worker-hang-$(Get-Date -Format 'yyyy-MM-dd').json"

if (-not $EvidencePath) {
    $EvidencePath = Join-Path `
        $repositoryRoot `
        "docs\evidence\packaging\v$Version-release-gate-$(Get-Date -Format 'yyyy-MM-dd').json"
}

$stableInstallDirectory = "C:\RyzenAdj"
$stableGuiPath = Join-Path $stableInstallDirectory "amd-mobile-power-gui.exe"
$stableWorkerPath = Join-Path $stableInstallDirectory "amdmobilepower_native_worker.exe"
$stablePipeName = '\\.\pipe\AmdMobilePower.RustGui.Worker.v1'
$stablePolicyHelper = Join-Path $root "apply-power-policy-direct.ps1"
$stablePolicyLog = Join-Path `
    $env:LOCALAPPDATA `
    "AmdMobilePower\maintenance\release-gate-recovery.log"
$testOwnerRoots = @(
    (Join-Path $repositoryRoot "artifacts\native-build"),
    (Join-Path $repositoryRoot "artifacts\native-packages")
)

function Get-ProcessArgumentsFromCommandLine {
    param([string]$CommandLine)

    if ([string]::IsNullOrWhiteSpace($CommandLine)) {
        return ""
    }
    if ($CommandLine -match '^\s*"[^"]+"\s*(.*)$') {
        return $Matches[1].Trim()
    }
    if ($CommandLine -match '^\s*\S+\s*(.*)$') {
        return $Matches[1].Trim()
    }
    return ""
}

function Get-StableGuiSnapshot {
    @(
        Get-CimInstance Win32_Process -Filter "Name = 'amd-mobile-power-gui.exe'" |
            Where-Object {
                $_.ExecutablePath -and
                [string]::Equals(
                    [System.IO.Path]::GetFullPath($_.ExecutablePath),
                    [System.IO.Path]::GetFullPath($stableGuiPath),
                    [System.StringComparison]::OrdinalIgnoreCase)
            } |
            ForEach-Object {
                [pscustomobject]@{
                    Id = [int]$_.ProcessId
                    Path = [string]$_.ExecutablePath
                    Arguments = Get-ProcessArgumentsFromCommandLine ([string]$_.CommandLine)
                    CreationDate = $_.CreationDate
                }
            }
    )
}

function Get-LiveStableGui {
    @(
        Get-CimInstance Win32_Process -Filter "Name = 'amd-mobile-power-gui.exe'" |
            Where-Object {
                $_.ExecutablePath -and
                [string]::Equals(
                    [System.IO.Path]::GetFullPath($_.ExecutablePath),
                    [System.IO.Path]::GetFullPath($stableGuiPath),
                    [System.StringComparison]::OrdinalIgnoreCase)
            }
    )
}

function Get-LiveStableWorker {
    @(
        Get-CimInstance Win32_Process -Filter "Name = 'amdmobilepower_native_worker.exe'" |
            Where-Object {
                $_.ExecutablePath -and
                [string]::Equals(
                    [System.IO.Path]::GetFullPath($_.ExecutablePath),
                    [System.IO.Path]::GetFullPath($stableWorkerPath),
                    [System.StringComparison]::OrdinalIgnoreCase)
            }
    )
}

function Test-PathInsideAnyRoot {
    param(
        [string]$Path,
        [string[]]$Roots
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $false
    }
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    foreach ($candidate in $Roots) {
        $fullRoot = [System.IO.Path]::GetFullPath($candidate).TrimEnd("\") + "\"
        if ($fullPath.StartsWith(
            $fullRoot,
            [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }
    return $false
}

function Get-TestOwnerProcesses {
    @(
        Get-CimInstance Win32_Process |
            Where-Object {
                $_.Name -in @(
                    "amd-mobile-power-gui.exe",
                    "amdmobilepower_native_worker.exe"
                ) -and
                (Test-PathInsideAnyRoot -Path ([string]$_.ExecutablePath) -Roots $testOwnerRoots)
            }
    )
}

function Stop-TestOwnerProcesses {
    # A package/UI verifier can fail before its own finally block runs. Clear
    # only processes launched from repository artifacts, then prove the stable
    # owner has no competitor before the policy helper is allowed to act.
    $testOwners = @(Get-TestOwnerProcesses)
    foreach ($owner in $testOwners) {
        Stop-Process -Id $owner.ProcessId -Force -ErrorAction SilentlyContinue
    }
    $deadline = (Get-Date).AddSeconds(12)
    while ((Get-Date) -lt $deadline) {
        if (@(Get-TestOwnerProcesses).Count -eq 0) {
            return
        }
        Start-Sleep -Milliseconds 250
    }
    $remaining = @(Get-TestOwnerProcesses)
    if ($remaining.Count -gt 0) {
        throw ("Test-owned GUI/worker processes did not exit: " +
            (($remaining | ForEach-Object { "$($_.Name):$($_.ProcessId)" }) -join ", "))
    }
}

function Start-StableGui {
    $arguments = if ($script:stableGuiSnapshot.Count -gt 0) {
        [string]$script:stableGuiSnapshot[0].Arguments
    }
    else {
        "--tray --simple-mode --max-target-watts 45"
    }
    $process = Start-Process `
        -FilePath $stableGuiPath `
        -WorkingDirectory $stableInstallDirectory `
        -ArgumentList $arguments `
        -WindowStyle Hidden `
        -PassThru `
        -ErrorAction Stop
    $process.Dispose()
    $deadline = (Get-Date).AddSeconds(15)
    while ((Get-Date) -lt $deadline) {
        if (@(Get-LiveStableGui).Count -gt 0) {
            return
        }
        Start-Sleep -Milliseconds 250
    }
    throw "Stable GUI did not remain alive after launch: $stableGuiPath"
}

function Stop-StableGui {
    foreach ($owner in @(Get-LiveStableGui)) {
        Stop-Process -Id $owner.ProcessId -Force -ErrorAction SilentlyContinue
    }
    foreach ($owner in @(Get-LiveStableWorker)) {
        Stop-Process -Id $owner.ProcessId -Force -ErrorAction SilentlyContinue
    }
    $deadline = (Get-Date).AddSeconds(12)
    while ((Get-Date) -lt $deadline) {
        if (@(Get-LiveStableGui).Count -eq 0 -and
            @(Get-LiveStableWorker).Count -eq 0) {
            return
        }
        Start-Sleep -Milliseconds 250
    }
    throw "Stable GUI/worker did not release ownership."
}

function Invoke-StablePolicyHelper {
    param(
        [int]$BatteryWatts,
        [int]$AcWatts
    )

    & $stablePolicyHelper `
        -BatteryWatts $BatteryWatts `
        -AcWatts $AcWatts `
        -AllowGuiAutoStart `
        -RefreshGui `
        -LogPath $stablePolicyLog
}

function Test-StablePolicy {
    param(
        [int]$BatteryWatts,
        [int]$AcWatts
    )

    . (Join-Path $root "worker-client.ps1")
    $policy = Invoke-WorkerPipeRequest `
        -PipeName $stablePipeName `
        -Command "getPowerPolicy"
    if (-not $policy.Success -or $null -eq $policy.Payload.settings) {
        throw "Stable GUI recovery could not read worker policy: $($policy.ErrorText)"
    }
    $settings = $policy.Payload.settings
    if ($settings.enabled -ne $true -or
        $settings.batteryEnabled -ne $true -or
        $settings.acEnabled -ne $true) {
        throw "Stable GUI recovery left automatic policy disabled."
    }
    foreach ($target in @(
        @{ Name = "battery"; Expected = $BatteryWatts; Value = $settings.batteryTarget },
        @{ Name = "ac"; Expected = $AcWatts; Value = $settings.acTarget }
    )) {
        $value = $target.Value
        if ($null -eq $value -or
            $value.stapmWatts -ne $target.Expected -or
            $value.fastWatts -ne $target.Expected -or
            $value.slowWatts -ne $target.Expected) {
            throw ("Stable GUI recovery $($target.Name) policy mismatch: " +
                "expected $($target.Expected)/$($target.Expected)/$($target.Expected).")
        }
    }
    $snapshot = Invoke-WorkerPipeRequest `
        -PipeName $stablePipeName `
        -Command "getSnapshot"
    if (-not $snapshot.Success -or $null -eq $snapshot.Payload.telemetry) {
        throw "Stable GUI recovery could not read worker telemetry."
    }
    $telemetry = $snapshot.Payload.telemetry
    $expected = if ($telemetry.powerLine -eq "ac") { $AcWatts } else { $BatteryWatts }
    if ([Math]::Abs([double]$telemetry.fastLimitWatts - $expected) -gt 1.0 -or
        [Math]::Abs([double]$telemetry.slowLimitWatts - $expected) -gt 1.0) {
        throw ("Stable GUI recovery current limit mismatch on $($telemetry.powerLine): " +
            "Fast/Slow $($telemetry.fastLimitWatts)/$($telemetry.slowLimitWatts) W; " +
            "expected $expected W.")
    }
}

function Restore-StableGuiAfterReleaseGate {
    Stop-TestOwnerProcesses

    # The initial state is recorded for audit, but the release gate always
    # returns the machine to the supervised stable tray. Ending a gate without
    # a tray was the 1.0.41 failure mode; a user-stopped tray is restarted only
    # after the gate has cleaned every test owner.
    $initialRunning = $script:stableGuiSnapshot.Count -gt 0
    if (@(Get-LiveStableGui).Count -eq 0) {
        Start-StableGui
    }

    $hour = (Get-Date).Hour
    $batteryWatts = if ($hour -ge 7 -and $hour -lt 23) { 25 } else { 10 }
    $acWatts = if ($hour -ge 7 -and $hour -lt 23) { 45 } else { 10 }
    $firstError = $null
    try {
        Invoke-StablePolicyHelper -BatteryWatts $batteryWatts -AcWatts $acWatts
    }
    catch {
        $firstError = $_
        # The GUI may be alive while its worker is gone. Restart the stable
        # owner once, then retry the same helper so the worker is recreated.
        Stop-StableGui
        Start-StableGui
        try {
            Invoke-StablePolicyHelper -BatteryWatts $batteryWatts -AcWatts $acWatts
        }
        catch {
            throw ("Stable GUI policy recovery failed after restart: " +
                "$($_.Exception.Message); first attempt: $($firstError.Exception.Message)")
        }
    }

    Stop-TestOwnerProcesses
    $stableGui = @(Get-LiveStableGui)
    $stableWorker = @(Get-LiveStableWorker)
    if ($stableGui.Count -ne 1 -or $stableWorker.Count -ne 1) {
        throw ("Stable owner count is invalid after recovery: " +
            "gui=$($stableGui.Count) worker=$($stableWorker.Count).")
    }
    Test-StablePolicy -BatteryWatts $batteryWatts -AcWatts $acWatts

    [pscustomobject]@{
        Status = "PASS"
        InitialGuiRunning = $initialRunning
        InitialGuiPid = if ($initialRunning) { $script:stableGuiSnapshot[0].Id } else { $null }
        InitialGuiArguments = if ($initialRunning) {
            $script:stableGuiSnapshot[0].Arguments
        }
        else {
            $null
        }
        RestoredGuiPid = [int]$stableGui[0].ProcessId
        RestoredWorkerPid = [int]$stableWorker[0].ProcessId
        BatteryWatts = $batteryWatts
        AcWatts = $acWatts
    }
}

$statusText = (& git `
    -C $repositoryRoot `
    status `
    --porcelain `
    --ignore-submodules=dirty |
    Where-Object { $_ -notmatch "^.. docs/evidence/" } |
    Out-String).Trim()
if ($statusText -and -not $AllowDirty) {
    throw "Native release verification requires a clean worktree. Use -AllowDirty only for diagnostics."
}

$stableGuiSnapshot = @(Get-StableGuiSnapshot)
if ($stableGuiSnapshot.Count -gt 1) {
    throw ("Multiple stable GUI sessions already own ${stableGuiPath}: " +
        (($stableGuiSnapshot | ForEach-Object { $_.Id }) -join ", "))
}
$stableRecoveryResult = $null

$verificationFailure = $null
try {
if (-not $NoBuild) {
    & (Join-Path $root "build.ps1") -Offline
}

$nativeArguments = @{
    NoBuild = $true
    VerifyHardware = $true
    VerifyRustGui = $true
    VerifyRustWorker = $true
    VerifyWriteGuard = $true
}
if ($AllowBatteryWriteGuard) {
    $nativeArguments.AllowBatteryWriteGuard = $true
}

# Hardware verification starts its own worker with an isolated pipe name, but
# the worker still takes the process-wide RyzenAdj owner mutex. Pause the
# supervised tray for the exclusive hardware section; finally restores it.
if ($nativeArguments.VerifyHardware) {
    Stop-TestOwnerProcesses
    Stop-StableGui
}
& (Join-Path $root "verify-native.ps1") @nativeArguments

& (Join-Path $root "verify-power-policy.ps1") -NoBuild

$reproducibilityEvidencePath = Join-Path `
    $repositoryRoot `
    "docs\evidence\build\reproducibility-$Version-$(Get-Date -Format 'yyyy-MM-dd').json"
$reproducibilityStatus = "Skipped"
if ($VerifyReproducibility) {
    $reproOutput = & (Join-Path $root "verify-reproducibility.ps1") `
        -PackageVersion $Version `
        -EvidencePath $reproducibilityEvidencePath 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Reproducibility verification failed: $reproOutput"
    }
    $reproReport = Get-Content -LiteralPath $reproducibilityEvidencePath -Raw |
        ConvertFrom-Json
    if ($reproReport.Verification -ne "PASS") {
        throw "Reproducibility verification did not report PASS."
    }
    $reproducibilityStatus = "PASS"
}

$packageArguments = @{
    NoBuild = $true
    Version = $Version
    EvidencePath = $packageEvidence
    ReadOnlyRuntimeVerification = $true
}
$null = & (Join-Path $root "build-package.ps1") @packageArguments

$sanitizationEvidencePath = Join-Path `
    $repositoryRoot `
    "docs\evidence\release\public-sanitization-$Version-$(Get-Date -Format 'yyyy-MM-dd').json"
$null = & (Join-Path $root "verify-public-sanitization.ps1") `
    -RepositoryRoot $repositoryRoot `
    -ScanPackageBinaries `
    -PackagePath (Join-Path `
        $repositoryRoot `
        "artifacts\native-packages\amd-mobile-power-v$Version-win-x64-native-preview.zip") `
    -EvidencePath $sanitizationEvidencePath

$packageDirectory = Join-Path `
    (Join-Path $repositoryRoot "artifacts\native-packages") `
    "amd-mobile-power-v$Version-win-x64-native-preview"
$dpiEvidencePath = Join-Path `
    $repositoryRoot `
    "docs\evidence\ui\native-dpi-100-125-150-$(Get-Date -Format 'yyyy-MM-dd').json"
$smallViewportEvidencePath = Join-Path `
    $repositoryRoot `
    "docs\evidence\ui\native-workarea-200-1366x768-$(Get-Date -Format 'yyyy-MM-dd').json"
$null = & (Join-Path $root "verify-dpi-fixtures.ps1") `
    -GuiExecutable (Join-Path $packageDirectory "amd-mobile-power-gui.exe") `
    -WorkerExecutable (Join-Path $packageDirectory "amdmobilepower_native_worker.exe") `
    -EvidencePath $dpiEvidencePath
if (-not (Test-Path -LiteralPath $dpiEvidencePath -PathType Leaf) -or
    (Get-Content -LiteralPath $dpiEvidencePath -Raw |
        ConvertFrom-Json).Verification -ne "PASS") {
    throw "Native DPI layout fixtures failed."
}
$null = & (Join-Path $root "verify-small-viewport.ps1") `
    -GuiExecutable (Join-Path $packageDirectory "amd-mobile-power-gui.exe") `
    -EvidencePath $smallViewportEvidencePath
if (-not (Test-Path -LiteralPath $smallViewportEvidencePath -PathType Leaf) -or
    (Get-Content -LiteralPath $smallViewportEvidencePath -Raw |
        ConvertFrom-Json).Verification -ne "PASS") {
    throw "Native 1366x768/200% work-area fixture failed."
}

$maximizeEvidencePath = Join-Path `
    $repositoryRoot `
    "docs\evidence\ui\native-maximize-scroll-$(Get-Date -Format 'yyyy-MM-dd').json"
$null = & (Join-Path $root "verify-maximize-scroll.ps1") `
    -GuiExecutable (Join-Path $packageDirectory "amd-mobile-power-gui.exe") `
    -EvidencePath $maximizeEvidencePath
if (-not (Test-Path -LiteralPath $maximizeEvidencePath -PathType Leaf) -or
    (Get-Content -LiteralPath $maximizeEvidencePath -Raw |
        ConvertFrom-Json).Verification -ne "PASS") {
    throw "Native maximize-scroll regression check failed."
}

$shellStatus = "Not requested"
if ($VerifyShellIntegration) {
    $null = & (Join-Path $root "verify-preview-shell-integration.ps1") `
        -EvidencePath $shellEvidence
    $shellStatus = "PASS"
}

$policyStatus = "Not requested"
if ($ExecuteNoChangePolicy) {
    $null = & (Join-Path $root "verify-power-policy.ps1") `
        -NoBuild `
        -ExecuteNoChangePolicy `
        -EvidencePath $policyEvidence
    $policyStatus = "PASS"
}

$workerHangStatus = "Not requested"
if ($VerifyWorkerHang) {
    $null = & (Join-Path $root "verify-worker-hang.ps1") `
        -Version $Version `
        -GuiExecutable (Join-Path $packageDirectory "amd-mobile-power-gui.exe") `
        -WorkerExecutable (Join-Path $packageDirectory "amdmobilepower_native_worker.exe") `
        -ProbeExecutable (Join-Path $packageDirectory "amd-mobile-power-probe.exe") `
        -EvidencePath $workerHangEvidence
    $workerHangStatus = "PASS"
}

$package = Get-Content -LiteralPath $packageEvidence -Raw | ConvertFrom-Json
$headCommit = (& git -C $repositoryRoot rev-parse HEAD).Trim()
if ($package.Version -ne $Version) {
    throw "Package evidence version mismatch: $($package.Version) != $Version"
}
if ($package.WorkingTree -ne "Clean") {
    throw "Package evidence was not produced from a clean worktree."
}

# A verified package stays valid while HEAD only moves forward over
# documentation. Any change to runtime, build, CI, or packaging paths after the
# recorded source commit invalidates the package and requires a rebuild.
if ($package.SourceCommit -ne $headCommit) {
    & git -C $repositoryRoot merge-base --is-ancestor $package.SourceCommit $headCommit
    if ($LASTEXITCODE -ne 0) {
        throw "Package source commit is not an ancestor of HEAD: $($package.SourceCommit)"
    }
    $nonPackagedGatePaths = @(
        "native/verify-release.ps1",
        "native/verify-native.ps1",
        "native/test-release-gui-recovery-contract.ps1",
        "native/test-current-policy-contract.ps1",
        "native/restore-current-policy.ps1",
        "native/install-current-policy-task.ps1"
    )
    $driftPaths = @(
        & git -C $repositoryRoot diff `
            --name-only `
            $package.SourceCommit `
            $headCommit |
            Where-Object {
                $_ -and
                $_ -notmatch "^docs/" -and
                $_ -notmatch "^[^/]+\.md$" -and
                $nonPackagedGatePaths -notcontains $_
            }
    )
    if ($driftPaths.Count -gt 0) {
        throw ("Package evidence is stale: HEAD changed non-documentation " +
            "paths after the package source commit: " + ($driftPaths -join ", "))
    }
}
if ($VerifyShellIntegration) {
    $shell = Get-Content -LiteralPath $shellEvidence -Raw | ConvertFrom-Json
    if ($shell.Version -ne $Version -or
        $shell.SourcePackageCommit -ne $headCommit -or
        $shell.Cleanup -ne "PASS") {
        throw "Shell-integration evidence does not match the release candidate."
    }
}
if ($ExecuteNoChangePolicy) {
    $policy = Get-Content -LiteralPath $policyEvidence -Raw | ConvertFrom-Json
    if ($policy.SourceCommit -ne $headCommit -or
        $policy.WorkingTree -ne "Clean" -or
        $policy.PolicyDisabled -ne "PASS" -or
        $policy.Shutdown -ne "PASS") {
        throw "Power-policy evidence does not match the release candidate."
    }
}
if ($VerifyWorkerHang) {
    $workerHang = Get-Content -LiteralPath $workerHangEvidence -Raw | ConvertFrom-Json
    if ($workerHang.Version -ne $Version -or
        $workerHang.Verification -ne "PASS" -or
        $workerHang.GuiRespondingFailures -ne 0 -or
        $null -eq $workerHang.NewWorkerPid) {
        throw "Worker-hang replacement evidence does not match the release candidate."
    }
}
$result = [ordered]@{
    Version = $Version
    Verification = "PASS"
    Package = $package.Package
    SHA256 = $package.SHA256
    Size = $package.Size
    SourceCommit = $package.SourceCommit
    PackageEvidence = $packageEvidence
    ShellIntegration = $shellStatus
    ShellEvidence = if ($VerifyShellIntegration) { $shellEvidence } else { $null }
    NoChangePolicy = $policyStatus
    PolicyEvidence = if ($ExecuteNoChangePolicy) { $policyEvidence } else { $null }
    WorkerHang = $workerHangStatus
    WorkerHangEvidence = if ($VerifyWorkerHang) { $workerHangEvidence } else { $null }
    DpiFixtures = "PASS"
    DpiEvidence = $dpiEvidencePath
    SmallViewport = "PASS"
    SmallViewportEvidence = $smallViewportEvidencePath
    MaximizeScroll = "PASS"
    MaximizeScrollEvidence = $maximizeEvidencePath
    Reproducibility = $reproducibilityStatus
    ReproducibilityEvidence = if ($VerifyReproducibility) {
        $reproducibilityEvidencePath
    }
    else {
        $null
    }
    RecordedAt = (Get-Date).ToString("o")
}

$evidenceDirectory = Split-Path -Parent $EvidencePath
if ($evidenceDirectory) {
    New-Item -ItemType Directory -Path $evidenceDirectory -Force | Out-Null
}
$result |
    ConvertTo-Json -Depth 8 |
    Set-Content -LiteralPath $EvidencePath -Encoding UTF8

$result | Format-List
}
catch {
    $verificationFailure = $_
    throw
}
finally {
    try {
        $stableRecoveryResult = Restore-StableGuiAfterReleaseGate
        Write-Output ("Stable GUI recovery: PASS initialRunning={0} gui={1} worker={2} target={3}/{4}" -f `
            $stableRecoveryResult.InitialGuiRunning,
            $stableRecoveryResult.RestoredGuiPid,
            $stableRecoveryResult.RestoredWorkerPid,
            $stableRecoveryResult.BatteryWatts,
            $stableRecoveryResult.AcWatts)
        if (Test-Path -LiteralPath $EvidencePath -PathType Leaf) {
            $document = Get-Content -LiteralPath $EvidencePath -Raw | ConvertFrom-Json
            $document | Add-Member `
                -NotePropertyName "InitialStableGui" `
                -NotePropertyValue ([pscustomobject]@{
                    Running = $stableRecoveryResult.InitialGuiRunning
                    ProcessId = $stableRecoveryResult.InitialGuiPid
                    Arguments = $stableRecoveryResult.InitialGuiArguments
                }) `
                -Force
            $document | Add-Member `
                -NotePropertyName "StableGuiRecovery" `
                -NotePropertyValue $stableRecoveryResult `
                -Force
            $document |
                ConvertTo-Json -Depth 10 |
                Set-Content -LiteralPath $EvidencePath -Encoding UTF8
        }
        elseif ($null -ne $verificationFailure) {
            $evidenceDirectory = Split-Path -Parent $EvidencePath
            if ($evidenceDirectory) {
                New-Item -ItemType Directory -Path $evidenceDirectory -Force | Out-Null
            }
            [ordered]@{
                Version = $Version
                Verification = "FAIL"
                Error = $verificationFailure.Exception.Message
                InitialStableGui = [pscustomobject]@{
                    Running = $stableRecoveryResult.InitialGuiRunning
                    ProcessId = $stableRecoveryResult.InitialGuiPid
                    Arguments = $stableRecoveryResult.InitialGuiArguments
                }
                StableGuiRecovery = $stableRecoveryResult
                RecordedAt = (Get-Date).ToString("o")
            } |
                ConvertTo-Json -Depth 10 |
                Set-Content -LiteralPath $EvidencePath -Encoding UTF8
        }
    }
    catch {
        $recoveryError = $_
        if (-not (Test-Path -LiteralPath $EvidencePath -PathType Leaf)) {
            $evidenceDirectory = Split-Path -Parent $EvidencePath
            if ($evidenceDirectory) {
                New-Item -ItemType Directory -Path $evidenceDirectory -Force | Out-Null
            }
            [ordered]@{
                Version = $Version
                Verification = "FAIL"
                Error = if ($null -ne $verificationFailure) {
                    $verificationFailure.Exception.Message
                }
                else {
                    $null
                }
                InitialStableGui = [pscustomobject]@{
                    Running = $script:stableGuiSnapshot.Count -gt 0
                    ProcessId = if ($script:stableGuiSnapshot.Count -gt 0) {
                        $script:stableGuiSnapshot[0].Id
                    }
                    else {
                        $null
                    }
                    Arguments = if ($script:stableGuiSnapshot.Count -gt 0) {
                        $script:stableGuiSnapshot[0].Arguments
                    }
                    else {
                        $null
                    }
                }
                StableGuiRecovery = [pscustomobject]@{
                    Status = "FAIL"
                    Error = $recoveryError.Exception.Message
                }
                RecordedAt = (Get-Date).ToString("o")
            } |
                ConvertTo-Json -Depth 8 |
                Set-Content -LiteralPath $EvidencePath -Encoding UTF8
        }
        if ($null -ne $verificationFailure) {
            throw [System.InvalidOperationException]::new(
                ("Release verification failed: {0}; stable GUI recovery also failed: {1}" -f `
                    $verificationFailure.Exception.Message,
                    $recoveryError.Exception.Message),
                $verificationFailure.Exception)
        }
        throw
    }
}
