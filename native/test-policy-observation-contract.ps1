# Isolated fake-worker contract for the native power-policy verifier.
#
# The real verifier is run with explicit fixture paths. The fake worker uses
# only an isolated named pipe and never loads RyzenAdj or touches hardware.
param([switch]$PreserveWork)
$ErrorActionPreference = 'Stop'
$native = $PSScriptRoot
$work = Join-Path $env:TEMP ('amd-policy-observation-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
$results = [ordered]@{}

function Add-Result([string]$Name, [bool]$Pass, [string]$Detail) {
    $script:results[$Name] = [ordered]@{ pass = $Pass; detail = $Detail }
    Write-Host ("{0} {1} :: {2}" -f ($(if ($Pass) { 'PASS' } else { 'FAIL' })), $Name, $Detail)
}

$fakeWorkerSource = @'
using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Pipes;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;

static class FakePolicyWorker
{
    static string _pipe;
    static string _mode;
    static string _observed = "battery";
    static string _attemptLine;
    static string _appliedLine;
    static DateTime? _attemptAt;
    static bool? _attemptSucceeded;
    static Dictionary<string, object> _appliedTarget;
    static Dictionary<string, object> _settings = Uniform(12, 45, true);
    static DateTime _convergeAt = DateTime.MinValue;
    static bool _convergePending;
    static bool _shutdown;
    static readonly object _sync = new object();

    static Dictionary<string, object> Target(int watts)
    {
        return new Dictionary<string, object> {
            { "stapmWatts", watts }, { "fastWatts", watts }, { "slowWatts", watts }
        };
    }

    static Dictionary<string, object> Uniform(int battery, int ac, bool enabled)
    {
        return new Dictionary<string, object> {
            { "enabled", enabled }, { "batteryEnabled", true }, { "acEnabled", true },
            { "batteryTarget", Target(battery) }, { "acTarget", Target(ac) }
        };
    }

    static Dictionary<string, object> TargetForLine()
    {
        return _observed == "ac"
            ? (Dictionary<string, object>)_settings["acTarget"]
            : (Dictionary<string, object>)_settings["batteryTarget"];
    }

    static int Main(string[] args)
    {
        for (int i = 0; i < args.Length; i++)
        {
            if (args[i] == "--pipe-name" && i + 1 < args.Length) { _pipe = args[i + 1]; }
        }
        if (_pipe != null && _pipe.StartsWith(@"\\.\pipe\"))
        {
            _pipe = _pipe.Substring(@"\\.\pipe\".Length);
        }
        _mode = Environment.GetEnvironmentVariable("AMD_POLICY_FAKE_MODE");
        if (String.IsNullOrEmpty(_mode)) { _mode = "new"; }

        if (_mode == "observation")
        {
            _observed = "ac";
            _attemptLine = "battery";
            _appliedLine = "battery";
            _attemptAt = DateTime.UtcNow.AddMinutes(-1);
            _attemptSucceeded = true;
            _appliedTarget = Target(45);
        }
        else if (_mode == "switch")
        {
            _observed = "ac";
            _attemptLine = "battery";
            _appliedLine = "battery";
            _attemptAt = DateTime.UtcNow.AddMinutes(-1);
            _attemptSucceeded = true;
            _appliedTarget = Target(45);
        }

        Thread server = new Thread(ServerLoop);
        server.IsBackground = true;
        server.Start();
        while (!_shutdown)
        {
            Thread.Sleep(50);
        }
        server.Join(3000);
        return 0;
    }

    static void RecordAttempt(bool success)
    {
        _attemptLine = _observed;
        _attemptAt = DateTime.UtcNow;
        _attemptSucceeded = success;
        if (success)
        {
            _appliedLine = _observed;
            _appliedTarget = TargetForLine();
        }
    }

    static void AdvanceScenario()
    {
        if (_convergePending && DateTime.UtcNow >= _convergeAt)
        {
            _convergePending = false;
            RecordAttempt(true);
        }
    }

    static Dictionary<string, object> PolicyPayload()
    {
        Dictionary<string, object> policy = new Dictionary<string, object> {
            { "settings", _settings },
            { "lastObservedPowerLine", _observed },
            { "lastAttemptSucceeded", _attemptSucceeded },
            { "lastAttemptAt", _attemptAt.HasValue ? _attemptAt.Value.ToString("o") : null }
        };
        if (_mode != "missingTarget")
        {
            policy["lastAppliedTarget"] = _appliedTarget;
        }
        if (_mode != "legacy")
        {
            policy["lastAttemptPowerLine"] = _attemptLine;
            policy["lastAppliedPowerLine"] = _appliedLine;
        }
        return policy;
    }

    static Dictionary<string, object> Dispatch(string command, Dictionary<string, object> payload)
    {
        lock (_sync)
        {
            AdvanceScenario();
            if (command == "getHealth")
            {
                return new Dictionary<string, object> {
                    { "status", "ok" },
                    { "workerVersion", "fake-policy-observation" },
                    { "processId", System.Diagnostics.Process.GetCurrentProcess().Id },
                    { "uptimeSeconds", 1.0 },
                    { "hardwareEnabled", true }
                };
            }
            if (command == "getPowerPolicy") { return PolicyPayload(); }
            if (command == "getSnapshot")
            {
                Dictionary<string, object> target = TargetForLine();
                return new Dictionary<string, object> {
                    { "telemetry", new Dictionary<string, object> {
                        { "powerLine", _observed },
                        { "stapmLimitWatts", target["stapmWatts"] },
                        { "fastLimitWatts", target["fastWatts"] },
                        { "slowLimitWatts", target["slowWatts"] }
                    } },
                    { "platform", new Dictionary<string, object> {
                        { "cpu", new Dictionary<string, object> {
                            { "processorName", "Fake Policy CPU" }
                        } }
                    } }
                };
            }
            if (command == "setPowerPolicy")
            {
                _settings = (Dictionary<string, object>)payload["settings"];
                if (_mode == "observation")
                {
                    _observed = "ac";
                }
                else if (_mode == "switch")
                {
                    _convergePending = true;
                    _convergeAt = DateTime.UtcNow.AddMilliseconds(800);
                }
                else
                {
                    RecordAttempt(_mode != "fail");
                }
                return PolicyPayload();
            }
            if (command == "shutdown")
            {
                _shutdown = true;
                return new Dictionary<string, object> { { "accepted", true } };
            }
            throw new InvalidOperationException("unsupported command " + command);
        }
    }

    static void ServerLoop()
    {
        JavaScriptSerializer serializer = new JavaScriptSerializer();
        using (NamedPipeServerStream server = new NamedPipeServerStream(
            _pipe, PipeDirection.InOut, 1, PipeTransmissionMode.Message, PipeOptions.Asynchronous))
        {
            while (!_shutdown)
            {
                server.WaitForConnection();
                try
                {
                    byte[] buffer = new byte[16384];
                    System.IO.MemoryStream requestBytes = new System.IO.MemoryStream();
                    while (true)
                    {
                        int length = server.Read(buffer, 0, buffer.Length);
                        if (length <= 0) { break; }
                        requestBytes.Write(buffer, 0, length);
                        bool hasNewline = false;
                        for (int i = 0; i < length; i++)
                        {
                            if (buffer[i] == (byte)'\n') { hasNewline = true; break; }
                        }
                        if (hasNewline) { break; }
                    }
                    string line = requestBytes.Length == 0
                        ? null
                        : Encoding.UTF8.GetString(requestBytes.ToArray()).TrimEnd('\r', '\n');
                    if (line != null)
                    {
                        Dictionary<string, object> request =
                            serializer.Deserialize<Dictionary<string, object>>(line);
                        string requestId = (string)request["requestId"];
                        string command = (string)request["command"];
                        object payload = null;
                        try
                        {
                            payload = Dispatch(
                                command,
                                request["payload"] as Dictionary<string, object>);
                        }
                        catch (Exception error)
                        {
                            Dictionary<string, object> responseError = new Dictionary<string, object> {
                                { "protocolVersion", 1 },
                                { "requestId", requestId },
                                { "success", false },
                                { "payload", null },
                                { "error", new Dictionary<string, object> {
                                    { "code", "fixture_error" },
                                    { "message", error.Message }
                                } }
                            };
                            byte[] errorBytes = Encoding.UTF8.GetBytes(
                                serializer.Serialize(responseError) + "\n");
                            server.Write(errorBytes, 0, errorBytes.Length);
                            server.Flush();
                            continue;
                        }
                        Dictionary<string, object> response = new Dictionary<string, object> {
                            { "protocolVersion", 1 },
                            { "requestId", requestId },
                            { "success", true },
                            { "payload", payload },
                            { "error", null }
                        };
                        byte[] responseBytes = Encoding.UTF8.GetBytes(
                            serializer.Serialize(response) + "\n");
                        server.Write(responseBytes, 0, responseBytes.Length);
                        server.Flush();
                    }
                }
                finally
                {
                    try { server.Disconnect(); } catch { }
                }
            }
        }
    }
}
'@

$fakeProbeSource = @'
using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Pipes;
using System.Text;
using System.Web.Script.Serialization;

static class FakePolicyProbe
{
    static int Main(string[] args)
    {
        string pipe = null;
        string command = null;
        for (int i = 0; i < args.Length; i++)
        {
            if (args[i] == "--pipe-name" && i + 1 < args.Length) { pipe = args[i + 1]; }
            if (args[i] == "--command" && i + 1 < args.Length) { command = args[i + 1]; }
        }
        if (pipe != null && pipe.StartsWith(@"\\.\pipe\"))
        {
            pipe = pipe.Substring(@"\\.\pipe\".Length);
        }
        try
        {
            using (NamedPipeClientStream client = new NamedPipeClientStream(
                ".", pipe, PipeDirection.InOut, PipeOptions.Asynchronous))
            {
                client.Connect(4000);
                JavaScriptSerializer serializer = new JavaScriptSerializer();
                string requestId = Guid.NewGuid().ToString("N");
                Dictionary<string, object> request = new Dictionary<string, object> {
                    { "protocolVersion", 1 },
                    { "requestId", requestId },
                    { "command", command },
                    { "payload", null }
                };
                byte[] bytes = Encoding.UTF8.GetBytes(serializer.Serialize(request) + "\n");
                var write = client.WriteAsync(bytes, 0, bytes.Length);
                if (!write.Wait(8000)) { return 1; }
                var flush = client.FlushAsync();
                if (!flush.Wait(8000)) { return 1; }
                StreamReader reader = new StreamReader(client, Encoding.UTF8);
                var read = reader.ReadLineAsync();
                if (!read.Wait(8000) || read.Result == null) { return 1; }
                Dictionary<string, object> response =
                    serializer.Deserialize<Dictionary<string, object>>(read.Result);
                if (!(bool)response["success"]) { return 1; }
                Console.WriteLine(serializer.Serialize(response["payload"]));
                return 0;
            }
        }
        catch
        {
            return 1;
        }
    }
}
'@

function Invoke-VerifierFixture([string]$Mode, [string]$ProbeExecutable) {
    $pipe = 'amdObservation.' + [guid]::NewGuid().ToString('N')
    $argList = @(
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        (Join-Path $native 'verify-power-policy.ps1'),
        '-NoBuild',
        '-ExecuteNoChangePolicy',
        '-WorkerPath',
        (Join-Path $work 'fake-policy-worker.exe'),
        '-ProbePath',
        $ProbeExecutable)
    $previousMode = $env:AMD_POLICY_FAKE_MODE
    try {
        $env:AMD_POLICY_FAKE_MODE = $Mode
        $process = Start-Process `
            -FilePath 'powershell.exe' `
            -ArgumentList $argList `
            -WindowStyle Hidden `
            -PassThru
        $deadline = (Get-Date).AddSeconds(60)
        while (-not $process.HasExited -and (Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 100
            $process.Refresh()
        }
        if (-not $process.HasExited) {
            try { $process.Kill() | Out-Null } catch { }
            $process.WaitForExit() | Out-Null
        }
        $process.Refresh()
        $code = $process.ExitCode
        $process.Dispose()
        return $code
    }
    finally {
        if ($null -eq $previousMode) {
            Remove-Item Env:\AMD_POLICY_FAKE_MODE -ErrorAction SilentlyContinue
        }
        else {
            $env:AMD_POLICY_FAKE_MODE = $previousMode
        }
    }
}

try {
    $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    if (-not (Test-Path -LiteralPath $csc -PathType Leaf)) {
        throw "csc.exe is missing: $csc"
    }
    $workerSource = Join-Path $work 'fake-policy-worker.cs'
    $probeSource = Join-Path $work 'fake-policy-probe.cs'
    $workerExe = Join-Path $work 'fake-policy-worker.exe'
    $probeExe = Join-Path $work 'fake-policy-probe.exe'
    [IO.File]::WriteAllText($workerSource, $fakeWorkerSource, [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($probeSource, $fakeProbeSource, [Text.UTF8Encoding]::new($false))
    & $csc /nologo /target:exe /r:System.Web.Extensions.dll "/out:$workerExe" $workerSource
    if ($LASTEXITCODE -ne 0) { throw "fake worker compilation failed: $LASTEXITCODE" }
    & $csc /nologo /target:exe /r:System.Web.Extensions.dll "/out:$probeExe" $probeSource
    if ($LASTEXITCODE -ne 0) { throw "fake probe compilation failed: $LASTEXITCODE" }
    Add-Result 'compile-fakes' $true 'fake policy worker + probe compiled'

    $realProbe = Join-Path $native 'rust-probe\target\release\amd-mobile-power-probe.exe'
    $switchProbe = if (Test-Path -LiteralPath $realProbe -PathType Leaf) {
        $realProbe
    }
    else {
        $probeExe
    }
    $switchProbeKind = if ($switchProbe -eq $realProbe) { 'real' } else { 'fake' }
    $switchExit = Invoke-VerifierFixture 'switch' $switchProbe
    Add-Result 'verify-new-fields-line-switch' ($switchExit -eq 0) "exit=$switchExit probe=$switchProbeKind"

    $legacyExit = Invoke-VerifierFixture 'legacy' $probeExe
    Add-Result 'verify-legacy-observed-fallback' ($legacyExit -eq 0) "exit=$legacyExit"

    $observationExit = Invoke-VerifierFixture 'observation' $probeExe
    Add-Result 'verify-observation-not-applied' ($observationExit -ne 0) "exit=$observationExit"

    $failExit = Invoke-VerifierFixture 'fail' $probeExe
    Add-Result 'verify-failed-attempt-rejected' ($failExit -ne 0) "exit=$failExit"

    $missingTargetExit = Invoke-VerifierFixture 'missingTarget' $probeExe
    Add-Result 'verify-missing-target-rejected' ($missingTargetExit -ne 0) "exit=$missingTargetExit"
}
catch {
    Add-Result 'harness-error' $false $_.Exception.Message
}
finally {
    if (-not $PreserveWork -and (Test-Path -LiteralPath $work)) {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$failed = @($results.Keys | Where-Object { -not $results[$_].pass })
$record = [ordered]@{
    Verification = $(if ($failed.Count -eq 0) { 'PASS' } else { 'FAIL' })
    HardwareEnabled = $false
    RealWorkerContacted = $false
    Checks = $results
    Failed = $failed
    RecordedAt = (Get-Date).ToString('o')
}
if ($PreserveWork) { Write-Host "work=$work" }
$record | ConvertTo-Json -Depth 8
if ($failed.Count -gt 0) { exit 1 }
