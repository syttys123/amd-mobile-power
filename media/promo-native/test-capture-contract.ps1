param(
    [string]$EvidencePath
)

$ErrorActionPreference = "Stop"
$promoRoot = $PSScriptRoot
$repositoryRoot = Split-Path -Parent (Split-Path -Parent $promoRoot)
$artifactsRoot = [System.IO.Path]::GetFullPath(
    (Join-Path $repositoryRoot "artifacts"))
$capturePath = Join-Path $promoRoot "capture-live-demo.ps1"
$captureText = Get-Content -LiteralPath $capturePath -Raw
$results = [System.Collections.Generic.List[object]]::new()

function Add-ContractResult {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter(Mandatory = $true)]
        [bool]$Passed,
        [Parameter(Mandatory = $true)]
        [string]$Detail
    )

    $results.Add([ordered]@{
        Name = $Name
        Passed = $Passed
        Detail = $Detail
    })
    $status = if ($Passed) { "PASS" } else { "FAIL" }
    Write-Host ("{0} {1} :: {2}" -f $status, $Name, $Detail)
}

function Assert-ContractCondition {
    param(
        [Parameter(Mandatory = $true)]
        [bool]$Condition,
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Test-ContractThrows {
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$Action
    )

    try {
        & $Action
        return $false
    }
    catch {
        return $true
    }
}

$parseErrors = $null
[System.Management.Automation.Language.Parser]::ParseFile(
    $capturePath,
    [ref]$null,
    [ref]$parseErrors) | Out-Null
Add-ContractResult `
    -Name "script-parses" `
    -Passed ($parseErrors.Count -eq 0) `
    -Detail "PowerShell AST errors: $($parseErrors.Count)"
if ($parseErrors.Count -gt 0) {
    $parseErrors | ForEach-Object {
        Write-Host $_.Message
    }
    exit 1
}

# ContractOnly defines the pure functions and returns before output paths,
# fixture state, process launch, Add-Type captures, or any hardware path.
. $capturePath -GuiExecutable "fixture-not-launched.exe" -ContractOnly

try {
    $simple = @(Get-LiveDemoTimeline -Mode simple -DemoType auto)
    $simpleCommands = @($simple | ForEach-Object { [int]$_.Command })
    $simpleWatts = @($simple | ForEach-Object { [int]$_.ExpectedWatts })
    $simpleSchemaPreserved = $captureText -match (
        'SchemaVersion\s*=\s*if\s*\(\$Mode\s+-eq\s+"simple"\)' +
        '\s*\{\s*1\s*\}\s*else\s*\{\s*2\s*\}')
    Add-ContractResult `
        -Name "simple-legacy-compatibility" `
        -Passed (
            $simple.Count -eq 3 -and
            ($simpleCommands -join ",") -eq "102,103,101" -and
            ($simpleWatts -join ",") -eq "25,45,10" -and
            @($simple | Where-Object { $_.Action -ne "command" }).Count -eq 0 -and
            $simpleSchemaPreserved
        ) `
        -Detail (
            "events=$($simple.Count); commands=$($simpleCommands -join ',')" +
            "; watts=$($simpleWatts -join ','); " +
            "schema1=$simpleSchemaPreserved")

    $simple[0].ActualAt = 1.61
    $simple[0].DispatchCompleted = $true
    $simple[0].Completed = $true
    $simple[0].CompletionStatus = "visible-change-observed"
    $simple[0].VisualChangedPixels = 50
    $simple[0].VisualFrameIndex = 41
    $simple[0].VisualAt = 1.64
    $simple[0].ClickX = 0.25
    $simple[0].ClickY = 0.33
    $simpleEvent = ConvertTo-LiveDemoManifestEvent -Step $simple[0]
    Add-ContractResult `
        -Name "simple-manifest-fields" `
        -Passed (
            $simpleEvent.Action -eq "command" -and
            [int]$simpleEvent.Command -eq 102 -and
            [int]$simpleEvent.PresetIndex -eq 1 -and
            [int]$simpleEvent.ExpectedWatts -eq 25 -and
            $simpleEvent.Completed -eq $true -and
            $simpleEvent.CompletionStatus -eq "visible-change-observed" -and
            $simpleEvent.VisualFrameIndex -eq 41
        ) `
        -Detail (
            "action=$($simpleEvent.Action); command=$($simpleEvent.Command); " +
            "visualFrame=$($simpleEvent.VisualFrameIndex)")

    $advancedDefault = Resolve-LiveDemoType `
        -Mode advanced `
        -DemoType auto
    $presets = @(Get-LiveDemoTimeline `
        -Mode advanced `
        -DemoType auto)
    $presetTexts = @(
        $presets |
            Where-Object {
                $_.Action -eq "set_text" -and [int]$_.ControlId -eq 301
            } |
            ForEach-Object { [string]$_.Text }
    )
    $presetSaveCount = @(
        $presets |
            Where-Object {
                $_.Action -eq "command" -and [int]$_.Command -eq 106
            }
    ).Count
    $presetApplyCount = @(
        $presets |
            Where-Object {
                $_.Action -eq "command" -and [int]$_.Command -eq 101
            }
    ).Count
    Add-ContractResult `
        -Name "advanced-preset-editing" `
        -Passed (
            $advancedDefault -eq "presets" -and
            $presets.Count -eq 6 -and
            ($presetTexts -join ",") -eq "12,10" -and
            $presetSaveCount -eq 2 -and
            $presetApplyCount -eq 2
        ) `
        -Detail (
            "type=$advancedDefault; events=$($presets.Count); " +
            "edits=$($presetTexts -join ','); saves=$presetSaveCount; " +
            "applies=$presetApplyCount")

    $policy = @(Get-LiveDemoTimeline `
        -Mode advanced `
        -DemoType policy)
    $policySequence = @($policy | ForEach-Object {
        if ($_.Action -eq "set_text") {
            "{0}:{1}={2}" -f $_.Action, $_.ControlId, $_.Text
        }
        else {
            "{0}:{1}" -f $_.Action, $_.Command
        }
    })
    $expectedPolicySequence = @(
        "set_text:312=25",
        "set_text:314=45",
        "command:315",
        "command:105",
        "command:318",
        "command:105",
        "command:318",
        "command:105"
    )
    Add-ContractResult `
        -Name "advanced-policy-operations" `
        -Passed (
            $policy.Count -eq 8 -and
            ($policySequence -join "|") -eq
                ($expectedPolicySequence -join "|")
        ) `
        -Detail ("sequence=" + ($policySequence -join ","))

    $timeOrdered = $true
    for ($index = 1; $index -lt $policy.Count; $index++) {
        if ([double]$policy[$index].At -le
            [double]$policy[$index - 1].At) {
            $timeOrdered = $false
        }
    }
    $policyIdsPresent = @(
        $policy |
            Where-Object { $null -eq $_.ControlId -or [int]$_.ControlId -le 0 }
    ).Count -eq 0
    Add-ContractResult `
        -Name "event-control-identity" `
        -Passed ($timeOrdered -and $policyIdsPresent) `
        -Detail (
            "strictlyOrdered=$timeOrdered; " +
            "allPolicyEventsHaveControlId=$policyIdsPresent")

    $stateSeed = New-LiveDemoStateSeed `
        -Mode advanced `
        -ResolvedDemoType policy
    Add-ContractResult `
        -Name "policy-fixture-seed" `
        -Passed (
            $stateSeed.powerPolicy.enabled -eq $false -and
            [int]$stateSeed.powerPolicy.batteryTarget.stapmWatts -eq 12 -and
            [int]$stateSeed.powerPolicy.acTarget.stapmWatts -eq 35
        ) `
        -Detail (
            "enabled=$($stateSeed.powerPolicy.enabled); battery=12; " +
            "ac=35; seeded values make both policy edits observable")

    $width = 8
    $height = 8
    $stride = $width * 4
    $baselineBytes = [byte[]]::new($stride * $height)
    $currentBytes = [byte[]]::new($stride * $height)
    $baseline = [pscustomobject]@{
        Width = $width
        Height = $height
        Stride = $stride
        Bytes = $baselineBytes
    }
    $unchanged = [pscustomobject]@{
        Width = $width
        Height = $height
        Stride = $stride
        Bytes = $currentBytes
    }
    $visibleBytes = [byte[]]::new($stride * $height)
    $visibleBytes[0] = 255
    $visible = [pscustomobject]@{
        Width = $width
        Height = $height
        Stride = $stride
        Bytes = $visibleBytes
    }
    $blankNonBlankCount = Measure-LiveDemoNonBlankPixels `
        -Snapshot $baseline `
        -SampleStep 1
    $visibleNonBlankCount = Measure-LiveDemoNonBlankPixels `
        -Snapshot $visible `
        -SampleStep 1
    $unchangedCount = Measure-LiveDemoVisualChange `
        -Baseline $baseline `
        -Current $unchanged `
        -SampleStep 1
    $currentBytes[0] = 255
    $changedCount = Measure-LiveDemoVisualChange `
        -Baseline $baseline `
        -Current $unchanged `
        -SampleStep 1
    $visualThresholdPass = (
        (Test-LiveDemoVisualChange `
            -Baseline $baseline `
            -Current $unchanged `
            -SampleStep 1 `
            -MinChangedPixels 1) -and
        -not (Test-LiveDemoVisualChange `
            -Baseline $baseline `
            -Current $unchanged `
            -SampleStep 1 `
            -MinChangedPixels 2)
    )
    Add-ContractResult `
        -Name "visual-completion-heuristic" `
        -Passed (
            $unchangedCount -eq 0 -and
            $changedCount -eq 1 -and
            $visualThresholdPass
        ) `
        -Detail (
            "unchanged=$unchangedCount; changed=$changedCount; " +
            "thresholdPass=$visualThresholdPass")

    Add-ContractResult `
        -Name "blank-baseline-rejected" `
        -Passed (
            $blankNonBlankCount -eq 0 -and
            $visibleNonBlankCount -eq 1 -and
            -not (Test-LiveDemoSnapshotNonBlank `
                -Snapshot $baseline `
                -SampleStep 1) -and
            (Test-LiveDemoSnapshotNonBlank `
                -Snapshot $visible `
                -SampleStep 1) -and
            $captureText -match (
                '(?s)function Get-LiveDemoClientSnapshot.*?' +
                'Test-LiveDemoSnapshotNonBlank.*?' +
                'Captured client baseline is blank')
        ) `
        -Detail (
            "blank=$blankNonBlankCount; visible=$visibleNonBlankCount; " +
            "blankRejected=True")

    $capturedBaselinePath = (
        $captureText -match (
            '(?s)function New-CapturedClientBitmap.*?' +
            'PrintWindow\(\s*\$Window,\s*\$hdc,\s*3\)') -and
        $captureText -match (
            '(?s)function Get-LiveDemoClientSnapshot.*?' +
            '\$bitmap = New-CapturedClientBitmap -Window \$Window') -and
        $captureText -match (
            '\$step\.BaselineNonBlankPixels\s*=') -and
        $captureText -match 'BaselineNonBlankPixels = \$Step\.BaselineNonBlankPixels'
    )
    Add-ContractResult `
        -Name "captured-baseline-path" `
        -Passed $capturedBaselinePath `
        -Detail (
            "baselineUsesPrintWindow=$capturedBaselinePath; " +
            "baselinePixelCountRecorded=True")

    Add-ContractResult `
        -Name "visual-change-required-before-complete" `
        -Passed (
            $captureText -match (
                '(?s)\$changed\s*=\s*Measure-LiveDemoVisualChange.*?' +
                'if\s*\(\$changed\s+-ge\s+\$VisualChangeMinPixels\).*?' +
                '\$step\.Completed\s*=\s*\$true') -and
            $captureText -match (
                'Completed=true only after a sampled client-pixel change') -and
            $captureText -match (
                '\$step\.CompletionStatus\s*=\s*"awaiting-visible-change"')
        ) `
        -Detail "Completed is set only by the sampled pixel-change branch"

    $privacyTitle = Get-LiveDemoWindowTitle
    Add-ContractResult `
        -Name "fixture-title-privacy" `
        -Passed (
            $privacyTitle.Length -le 80 -and
            $privacyTitle -match '^AMD Mobile Power' -and
            $privacyTitle -notmatch '[0-9a-fA-F]{16,}' -and
            $privacyTitle -notmatch '(?i)worker|pipe|livedemo|guid' -and
            $captureText -match (
                'SetWindowTextW\(\s*\$window,\s*\(Get-LiveDemoWindowTitle\)')
        ) `
        -Detail "title=$privacyTitle"

    $insideOutput = Join-Path $artifactsRoot "media\contract-output"
    $insideClip = Join-Path $artifactsRoot "media\contract-output\clip.mp4"
    $outsideOutput = Join-Path $repositoryRoot "outside-artifacts.mp4"
    $insideAccepted = $false
    $outsideRejected = $false
    try {
        $resolvedInside = Assert-LiveDemoArtifactsPath `
            -Path $insideOutput `
            -ArtifactsRoot $artifactsRoot
        $resolvedClip = Assert-LiveDemoArtifactsPath `
            -Path $insideClip `
            -ArtifactsRoot $artifactsRoot
        $insideAccepted = (
            $resolvedInside.StartsWith($artifactsRoot) -and
            $resolvedClip.StartsWith($artifactsRoot))
    }
    catch {
        $insideAccepted = $false
    }
    $outsideRejected = Test-ContractThrows {
        Assert-LiveDemoArtifactsPath `
            -Path $outsideOutput `
            -ArtifactsRoot $artifactsRoot
    }
    Add-ContractResult `
        -Name "artifacts-path-boundary" `
        -Passed ($insideAccepted -and $outsideRejected) `
        -Detail (
            "insideAccepted=$insideAccepted; " +
            "outsideRejected=$outsideRejected")

    $ownedState = Join-Path `
        $artifactsRoot `
        ("media\live-demo-state-" + [Guid]::NewGuid().ToString("N"))
    $outsideState = Join-Path $repositoryRoot "live-demo-state-fixture"
    $nonGuidState = Join-Path $artifactsRoot "media\live-demo-state-fixture"
    $ownedStateAccepted = Test-LiveDemoOwnedStateDirectoryPath `
        -StateDirectory $ownedState `
        -ArtifactsRoot $artifactsRoot
    $outsideStateRejected = -not (
        Test-LiveDemoOwnedStateDirectoryPath `
            -StateDirectory $outsideState `
            -ArtifactsRoot $artifactsRoot)
    $nonGuidStateRejected = -not (
        Test-LiveDemoOwnedStateDirectoryPath `
            -StateDirectory $nonGuidState `
            -ArtifactsRoot $artifactsRoot)
    $outsideCleanupRejected = Test-ContractThrows {
        Remove-LiveDemoStateDirectory `
            -StateDirectory $outsideState `
            -ArtifactsRoot $artifactsRoot
    }
    $cleanupProbe = Join-Path `
        $artifactsRoot `
        ("media\live-demo-state-" + [Guid]::NewGuid().ToString("N"))
    $cleanupProbeNested = Join-Path $cleanupProbe "AmdMobilePower"
    $cleanupProbeLogs = Join-Path $cleanupProbeNested "logs"
    $cleanupProbeCaches = Join-Path `
        $cleanupProbe `
        "Microsoft\Windows\Caches"
    $ownedStateCleaned = $false
    try {
        New-Item -ItemType Directory -Path $cleanupProbeNested -Force |
            Out-Null
        New-Item -ItemType Directory -Path $cleanupProbeLogs -Force |
            Out-Null
        New-Item -ItemType Directory -Path $cleanupProbeCaches -Force |
            Out-Null
        [System.IO.File]::WriteAllText(
            (Join-Path $cleanupProbeNested "rust-ui-state.json"),
            "{}",
            [System.Text.UTF8Encoding]::new($false))
        [System.IO.File]::WriteAllText(
            (Join-Path $cleanupProbeLogs "worker.log"),
            "fixture log",
            [System.Text.UTF8Encoding]::new($false))
        [System.IO.File]::WriteAllText(
            (Join-Path $cleanupProbe "root.log"),
            "root log",
            [System.Text.UTF8Encoding]::new($false))
        [System.IO.File]::WriteAllText(
            (Join-Path $cleanupProbeCaches "cache.tmp"),
            "cache",
            [System.Text.UTF8Encoding]::new($false))
        Remove-LiveDemoStateDirectory `
            -StateDirectory $cleanupProbe `
            -ArtifactsRoot $artifactsRoot
        $ownedStateCleaned = -not (Test-Path -LiteralPath $cleanupProbe)
    }
    finally {
        if (Test-Path -LiteralPath $cleanupProbe) {
            Remove-LiveDemoStateDirectory `
                -StateDirectory $cleanupProbe `
                -ArtifactsRoot $artifactsRoot
        }
    }
    Add-ContractResult `
        -Name "owned-state-cleanup-boundary" `
        -Passed (
            $ownedStateAccepted -and
            $outsideStateRejected -and
            $nonGuidStateRejected -and
            $outsideCleanupRejected -and
            $ownedStateCleaned
        ) `
        -Detail (
            "ownedAccepted=$ownedStateAccepted; " +
            "outsideRejected=$outsideStateRejected; " +
            "nonGuidRejected=$nonGuidStateRejected; " +
            "outsideCleanupRejected=$outsideCleanupRejected; " +
            "ownedStateCleaned=$ownedStateCleaned")

    $reparseProbe = Join-Path `
        $artifactsRoot `
        ("media\live-demo-state-" + [Guid]::NewGuid().ToString("N"))
    $reparseProbeNested = Join-Path $reparseProbe "AmdMobilePower"
    $reparseProbeOwnedFile = Join-Path `
        $reparseProbeNested `
        "rust-ui-state.json"
    $reparseTarget = Join-Path `
        $artifactsRoot `
        ("media\live-demo-cleanup-target-" + [Guid]::NewGuid().ToString("N"))
    $reparseTargetSentinel = Join-Path $reparseTarget "sentinel.txt"
    $reparseJunction = Join-Path $reparseProbe "linked-target"
    $reparseRejected = $false
    $reparseOwnedFilePreserved = $false
    $reparseTargetPreserved = $false
    try {
        New-Item -ItemType Directory -Path $reparseProbeNested -Force |
            Out-Null
        New-Item -ItemType Directory -Path $reparseTarget -Force |
            Out-Null
        [System.IO.File]::WriteAllText(
            $reparseProbeOwnedFile,
            "{}",
            [System.Text.UTF8Encoding]::new($false))
        [System.IO.File]::WriteAllText(
            $reparseTargetSentinel,
            "outside-owned-root",
            [System.Text.UTF8Encoding]::new($false))
        New-Item `
            -ItemType Junction `
            -Path $reparseJunction `
            -Target $reparseTarget `
            -ErrorAction Stop | Out-Null
        $reparseRejected = Test-ContractThrows {
            Remove-LiveDemoStateDirectory `
                -StateDirectory $reparseProbe `
                -ArtifactsRoot $artifactsRoot
        }
        $reparseOwnedFilePreserved = Test-Path `
            -LiteralPath $reparseProbeOwnedFile `
            -PathType Leaf
        $reparseTargetPreserved = Test-Path `
            -LiteralPath $reparseTargetSentinel `
            -PathType Leaf
    }
    finally {
        if (Test-Path -LiteralPath $reparseJunction) {
            $junctionAttributes = [System.IO.File]::GetAttributes(
                $reparseJunction)
            if (($junctionAttributes -band
                    [System.IO.FileAttributes]::ReparsePoint) -eq 0) {
                throw "Reparse probe path was unexpectedly replaced."
            }
            [System.IO.Directory]::Delete($reparseJunction, $false)
        }
        if (Test-Path -LiteralPath $reparseProbe) {
            Remove-LiveDemoStateDirectory `
                -StateDirectory $reparseProbe `
                -ArtifactsRoot $artifactsRoot
        }
        if (Test-Path -LiteralPath $reparseTargetSentinel) {
            [System.IO.File]::Delete($reparseTargetSentinel)
        }
        if (Test-Path -LiteralPath $reparseTarget) {
            [System.IO.Directory]::Delete($reparseTarget, $false)
        }
    }
    Add-ContractResult `
        -Name "reparse-point-cleanup-rejected" `
        -Passed (
            $reparseRejected -and
            $reparseOwnedFilePreserved -and
            $reparseTargetPreserved
        ) `
        -Detail (
            "junctionRejected=$reparseRejected; " +
            "ownedFilePreserved=$reparseOwnedFilePreserved; " +
            "externalTargetPreserved=$reparseTargetPreserved")

    $hasFinallyCleanup = $captureText -match '(?m)^finally\s*\{'
    $restoresLocalAppData = $captureText -match (
        '\$env:LOCALAPPDATA\s*=\s*\$previousLocalAppData')
    $finallyRestoresLocalAppData = (
        $hasFinallyCleanup -and $restoresLocalAppData)
    $ownsProcessExit = (
        $captureText -match '\$process\.Kill\(\)' -and
        $captureText -match '\$process\.Dispose\(\)')
    $nonRecursiveCleanup = $captureText -match (
        'Directory\]::Delete\(\$fullPath,\s*\$false\)')
    $planBeforeMutation = (
        $captureText -match (
            '(?s)\$plan\s*=\s*Get-LiveDemoOwnedTreePlan.*?' +
            'The complete tree was validated before this first mutation') -and
        $captureText -match (
            '(?s)Get-LiveDemoOwnedTreePlan.*?' +
            'ReparsePoint.*?' +
            '\$files\.Add\(\$fullPath\)'))
    $noBroadProcessTermination = -not (
        $captureText -match '(?im)\bStop-Process\b|\bGet-Process\b|\btaskkill\b')
    $noStableDeploymentOrPipe = -not (
        $captureText -match '(?i)C:\\RyzenAdj|' +
            'AmdMobilePower\.RustGui\.Worker\.v1|RyzenAdj\.exe')
    $simulatedFixtureOnly = (
        $captureText -match '--ui-fixture' -and
        $captureText -match 'SimulatedData\s*=\s*\$true')
    Add-ContractResult `
        -Name "cleanup-and-isolation" `
        -Passed (
            $finallyRestoresLocalAppData -and
            $ownsProcessExit -and
            $nonRecursiveCleanup -and
            $planBeforeMutation -and
            $noBroadProcessTermination -and
            $noStableDeploymentOrPipe -and
            $simulatedFixtureOnly
        ) `
        -Detail (
            "restoresLocalAppData=$finallyRestoresLocalAppData; " +
            "ownsProcess=$ownsProcessExit; " +
            "nonRecursiveCleanup=$nonRecursiveCleanup; " +
            "planBeforeMutation=$planBeforeMutation; " +
            "noBroadStop=$noBroadProcessTermination; " +
            "noStableDeployment=$noStableDeploymentOrPipe; " +
            "simulatedFixture=$simulatedFixtureOnly")

    $clientOnlyCapture = (
        $captureText -match 'PrintWindow\(\s*\$Window,\s*\$hdc,\s*3\)' -and
        $captureText -match 'PW_CLIENTONLY\s*\|\s*PW_RENDERFULLCONTENT')
    $allClicksResolved = $captureText -match (
        '(?s)foreach\s*\(\$step\s+in\s+\$timeline\).*?' +
        'Get-ControlCenterPoint.*?' +
        '\$step\.ClickX\s*=\s*\$point\.X.*?' +
        '\$step\.ClickY\s*=\s*\$point\.Y')
    Add-ContractResult `
        -Name "capture-coordinate-contract" `
        -Passed ($clientOnlyCapture -and $allClicksResolved) `
        -Detail (
            "clientOnlyPrintWindow=$clientOnlyCapture; " +
            "actualControlCenters=$allClicksResolved")
}
catch {
    Add-ContractResult `
        -Name "contract-execution" `
        -Passed $false `
        -Detail $_.Exception.Message
}

$failures = @($results | Where-Object { -not $_.Passed })
$summary = [ordered]@{
    Verification = if ($failures.Count -eq 0) { "PASS" } else { "FAIL" }
    PowerShellVersion = $PSVersionTable.PSVersion.ToString()
    CaptureScript = $capturePath
    CaptureScriptSha256 = (
        Get-FileHash -LiteralPath $capturePath -Algorithm SHA256
    ).Hash.ToLowerInvariant()
    Checks = @($results)
    Failures = @($failures)
    GuiLaunched = $false
    HardwareWriteAttempted = $false
}
if ($EvidencePath) {
    $resolvedEvidence = Assert-LiveDemoArtifactsPath `
        -Path $EvidencePath `
        -ArtifactsRoot $artifactsRoot
    $evidenceDirectory = Split-Path -Parent $resolvedEvidence
    if ($evidenceDirectory) {
        New-Item -ItemType Directory -Path $evidenceDirectory -Force |
            Out-Null
    }
    [System.IO.File]::WriteAllText(
        $resolvedEvidence,
        ($summary | ConvertTo-Json -Depth 10),
        [System.Text.UTF8Encoding]::new($false))
}
$summary | ConvertTo-Json -Depth 10
if ($failures.Count -gt 0) {
    exit 1
}
