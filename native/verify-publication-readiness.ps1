# Requires PowerShell 7+ ([System.IO.Path]::GetRelativePath).
param(
    [string]$Version = "1.0.0-native",
    [string]$EvidencePath
)

$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSCommandPath
$repositoryRoot = Split-Path -Parent $root
$artifactsRoot = [System.IO.Path]::GetFullPath(
    (Join-Path $repositoryRoot "artifacts"))
$guiArgumentContractPath = Join-Path $root "gui-cli-contract.json"

function Get-GuiArgumentContract {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "GUI argument contract is missing: $Path"
    }
    return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Test-ShortcutArgumentsAgainstContract {
    param(
        [AllowEmptyString()]
        [string]$Arguments,
        [Parameter(Mandatory = $true)]
        $Contract
    )

    $unsupported = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($Arguments)) {
        $tokens = @(
            $Arguments -split "\s+" |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $index = 0
        while ($index -lt $tokens.Count) {
            $token = $tokens[$index]
            $entry = $Contract.arguments.PSObject.Properties[$token]
            if ($null -eq $entry) {
                $unsupported.Add($token)
                $index += 1
                continue
            }
            if ([bool]$entry.Value.takesValue) {
                if ($index + 1 -ge $tokens.Count) {
                    $unsupported.Add("$token (missing value)")
                    break
                }
                $index += 2
                continue
            }
            $index += 1
        }
    }
    return [pscustomobject]@{
        Supported = ($unsupported.Count -eq 0)
        Unsupported = @($unsupported)
    }
}

# Launches the deployed GUI with the exact shortcut arguments under an
# isolated LOCALAPPDATA and a unique worker pipe. This is the check that
# catches argument-parser drift before a release gate claims readiness.
function Test-ShortcutGuiLaunch {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Executable,
        [AllowEmptyString()]
        [string]$Arguments
    )

    $isolatedLocalAppData = [System.IO.Path]::GetFullPath(
        (Join-Path $artifactsRoot "publication-launch-$([Guid]::NewGuid().ToString('N'))"))
    if (-not $isolatedLocalAppData.StartsWith(
        $artifactsRoot + [System.IO.Path]::DirectorySeparatorChar,
        [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Unsafe launch-check directory: $isolatedLocalAppData"
    }
    $pipeName = "AmdMobilePower.Worker.readiness.$([Guid]::NewGuid().ToString('N').Substring(0, 8))"
    $stderrPath = Join-Path $isolatedLocalAppData "gui-stderr.txt"
    $argumentList = @()
    if (-not [string]::IsNullOrWhiteSpace($Arguments)) {
        $argumentList += @(
            $Arguments -split "\s+" |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }
    $argumentList += @("--pipe-name", $pipeName)
    $previousLocalAppData = $env:LOCALAPPDATA
    $process = $null
    try {
        New-Item -ItemType Directory -Path $isolatedLocalAppData -Force | Out-Null
        $env:LOCALAPPDATA = $isolatedLocalAppData
        $process = Start-Process `
            -FilePath $Executable `
            -WorkingDirectory (Split-Path -Parent $Executable) `
            -ArgumentList $argumentList `
            -RedirectStandardError $stderrPath `
            -PassThru
        $windowReady = $false
        $exitedEarly = $false
        $exitCode = $null
        $deadline = [DateTime]::UtcNow.AddSeconds(12)
        while ([DateTime]::UtcNow -lt $deadline) {
            $process.Refresh()
            if ($process.HasExited) {
                $exitedEarly = $true
                $exitCode = $process.ExitCode
                break
            }
            if ($process.MainWindowHandle -ne [IntPtr]::Zero -and
                $process.MainWindowTitle -like "AMD Mobile Power*") {
                $windowReady = $true
                break
            }
            Start-Sleep -Milliseconds 250
        }
        $stderrText = ""
        if (Test-Path -LiteralPath $stderrPath -PathType Leaf) {
            # In PowerShell 7, [string]$null stays $null, so an empty stderr file
            # would otherwise throw on .Trim().
            $rawStderr = Get-Content -LiteralPath $stderrPath -Raw
            if ($null -ne $rawStderr) {
                $stderrText = ([string]$rawStderr).Trim()
            }
        }
        return [pscustomobject]@{
            Arguments = ($argumentList -join " ")
            WindowReady = $windowReady
            ExitedEarly = $exitedEarly
            ExitCode = $exitCode
            StandardError = $stderrText
            Note = if ($windowReady) {
                "GUI window observed."
            }
            elseif ($exitedEarly) {
                "GUI exited immediately; exit code 0 means the arguments parsed and another instance owns the single-instance mutex."
            }
            else {
                "GUI stayed alive but no window appeared within the timeout."
            }
        }
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
            Remove-Item `
                -LiteralPath $isolatedLocalAppData `
                -Recurse `
                -Force `
                -ErrorAction SilentlyContinue
        }
    }
}

function Read-JsonFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Required JSON file is missing: $Path"
    }
    return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Get-Sha256 {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).
        Hash.ToLowerInvariant()
}

function Get-BuildInfo {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $values = @{}
    foreach ($line in Get-Content -LiteralPath $Path) {
        if ($line -match "^([^=]+)=(.*)$") {
            $values[$Matches[1]] = $Matches[2]
        }
    }
    return $values
}

function Resolve-EvidencePath {
    param(
        [Parameter(Mandatory = $true)][string]$Directory,
        [Parameter(Mandatory = $true)][string[]]$Patterns
    )
    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) {
        return $null
    }
    foreach ($pattern in $Patterns) {
        $candidate = Get-ChildItem -LiteralPath $Directory -Filter $pattern -File |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1
        if ($candidate) { return $candidate.FullName }
    }
    return $null
}

function Read-JsonFileOptional {
    param([string]$Path)
    if ($Path -and (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return Read-JsonFile $Path
    }
    return $null
}

if (-not $EvidencePath) {
    $EvidencePath = Join-Path `
        $repositoryRoot `
        "docs\evidence\release\native-publication-readiness-$(Get-Date -Format 'yyyy-MM-dd').json"
}

$packageName = "amd-mobile-power-v$Version-win-x64-native-preview.zip"
$packagePath = Join-Path `
    (Join-Path $artifactsRoot "native-packages") `
    $packageName
$packagingEvidenceDir = Join-Path $repositoryRoot "docs\evidence\packaging"
$hardwareEvidenceDir = Join-Path $repositoryRoot "docs\evidence\hardware"
$uiEvidenceDir = Join-Path $repositoryRoot "docs\evidence\ui"
$mediaEvidenceDir = Join-Path $repositoryRoot "docs\evidence\media"
$buildEvidenceDir = Join-Path $repositoryRoot "docs\evidence\build"
$releaseGatePath = Resolve-EvidencePath $packagingEvidenceDir @(
    "v$Version-release-gate-*.json",
    "v$Version-native-release-gate-*.json"
)
$cleanEvidencePath = Resolve-EvidencePath $packagingEvidenceDir @(
    "v$Version-clean-*.json"
)
$deploymentEvidencePath = Resolve-EvidencePath $packagingEvidenceDir @(
    "v$Version-deployment-*.json",
    "v$Version-native-deployment-*.json"
)
$policyEvidencePath = Resolve-EvidencePath $hardwareEvidenceDir @(
    "v$Version-power-policy-no-change-*.json",
    "v$Version-native-power-policy-no-change-*.json"
)
$packagedUiEvidencePath = Resolve-EvidencePath $uiEvidenceDir @(
    "native-packaged-$Version-ui-*.json",
    "native-packaged-$Version-*.json",
    "frozen-$Version-panels-*.json"
)
$mediaEvidencePath = Resolve-EvidencePath $mediaEvidenceDir @(
    "native-promo-$Version-review-*.json",
    "native-promo-$Version-draft-*.json",
    "native-promo-review-v2-*.json",
    "native-promo-draft-*.json"
)
$compatibilityIndexPath = Join-Path `
    $repositoryRoot `
    "docs\evidence\compatibility\index.json"
$reviewBundle = Join-Path `
    $artifactsRoot `
    "native-release-review\v$Version"

if (-not (Test-Path -LiteralPath $packagePath -PathType Leaf)) {
    throw "Native package is missing: $packagePath"
}
$packageHash = Get-Sha256 $packagePath
$releaseGate = Read-JsonFileOptional $releaseGatePath
$cleanEvidence = Read-JsonFileOptional $cleanEvidencePath
$deployment = Read-JsonFileOptional $deploymentEvidencePath
$policyEvidence = Read-JsonFileOptional $policyEvidencePath
$packagedUi = Read-JsonFileOptional $packagedUiEvidencePath
$media = Read-JsonFileOptional $mediaEvidencePath
$compatibilityIndex = Read-JsonFile $compatibilityIndexPath

$checks = [ordered]@{}
$blockers = New-Object System.Collections.Generic.List[string]
$deployedGuiHash = if ($deployment.DeployedGuiSHA256) {
    $deployment.DeployedGuiSHA256
}
elseif ($deployment.DeployedHashes.gui) {
    $deployment.DeployedHashes.gui
}
else { $null }
$deployedWorkerHash = if ($deployment.DeployedWorkerSHA256) {
    $deployment.DeployedWorkerSHA256
}
elseif ($deployment.DeployedHashes.worker) {
    $deployment.DeployedHashes.worker
}
else { $null }
$deployedProbeHash = if ($deployment.DeployedProbeSHA256) {
    $deployment.DeployedProbeSHA256
}
elseif ($deployment.DeployedHashes.probe) {
    $deployment.DeployedHashes.probe
}
else { $null }

$checks.PackageHash = (
    $releaseGate.SHA256 -eq $packageHash -and
    $cleanEvidence.SHA256 -eq $packageHash -and
    $releaseGate.Version -eq $Version
)
if (-not $checks.PackageHash) {
    $blockers.Add("Package hash or version does not match the clean/release evidence.")
}

$checks.PackageVerification = (
    $cleanEvidence.Verification -eq "PASS" -and
    $cleanEvidence.ChecksumEntries -ge 16 -and
    $cleanEvidence.RuntimeVerification -eq "PASS"
)
if (-not $checks.PackageVerification) {
    $blockers.Add("Clean package verification is incomplete.")
}

$checks.NoChangePolicy = (
    $releaseGate.NoChangePolicy -eq "PASS" -and
    $policyEvidence.Verification -eq "PASS" -and
    $policyEvidence.PolicyDisabled -eq "PASS" -and
    $policyEvidence.Shutdown -eq "PASS"
)
if (-not $checks.NoChangePolicy) {
    $blockers.Add("Controlled current-value policy evidence is incomplete.")
}

$checks.PackagedUi = (
    $packagedUi.Verification -eq "PASS" -and
    $packagedUi.TaskbarIconAvailable -eq $true -and
    $packagedUi.TrayIconId -eq 1 -and
    $packagedUi.CloseToTray -eq "PASS" -and
    $packagedUi.TrayRestore -eq "PASS" -and
    $packagedUi.SingleInstanceWake -eq "PASS" -and
    $packagedUi.InitialUiMode -eq "simple" -and
    $packagedUi.FinalUiMode -eq "advanced"
)
if (-not $checks.PackagedUi) {
    $blockers.Add("Packaged GUI/tray/mode evidence is incomplete.")
}

$deployedBuildInfo = Get-BuildInfo (Join-Path "C:\RyzenAdj" "BUILD-INFO.txt")
$deployedGuiPath = Join-Path "C:\RyzenAdj" "amd-mobile-power-gui.exe"
$deployedWorkerPath = Join-Path "C:\RyzenAdj" "amdmobilepower_native_worker.exe"
# The deployment record may carry its own UI verdict, but a fresh packaged-GUI
# verification of the same executable hash is stronger evidence and is accepted
# in its place.
$packagedUiMatchesDeployment = (
    $packagedUi.Verification -eq "PASS" -and
    $packagedUi.GuiSHA256 -eq $deployedGuiHash
)
$checks.LocalDeployment = (
    (Test-Path -LiteralPath $deployedGuiPath -PathType Leaf) -and
    (Test-Path -LiteralPath $deployedWorkerPath -PathType Leaf) -and
    $deployedBuildInfo["Version"] -eq $Version -and
    (Get-Sha256 $deployedGuiPath) -eq $deployedGuiHash -and
    (Get-Sha256 $deployedWorkerPath) -eq $deployedWorkerHash -and
    ($deployment.UiVerification -eq "PASS" -or $packagedUiMatchesDeployment)
)
if (-not $checks.LocalDeployment) {
    $blockers.Add("C:\RyzenAdj does not match the recorded deployment evidence.")
}

$deployedProbePath = Join-Path "C:\RyzenAdj" "amd-mobile-power-probe.exe"
$checks.DeployedProbe = $false
if ((Test-Path -LiteralPath $deployedProbePath -PathType Leaf) -and
    $deployedProbeHash -and
    (Get-Sha256 $deployedProbePath) -eq $deployedProbeHash) {
    try {
        $probeSelfTest = & $deployedProbePath --self-test 2>$null | ConvertFrom-Json
        if ($LASTEXITCODE -eq 0 -and
            $probeSelfTest.selfTest -eq "PASS" -and
            $probeSelfTest.readOnlyByDefault -eq $true) {
            $checks.DeployedProbe = $true
        }
    }
    catch {
    }
}
if (-not $checks.DeployedProbe) {
    $blockers.Add(
        "Deployed headless probe is missing, does not match the deployment evidence, or failed --self-test.")
}

$checks.DeployedIcon = $false
if (Test-Path -LiteralPath $deployedGuiPath -PathType Leaf) {
    try {
        $null = & (Join-Path $root "check-exe-icon.ps1") -Path $deployedGuiPath
        $checks.DeployedIcon = $true
    }
    catch {
        $blockers.Add(
            "Deployed GUI has no embedded application icon: $($_.Exception.Message)")
    }
}
else {
    $blockers.Add("Deployed GUI is missing, so its icon resource cannot be verified.")
}

$shortcutPath = Join-Path `
    ([Environment]::GetFolderPath("Desktop")) `
    "功耗设置 5-60W.lnk"
# The recorded evidence is published, so the user-home prefix is redacted.
$shortcutDisplayPath = "<USER_HOME>\Desktop\功耗设置 5-60W.lnk"
$deployedGui = Join-Path "C:\RyzenAdj" "amd-mobile-power-gui.exe"
$shortcutArguments = ""
$checks.DesktopShortcut = $false
if (Test-Path -LiteralPath $shortcutPath -PathType Leaf) {
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcutArguments = [string]$shortcut.Arguments
    $checks.DesktopShortcut = (
        $shortcut.TargetPath -eq $deployedGui -and
        $shortcut.WorkingDirectory -eq "C:\RyzenAdj"
    )
}
if (-not $checks.DesktopShortcut) {
    $blockers.Add("Desktop shortcut target or arguments do not match the deployment.")
}

$argumentAudit = $null
$checks.ShortcutArguments = $false
if (Test-Path -LiteralPath $guiArgumentContractPath -PathType Leaf) {
    $guiContract = Get-GuiArgumentContract -Path $guiArgumentContractPath
    $argumentAudit = Test-ShortcutArgumentsAgainstContract `
        -Arguments $shortcutArguments `
        -Contract $guiContract
    $checks.ShortcutArguments = $argumentAudit.Supported
}
if (-not $checks.ShortcutArguments) {
    $rejected = @($argumentAudit.Unsupported) -join ", "
    $blockers.Add("Desktop shortcut passes arguments the native GUI rejects: $rejected")
}

$launchAudit = $null
$checks.ShortcutLaunch = $false
if ($checks.DesktopShortcut) {
    $launchAudit = Test-ShortcutGuiLaunch `
        -Executable $deployedGui `
        -Arguments $shortcutArguments
    $checks.ShortcutLaunch = (
        $launchAudit.WindowReady -or
        ($launchAudit.ExitedEarly -and
            $launchAudit.ExitCode -eq 0 -and
            [string]::IsNullOrWhiteSpace($launchAudit.StandardError))
    )
}
if (-not $checks.ShortcutLaunch) {
    $blockers.Add(
        "Desktop shortcut does not launch the native GUI: $($launchAudit.StandardError)")
}

$checks.CompatibilityIndex = (
    $null -ne $compatibilityIndex -and
    @($compatibilityIndex).Count -ge 1
)
if (-not $checks.CompatibilityIndex) {
    $blockers.Add("No sanitized compatibility report is indexed.")
}

$mediaVideoRelative = if ($media.video.path) {
    $media.video.path
}
elseif ($media.Video) {
    $media.Video
}
else { $null }
$mediaVideoHash = if ($media.video.sha256) {
    $media.video.sha256
}
elseif ($media.VideoSHA256) {
    $media.VideoSHA256
}
else { $null }
$mediaStatus = if ($media.status) { $media.status } else { $media.Status }
$mediaDecode = if ($media.verification.ffmpegFullDecode) {
    $media.verification.ffmpegFullDecode
}
else { $media.FullDecode }
$videoPath = if ($mediaVideoRelative) {
    Join-Path $repositoryRoot ($mediaVideoRelative -replace "/", "\")
}
else { $null }
$checks.MediaDraft = (
    $videoPath -and
    (Test-Path -LiteralPath $videoPath -PathType Leaf) -and
    (Get-Sha256 $videoPath) -eq $mediaVideoHash -and
    $mediaStatus -eq "DRAFT_FOR_HUMAN_REVIEW" -and
    $mediaDecode -eq "PASS"
)
if (-not $checks.MediaDraft) {
    $blockers.Add("Native promotional-video draft or media evidence is incomplete.")
}

$checks.ReviewBundle = $false
$bundleChecksums = Join-Path $reviewBundle "SHA256SUMS.txt"
if (Test-Path -LiteralPath $bundleChecksums -PathType Leaf) {
    $checks.ReviewBundle = $true
    foreach ($line in Get-Content -LiteralPath $bundleChecksums) {
        if ($line -notmatch "^([a-f0-9]{64})  (.+)$") {
            $checks.ReviewBundle = $false
            break
        }
        $bundleFile = Join-Path $reviewBundle $Matches[2]
        if (-not (Test-Path -LiteralPath $bundleFile -PathType Leaf) -or
            (Get-Sha256 $bundleFile) -ne $Matches[1]) {
            $checks.ReviewBundle = $false
            break
        }
    }
}
if (-not $checks.ReviewBundle) {
    $blockers.Add("Native review bundle checksums are incomplete or invalid.")
}

$dpiEvidencePath = Resolve-EvidencePath $uiEvidenceDir @(
    "native-dpi-$Version-*.json",
    "native-dpi-100-125-150-*.json"
)
$dpiGate = "PENDING"
$dpiEvidence = $null
if (Test-Path -LiteralPath $dpiEvidencePath -PathType Leaf) {
    $dpiEvidence = Get-Content -LiteralPath $dpiEvidencePath -Raw -Encoding UTF8 |
        ConvertFrom-Json
    $expectedDpiSizes = [ordered]@{
        "100" = "600x360|780x680"
        "125" = "750x450|975x850"
        "150" = "900x540|1170x1020"
    }
    $dpiResultsValid = $dpiEvidence.Verification -eq "PASS"
    foreach ($scale in $expectedDpiSizes.Keys) {
        $entry = @($dpiEvidence.Scales) |
            Where-Object { [int]$_.Scale -eq [int]$scale } |
            Select-Object -First 1
        $actual = if ($null -ne $entry) {
            "$($entry.SimpleClientSize)|$($entry.AdvancedClientSize)"
        }
        else {
            ""
        }
        $imagesValid = $null -ne $entry -and
            (Test-Path -LiteralPath $entry.SimpleImage -PathType Leaf) -and
            (Test-Path -LiteralPath $entry.AdvancedImage -PathType Leaf)
        if ($actual -ne $expectedDpiSizes[[string]$scale] -or -not $imagesValid) {
            $dpiResultsValid = $false
            break
        }
    }
    if ($dpiResultsValid) {
        $dpiGate = "PASS"
    }
}

$hostedCiEvidencePath = Resolve-EvidencePath $buildEvidenceDir @(
    "hosted-ci-$Version-*.json",
    "hosted-ci-post-deployment-*.json",
    "hosted-ci-*.json"
)
$hostedCiGate = "PENDING"
$hostedCiEvidence = $null
if (Test-Path -LiteralPath $hostedCiEvidencePath -PathType Leaf) {
    $hostedCiEvidence = Get-Content -LiteralPath $hostedCiEvidencePath -Raw -Encoding UTF8 |
        ConvertFrom-Json
    if ($hostedCiEvidence.conclusion -eq "success" -and
        $hostedCiEvidence.workflow -eq "build" -and
        $hostedCiEvidence.commit) {
        $hostedCiCommit = [string]$hostedCiEvidence.commit
        & git -C $repositoryRoot cat-file -e "$hostedCiCommit^{commit}" 2>$null
        $commitKnown = ($LASTEXITCODE -eq 0)
        if ($commitKnown) {
            & git -C $repositoryRoot merge-base --is-ancestor $hostedCiCommit HEAD 2>$null
            $isAncestor = ($LASTEXITCODE -eq 0)
            $changedSince = @(
                & git -C $repositoryRoot diff --name-only "$hostedCiCommit..HEAD" 2>$null
            )
            $nativeChangedSince = @(
                $changedSince | Where-Object {
                    $_ -match '^(native/|\.github/|build-ryzenadj\.ps1$|build\.ps1$)' -or
                    $_ -match '(^|/)Cargo\.(toml|lock)$'
                }
            ).Count -gt 0
            if ($isAncestor -and -not $nativeChangedSince) {
                $hostedCiGate = "PASS"
            }
        }
    }
}

$openGates = [ordered]@{
    SecondAmdDevice = "PENDING"
    DpiLayoutFixtures100And150 = $dpiGate
    Dpi100And150SystemSessions = "PENDING"
    HostedWindowsCi = $hostedCiGate
    CleanWindowsWinRing0Baseline = "PENDING"
    HumanVideoAndClaimReview = "PENDING"
    ExplicitPublicReleaseApproval = "PENDING"
    BilibiliAuthenticatedUpload = "PENDING"
}

$localChecksPass = -not ($checks.Values -contains $false)
$result = [ordered]@{
    SchemaVersion = 1
    Version = $Version
    Package = $packageName
    PackageSHA256 = $packageHash
    LocalDeployment = "C:\RyzenAdj"
    Checks = $checks
    LocalReadiness = if ($localChecksPass) { "PASS" } else { "FAIL" }
    PublicReleaseReadiness = if ($localChecksPass) {
        "READY_FOR_HUMAN_REVIEW"
    }
    else {
        "BLOCKED_BY_LOCAL_CHECKS"
    }
    DesktopShortcut = [ordered]@{
        Path = $shortcutDisplayPath
        Arguments = $shortcutArguments
        RejectedArguments = @($argumentAudit.Unsupported)
        Launch = $launchAudit
    }
    OpenGates = $openGates
    DpiFixtures = [ordered]@{
        Evidence = [System.IO.Path]::GetRelativePath(
            $repositoryRoot,
            $dpiEvidencePath).Replace("\", "/")
        Verification = $dpiGate
        Scales = if ($null -ne $dpiEvidence) { $dpiEvidence.Scales } else { @() }
    }
    HostedCi = [ordered]@{
        Evidence = [System.IO.Path]::GetRelativePath(
            $repositoryRoot,
            $hostedCiEvidencePath).Replace("\", "/")
        Verification = $hostedCiGate
        RunId = if ($null -ne $hostedCiEvidence) { $hostedCiEvidence.runId } else { $null }
        Commit = if ($null -ne $hostedCiEvidence) { $hostedCiEvidence.commit } else { $null }
    }
    BlockersFromLocalChecks = @($blockers)
    Note = "No GitHub login, Bilibili login, upload, publication, or power write was performed by this check. The shortcut launch audit runs the deployed GUI with an isolated LOCALAPPDATA and a unique worker pipe, then stops it."
    RecordedAt = (Get-Date).ToString("o")
}

$evidenceDirectory = Split-Path -Parent $EvidencePath
if ($evidenceDirectory) {
    New-Item -ItemType Directory -Path $evidenceDirectory -Force | Out-Null
}
$result | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $EvidencePath -Encoding UTF8
$result | Format-List

if (-not $localChecksPass) {
    exit 1
}
