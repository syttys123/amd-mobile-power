$ErrorActionPreference = 'Stop'

# Contract scope: parse verify-release.ps1, assert the release-gate
# catch/finally structure, then execute only those extracted blocks against a
# stub recovery function. This test never starts verify-release.ps1, builds or
# packages, inspects or stops C:\RyzenAdj processes, or writes hardware.

$root = Split-Path -Parent $PSCommandPath
$scriptPath = Join-Path $root 'verify-release.ps1'
$source = Get-Content -LiteralPath $scriptPath -Raw
$failures = New-Object System.Collections.Generic.List[string]

function Assert-Contains([string]$Text, [string]$Needle, [string]$Message) {
    if (-not $Text.Contains($Needle)) {
        $script:failures.Add($Message)
    }
}

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) {
        $script:failures.Add($Message)
    }
}

Assert-Contains $source '$stableGuiSnapshot = @(Get-StableGuiSnapshot)' `
    'verify-release must snapshot the stable GUI before hardware/package work'
Assert-Contains $source 'Stop-TestOwnerProcesses' `
    'test-owned GUI/worker cleanup must run before recovery'
Assert-Contains $source 'Restore-StableGuiAfterReleaseGate' `
    'finally must enter the stable GUI recovery function'
Assert-Contains $source 'try {' `
    'the release body must be exception-guarded'
Assert-Contains $source 'finally {' `
    'the release body must have a finally recovery path'
Assert-Contains $source '-AllowGuiAutoStart' `
    'stable recovery must use the opt-in GUI auto-start helper path'
Assert-Contains $source '-RefreshGui' `
    'stable recovery must use the safe GUI reload path'
Assert-Contains $source '$hour -ge 7 -and $hour -lt 23' `
    'recovery must select the 07:00-23:00 day window'
Assert-Contains $source '{ 25 } else { 10 }' `
    'recovery must select battery 25/10 W by time window'
Assert-Contains $source '{ 45 } else { 10 }' `
    'recovery must select AC 45/10 W by time window'
Assert-Contains $source 'getPowerPolicy' `
    'recovery must probe the worker policy'
Assert-Contains $source 'getSnapshot' `
    'recovery must probe current telemetry limits'
Assert-Contains $source 'stable GUI recovery also failed' `
    'recovery failure must not hide the original verification failure'
Assert-Contains $source 'InitialStableGui' `
    'gate evidence must record the initial stable GUI state'

$hardwarePauseIndex = $source.IndexOf(
    'if ($nativeArguments.VerifyHardware) {')
$stopStableIndex = $source.IndexOf(
    'Stop-StableGui',
    [Math]::Max(0, $hardwarePauseIndex))
$verifyNativeIndex = $source.IndexOf(
    '& (Join-Path $root "verify-native.ps1") @nativeArguments')
Assert-True ($hardwarePauseIndex -ge 0 -and
    $stopStableIndex -gt $hardwarePauseIndex -and
    $verifyNativeIndex -gt $hardwarePauseIndex) `
    'the stable owner pause must precede verify-native'
Assert-Contains $source '$nonPackagedGatePaths = @(' `
    'gate-only script drift must be identified explicitly'
Assert-Contains $source '"native/verify-native.ps1"' `
    'the native verifier must remain outside packaged-binary drift'

# Parse the real wrapper and isolate the top-level release-gate try statement.
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    $scriptPath,
    [ref]$tokens,
    [ref]$parseErrors)
if ($parseErrors.Count -gt 0) {
    $parseErrors | ForEach-Object { Write-Error $_.Message }
    Write-Output 'release-gui-recovery-contract: FAIL'
    exit 1
}

$gateTry = @($ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.TryStatementAst] -and
            $node.CatchClauses.Count -eq 1 -and
            $null -ne $node.Finally -and
            $node.CatchClauses[0].Body.Extent.Text.Contains('$verificationFailure')
        }, $true)) |
    Select-Object -First 1
Assert-True ($null -ne $gateTry) `
    'verify-release must contain one top-level try/catch/finally gate that saves verificationFailure'
if ($null -eq $gateTry) {
    $failures | ForEach-Object { Write-Error $_ }
    Write-Output 'release-gui-recovery-contract: FAIL'
    exit 1
}

$catchBlock = $gateTry.CatchClauses[0].Body
$finallyBlock = $gateTry.Finally
$catchText = $catchBlock.Extent.Text
$finallyText = $finallyBlock.Extent.Text
$catchClauseText = 'catch ' + $catchText
$finallyClauseText = 'finally ' + $finallyText

$savesFailure = @($catchBlock.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $node.Left.VariablePath.UserPath -eq 'verificationFailure' -and
            $node.Right.Extent.Text.Trim() -eq '$_'
        }, $true)).Count -gt 0
Assert-True $savesFailure `
    'catch must save the original failure in $verificationFailure = $_'

$rethrowsOriginal = @($catchBlock.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.ThrowStatementAst] -and
            $node.IsRethrow
        }, $true)).Count -gt 0
Assert-True $rethrowsOriginal `
    'catch must rethrow the original verification failure'

$restoreCallsInFinally = @($finallyBlock.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.CommandAst] -and
            $node.GetCommandName() -eq 'Restore-StableGuiAfterReleaseGate'
        }, $true))
Assert-True ($restoreCallsInFinally.Count -ge 1) `
    'finally must call Restore-StableGuiAfterReleaseGate'

$innerCatches = @($finallyBlock.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.CatchClauseAst]
        }, $true))
Assert-True ($innerCatches.Count -eq 1) `
    'finally must contain exactly one recovery catch block'
if ($innerCatches.Count -ge 1) {
    $recoveryCatchText = $innerCatches[0].Body.Extent.Text
    Assert-True ($recoveryCatchText.Contains('System.InvalidOperationException')) `
        'recovery failure must construct an InvalidOperationException'
    Assert-True ($recoveryCatchText.Contains(
            'Release verification failed: {0}; stable GUI recovery also failed: {1}')) `
        'composite recovery error must name both the verification and recovery failures'
    Assert-True ($recoveryCatchText.Contains('$verificationFailure.Exception.Message')) `
        'composite recovery error must include the original verification failure message'
    Assert-True ($recoveryCatchText.Contains('$recoveryError.Exception.Message')) `
        'composite recovery error must include the recovery failure message'
    Assert-True ($recoveryCatchText.Contains('$verificationFailure.Exception')) `
        'composite recovery error must retain the original failure as the inner exception'
}

Assert-True ($finallyText.Contains('-NotePropertyName "InitialStableGui"')) `
    'finally must append InitialStableGui to gate evidence'
Assert-True ($finallyText.Contains('-NotePropertyName "StableGuiRecovery"')) `
    'finally must append StableGuiRecovery to gate evidence'

# The extracted finally block is executed below, so fail closed if a future
# edit introduces a command that could touch hosts, processes, or hardware.
$allowedFinallyCommands = @(
    'Restore-StableGuiAfterReleaseGate',
    'Write-Output',
    'Test-Path',
    'Get-Content',
    'ConvertFrom-Json',
    'Add-Member',
    'ConvertTo-Json',
    'Set-Content',
    'New-Item',
    'Split-Path',
    'Out-Null',
    'Get-Date'
)
$unexpectedFinallyCommands = @($finallyBlock.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.CommandAst]
        }, $true) |
        ForEach-Object { $_.GetCommandName() } |
        Where-Object { $allowedFinallyCommands -notcontains $_ })
Assert-True ($unexpectedFinallyCommands.Count -eq 0) `
    ("extracted finally block contains unexpected command(s): " +
        ($unexpectedFinallyCommands -join ', '))

if ($unexpectedFinallyCommands.Count -eq 0) {
    $script:restoreCalls = 0
    $script:restoreMode = 'success'
    function Restore-StableGuiAfterReleaseGate {
        $script:restoreCalls++
        if ($script:restoreMode -eq 'throw') {
            throw [System.InvalidOperationException]::new('recovery boom')
        }
        [pscustomobject]@{
            InitialGuiRunning = $true
            InitialGuiPid = 16292
            InitialGuiArguments = '--tray --simple-mode --max-target-watts 45'
            RestoredGuiPid = 16293
            RestoredWorkerPid = 42153
            BatteryWatts = 10
            AcWatts = 10
        }
    }

    function New-GateHarness([string]$BodyExpression) {
        [scriptblock]::Create(@(
                '$verificationFailure = $null'
                '$stableRecoveryResult = $null'
                'try {'
                $BodyExpression
                '}'
                $catchClauseText
                $finallyClauseText
            ) -join "`n")
    }

    $work = Join-Path `
        ([System.IO.Path]::GetTempPath()) `
        ('amd-release-gui-recovery-contract-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    $EvidencePath = Join-Path $work 'evidence.json'

    function Write-BaseEvidence {
        [pscustomobject]@{
            Version = '1.0.33'
            Verification = 'PASS'
        } |
            ConvertTo-Json |
            Set-Content -LiteralPath $EvidencePath -Encoding UTF8
    }

    try {
        # 1. A body failure must still invoke recovery and then preserve the
        #    original verification error.
        Write-BaseEvidence
        $script:restoreCalls = 0
        $script:restoreMode = 'success'
        $failingGate = New-GateHarness `
            "throw [System.InvalidOperationException]::new('verification boom')"
        $observed = $null
        try {
            $null = & $failingGate
        }
        catch {
            $observed = $_
        }
        Assert-True ($script:restoreCalls -eq 1) `
            'body failure must invoke the recovery function exactly once'
        Assert-True ($null -ne $observed) `
            'body failure must propagate an error after recovery'
        if ($null -ne $observed) {
            Assert-True ($observed.Exception.Message -eq 'verification boom') `
                'body failure must remain the reported verification failure'
        }

        # 2. Recovery failure after a body failure must produce a composite
        #    error containing both messages and the original inner exception.
        $script:restoreCalls = 0
        $script:restoreMode = 'throw'
        $observed = $null
        try {
            $null = & $failingGate
        }
        catch {
            $observed = $_
        }
        Assert-True ($script:restoreCalls -eq 1) `
            'recovery failure case must invoke the recovery function'
        Assert-True ($null -ne $observed) `
            'recovery failure must propagate an error'
        if ($null -ne $observed) {
            Assert-True ($observed.Exception -is [System.InvalidOperationException]) `
                'composite failure must surface as InvalidOperationException'
            Assert-True ($observed.Exception.Message.Contains('verification boom')) `
                'composite failure must contain the original verification message'
            Assert-True ($observed.Exception.Message.Contains('recovery boom')) `
                'composite failure must contain the recovery message'
            Assert-True ($null -ne $observed.Exception.InnerException -and
                $observed.Exception.InnerException.Message -eq 'verification boom') `
                'composite failure must keep the original verification exception as InnerException'
        }

        # 3. A successful gate must record the initial stable GUI and the
        #    recovery result in the evidence document.
        Write-BaseEvidence
        $script:restoreCalls = 0
        $script:restoreMode = 'success'
        $successGate = New-GateHarness '$null = 1'
        $null = & $successGate
        $document = Get-Content -LiteralPath $EvidencePath -Raw | ConvertFrom-Json
        Assert-True ($script:restoreCalls -eq 1) `
            'success path must invoke recovery'
        Assert-True ($null -ne $document.InitialStableGui) `
            'success path must record InitialStableGui'
        Assert-True ($document.InitialStableGui.Running -eq $true) `
            'InitialStableGui must preserve the initial running state'
        Assert-True ($document.InitialStableGui.ProcessId -eq 16292) `
            'InitialStableGui must preserve the initial GUI process id'
        Assert-True ($document.InitialStableGui.Arguments -eq
            '--tray --simple-mode --max-target-watts 45') `
            'InitialStableGui must preserve the initial launch arguments'
        Assert-True ($null -ne $document.StableGuiRecovery) `
            'success path must record StableGuiRecovery'
        Assert-True ($document.StableGuiRecovery.RestoredGuiPid -eq 16293) `
            'StableGuiRecovery must record the restored GUI pid'
        Assert-True ($document.StableGuiRecovery.RestoredWorkerPid -eq 42153) `
            'StableGuiRecovery must record the restored worker pid'
        Assert-True ($document.StableGuiRecovery.BatteryWatts -eq 10 -and
            $document.StableGuiRecovery.AcWatts -eq 10) `
            'StableGuiRecovery must record the applied policy targets'

        # 4. A recovery-only failure must surface the recovery error directly,
        #    not as a misleading composite.
        $script:restoreCalls = 0
        $script:restoreMode = 'throw'
        $observed = $null
        try {
            $null = & $successGate
        }
        catch {
            $observed = $_
        }
        Assert-True ($null -ne $observed -and
            $observed.Exception.Message -eq 'recovery boom') `
            'recovery-only failure must surface the recovery error directly'
    }
    finally {
        $resolvedWork = [System.IO.Path]::GetFullPath($work)
        $tempRoot = [System.IO.Path]::GetFullPath(
            [System.IO.Path]::GetTempPath())
        if ($resolvedWork.StartsWith(
                $tempRoot,
                [System.StringComparison]::OrdinalIgnoreCase) -and
            (Test-Path -LiteralPath $resolvedWork)) {
            Remove-Item -LiteralPath $resolvedWork -Recurse -Force
        }
    }
}

if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Error $_ }
    Write-Output 'release-gui-recovery-contract: FAIL'
    exit 1
}
Write-Output 'release-gui-recovery-contract: PASS (AST + extracted finally failure injection; no hardware)'
