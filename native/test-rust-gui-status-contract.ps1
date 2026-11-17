$ErrorActionPreference = 'Stop'

# This contract extracts only the read-only worker-status predicate from the
# real GUI verifier. It never launches a GUI/worker or touches hardware.
$root = Split-Path -Parent $PSCommandPath
$scriptPath = Join-Path $root 'verify-rust-gui.ps1'
$source = [System.IO.File]::ReadAllText(
    $scriptPath,
    [System.Text.Encoding]::UTF8)
$failures = New-Object System.Collections.Generic.List[string]

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) {
        $script:failures.Add($Message)
    }
}

$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    $scriptPath,
    [ref]$tokens,
    [ref]$parseErrors)
Assert-True ($parseErrors.Count -eq 0) 'GUI verifier must parse successfully'

$statusIf = @($ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.IfStatementAst] -and
            $node.Clauses.Count -eq 1 -and
            $node.Clauses[0].Item1.Extent.Text.Contains('$workerStatus') -and
            $node.Clauses[0].Item2.Extent.Text.Contains(
                'Rust GUI worker status is incomplete')
        }, $true)) | Select-Object -First 1
Assert-True ($null -ne $statusIf) 'worker-status completeness check must exist'

if ($null -ne $statusIf) {
    Assert-True ($statusIf.Clauses.Count -eq 1) `
        'worker-status check must have one condition clause'
    $conditionAst = $statusIf.Clauses[0].Item1
    $predicate = $conditionAst.Extent.Text
    Assert-True ($predicate.Contains('最近写入目标：')) `
        'status check must require the explicit recent-write label'
    Assert-True (-not $predicate.Contains('"目标功耗："')) `
        'status check must not require the obsolete ambiguous target label'
    Assert-True ($predicate.Contains('已连接 worker ·')) `
        'status check must require a connected worker'
    Assert-True ($predicate.Contains('STAPM / Fast / Slow 上限')) `
        'status check must require all three limit headings'

    $commands = @($conditionAst.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.CommandAst]
            }, $true))
    Assert-True ($commands.Count -eq 0) `
        'extracted status predicate must not execute commands'

    if ($commands.Count -eq 0) {
        $check = [scriptblock]::Create(
            "param([string]`$workerStatus)`nif ($predicate) { `$false } else { `$true }")
        $current = @(
            '已连接 worker · 外接电源',
            'AMD Ryzen 7 8845HS w/ Radeon 780M Graphics',
            'STAPM / Fast / Slow 上限',
            '15.00 W / 15.00 W / 15.00 W',
            '最近写入目标：--    CPU：55.3 °C',
            '自动策略：未配置'
        ) -join "`n"
        $configured = $current.Replace(
            '最近写入目标：--',
            '最近写入目标：15.00 W').Replace(
            '自动策略：未配置',
            '自动策略：已启用（电池 15 W / 外接 15 W）')
        Assert-True (& $check $current) `
            'a connected read-only worker with no saved policy is a complete status'
        Assert-True (& $check $configured) `
            'a configured policy remains a complete status'
        Assert-True (-not (& $check $current.Replace('最近写入目标：', '目标功耗：'))) `
            'the obsolete label must fail the current contract'
        Assert-True (-not (& $check $current.Replace('已连接 worker ·', '等待 worker ·'))) `
            'a disconnected worker must fail'
        Assert-True (-not (& $check $current.Replace('STAPM / Fast / Slow 上限', '部分上限'))) `
            'missing limit headings must fail'
    }
}

if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Error $_ }
    Write-Output 'rust-gui-status-contract: FAIL'
    exit 1
}

Write-Output 'rust-gui-status-contract: PASS (7 checks; no GUI, worker, or hardware)'
