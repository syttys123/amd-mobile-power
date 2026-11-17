# Isolated contract tests for the power-policy maintenance scripts.
#
# Safety: these tests NEVER touch the deployed worker pipe, the stable GUI, or
# hardware. They compile a synthetic "fake GUI" (owner-draw toggles + a
# POLICY_SAVE that assembles settings from in-memory flags, mirroring the Rust
# behavior) hosting a fake worker pipe, plus a fake probe, then run the REAL
# apply/restore scripts against those fakes with overridden -PipeName/-GuiPath/
# -StatePath/-LogPath. setPowerPolicy is only ever sent to the fake pipe.
param([string]$EvidencePath)
$ErrorActionPreference = 'Stop'
$native = $PSScriptRoot
. (Join-Path $native 'worker-client.ps1')

$work = Join-Path $env:TEMP ('amd-policy-contract-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
$results = [ordered]@{}
$guiProc = $null

function Add-Result([string]$Name, [bool]$Pass, [string]$Detail) {
    $script:results[$Name] = [ordered]@{ pass = $Pass; detail = $Detail }
    Write-Host ("{0} {1} :: {2}" -f ($(if ($Pass) { 'PASS' } else { 'FAIL' })), $Name, $Detail)
}

$fakeGuiSource = @'
using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;

static class FakeAmdGui
{
    public delegate IntPtr WndProc(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct WNDCLASS
    {
        public uint style; public IntPtr lpfnWndProc; public int cbClsExtra; public int cbWndExtra;
        public IntPtr hInstance; public IntPtr hIcon; public IntPtr hCursor; public IntPtr hbrBackground;
        public string lpszMenuName; public string lpszClassName;
    }
    [StructLayout(LayoutKind.Sequential)]
    public struct MSG { public IntPtr hwnd; public uint message; public IntPtr wParam; public IntPtr lParam; public uint time; public int ptX; public int ptY; }
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern ushort RegisterClassW(ref WNDCLASS lp);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr CreateWindowExW(uint ex, string cls, string name, uint style, int x, int y, int w, int h, IntPtr parent, IntPtr menu, IntPtr inst, IntPtr param);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr DefWindowProcW(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern bool SetWindowTextW(IntPtr hWnd, string text);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr hWnd, StringBuilder text, int maxCount);
    [DllImport("user32.dll")] public static extern IntPtr GetDlgItem(IntPtr hWnd, int id);
    [DllImport("user32.dll")] public static extern bool GetMessage(out MSG m, IntPtr hWnd, uint a, uint b);
    [DllImport("user32.dll")] public static extern bool TranslateMessage(ref MSG m);
    [DllImport("user32.dll")] public static extern IntPtr DispatchMessage(ref MSG m);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr GetModuleHandleW(string name);

    static string _pipe;
    static bool _enabled, _batteryOnly, _writeEnabled;
    static int _saveCount;
    static IntPtr _hwnd;
    static readonly object _sync = new object();
    static Dictionary<string, object> _settings = Uniform(12, 45, false, false);
    static WndProc _proc;

    static Dictionary<string, object> Target(int w)
    {
        return new Dictionary<string, object> { { "stapmWatts", w }, { "fastWatts", w }, { "slowWatts", w } };
    }
    static Dictionary<string, object> Uniform(int b, int a, bool enabled, bool acEnabled)
    {
        return new Dictionary<string, object> {
            { "enabled", enabled }, { "batteryEnabled", true }, { "acEnabled", acEnabled },
            { "batteryTarget", Target(b) }, { "acTarget", Target(a) }
        };
    }

    static void Main(string[] args)
    {
        _pipe = args[0];
        _enabled = args.Length > 1 && args[1] == "1";
        _batteryOnly = args.Length > 2 && args[2] == "1";
        _writeEnabled = args.Length <= 3 || args[3] == "1";
        string ready = args.Length > 4 ? args[4] : null;
        Thread server = new Thread(ServerLoop); server.IsBackground = true; server.Start();
        _proc = Wnd;
        WNDCLASS wc = new WNDCLASS();
        wc.lpfnWndProc = Marshal.GetFunctionPointerForDelegate(_proc);
        wc.hInstance = GetModuleHandleW(null);
        wc.lpszClassName = "FakeAmdGuiClass";
        RegisterClassW(ref wc);
        _hwnd = CreateWindowExW(0, "FakeAmdGuiClass", "FakeAmdGui", 0x00CF0000, -2000, -2000, 320, 240, IntPtr.Zero, IntPtr.Zero, wc.hInstance, IntPtr.Zero);
        uint child = 0x40000000; uint edit = 0x2000; uint ownerdraw = 0x000B;
        CreateWindowExW(0, "EDIT", "12", child | edit, 0, 0, 60, 22, _hwnd, (IntPtr)312, wc.hInstance, IntPtr.Zero);
        CreateWindowExW(0, "EDIT", "45", child | edit, 0, 30, 60, 22, _hwnd, (IntPtr)314, wc.hInstance, IntPtr.Zero);
        CreateWindowExW(0, "BUTTON", "enabled", child | ownerdraw, 0, 60, 90, 22, _hwnd, (IntPtr)315, wc.hInstance, IntPtr.Zero);
        CreateWindowExW(0, "BUTTON", "batteryonly", child | ownerdraw, 0, 90, 90, 22, _hwnd, (IntPtr)318, wc.hInstance, IntPtr.Zero);
        CreateWindowExW(0, "BUTTON", "save", child | ownerdraw, 0, 120, 90, 22, _hwnd, (IntPtr)105, wc.hInstance, IntPtr.Zero);
        if (ready != null) { try { File.WriteAllText(ready, "ready"); } catch { } }
        MSG m;
        while (GetMessage(out m, IntPtr.Zero, 0, 0)) { TranslateMessage(ref m); DispatchMessage(ref m); }
    }

    static IntPtr Wnd(IntPtr h, uint msg, IntPtr w, IntPtr l)
    {
        if (msg == 0x0111)
        {
            int id = (int)((long)w & 0xFFFF);
            int notify = (int)(((long)w >> 16) & 0xFFFF);
            if (notify == 0)
            {
                if (id == 315 && _writeEnabled) { _enabled = !_enabled; }
                else if (id == 318 && _writeEnabled) { _batteryOnly = !_batteryOnly; }
                else if (id == 105 && _writeEnabled) { DoSave(h); }
            }
        }
        return DefWindowProcW(h, msg, w, l);
    }

    static int ReadEdit(IntPtr h, int id, int fallback)
    {
        StringBuilder sb = new StringBuilder(64);
        GetWindowTextW(GetDlgItem(h, id), sb, 64);
        int v;
        if (!int.TryParse(sb.ToString().Trim(), out v)) v = fallback;
        if (v < 5) v = 5; if (v > 60) v = 60;
        return v;
    }

    static void DoSave(IntPtr h)
    {
        int b = ReadEdit(h, 312, 12);
        int a = ReadEdit(h, 314, 45);
        SetWindowTextW(GetDlgItem(h, 312), b.ToString());
        SetWindowTextW(GetDlgItem(h, 314), a.ToString());
        Dictionary<string, object> settings = Uniform(b, a, _enabled, !_batteryOnly);
        try { SendSetPolicy(settings); lock (_sync) { _saveCount++; } } catch { }
    }

    static void SendSetPolicy(Dictionary<string, object> settings)
    {
        using (NamedPipeClientStream client = new NamedPipeClientStream(".", _pipe, PipeDirection.InOut))
        {
            client.Connect(5000);
            JavaScriptSerializer ser = new JavaScriptSerializer();
            string rid = Guid.NewGuid().ToString("N");
            Dictionary<string, object> req = new Dictionary<string, object> {
                { "protocolVersion", 1 }, { "requestId", rid }, { "command", "setPowerPolicy" },
                { "payload", new Dictionary<string, object> { { "settings", settings } } }
            };
            byte[] bytes = Encoding.UTF8.GetBytes(ser.Serialize(req) + "\n");
            client.Write(bytes, 0, bytes.Length);
            client.Flush();
            StreamReader reader = new StreamReader(client, Encoding.UTF8);
            System.Threading.Tasks.Task<string> read = reader.ReadLineAsync();
            if (!read.Wait(8000)) { throw new Exception("fake worker did not answer setPowerPolicy"); }
        }
    }

    static void ServerLoop()
    {
        JavaScriptSerializer ser = new JavaScriptSerializer();
        using (NamedPipeServerStream server = new NamedPipeServerStream(_pipe, PipeDirection.InOut, 1, PipeTransmissionMode.Byte, PipeOptions.Asynchronous))
        {
            while (true)
            {
                server.WaitForConnection();
                try
                {
                    StreamReader reader = new StreamReader(server, Encoding.UTF8);
                    StreamWriter writer = new StreamWriter(server, Encoding.UTF8); writer.AutoFlush = true;
                    string line = reader.ReadLine();
                    if (line != null)
                    {
                        Dictionary<string, object> req = ser.Deserialize<Dictionary<string, object>>(line);
                        string cmd = (string)req["command"];
                        string rid = (string)req["requestId"];
                        object payload = null; bool success = true;
                        lock (_sync)
                        {
                            if (cmd == "getPowerPolicy")
                            {
                                payload = new Dictionary<string, object> {
                                    { "settings", _settings }, { "lastAttemptSucceeded", true },
                                    { "lastAppliedTarget", _settings["batteryTarget"] }, { "lastObservedPowerLine", "battery" }
                                };
                            }
                            else if (cmd == "setPowerPolicy")
                            {
                                Dictionary<string, object> p = (Dictionary<string, object>)req["payload"];
                                _settings = (Dictionary<string, object>)p["settings"];
                            }
                            else if (cmd == "getSnapshot")
                            {
                                Dictionary<string, object> bt = (Dictionary<string, object>)_settings["batteryTarget"];
                                payload = new Dictionary<string, object> {
                                    { "telemetry", new Dictionary<string, object> {
                                        { "powerLine", "battery" }, { "fastLimitWatts", bt["fastWatts"] },
                                        { "slowLimitWatts", bt["slowWatts"] }, { "stapmLimitWatts", bt["stapmWatts"] } } }
                                };
                            }
                            else if (cmd == "getGuiState")
                            {
                                payload = new Dictionary<string, object> {
                                    { "enabled", _enabled }, { "batteryOnly", _batteryOnly }, { "saveCount", _saveCount }
                                };
                            }
                            else { success = false; }
                        }
                        Dictionary<string, object> resp = new Dictionary<string, object> {
                            { "protocolVersion", 1 }, { "requestId", rid }, { "success", success },
                            { "payload", payload }, { "error", null }
                        };
                        writer.WriteLine(ser.Serialize(resp));
                    }
                }
                catch { }
                finally { try { server.Disconnect(); } catch { } }
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
static class FakeAmdProbe
{
    static int Main(string[] args)
    {
        string pipe = null; string cmd = "getPowerPolicy";
        for (int i = 0; i < args.Length; i++)
        {
            if (args[i] == "--pipe-name" && i + 1 < args.Length) pipe = args[i + 1];
            if (args[i] == "--command" && i + 1 < args.Length) cmd = args[i + 1];
        }
        try
        {
            using (NamedPipeClientStream client = new NamedPipeClientStream(".", pipe, PipeDirection.InOut))
            {
                client.Connect(4000);
                JavaScriptSerializer ser = new JavaScriptSerializer();
                string rid = Guid.NewGuid().ToString("N");
                Dictionary<string, object> req = new Dictionary<string, object> {
                    { "protocolVersion", 1 }, { "requestId", rid }, { "command", cmd }, { "payload", null }
                };
                byte[] bytes = Encoding.UTF8.GetBytes(ser.Serialize(req) + "\n");
                client.Write(bytes, 0, bytes.Length);
                StreamReader reader = new StreamReader(client, Encoding.UTF8);
                Dictionary<string, object> resp = ser.Deserialize<Dictionary<string, object>>(reader.ReadLine());
                if (!(bool)resp["success"]) { Console.Error.WriteLine("worker error"); return 1; }
                Console.WriteLine(ser.Serialize(resp["payload"]));
                return 0;
            }
        }
        catch (Exception e) { Console.Error.WriteLine(e.Message); return 1; }
    }
}
'@

function Wait-Ready([string]$File, [int]$TimeoutMs) {
    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $File) { return $true }
        Start-Sleep -Milliseconds 100
    }
    return $false
}
function Invoke-FakeCommand([string]$Pipe, [string]$Command) {
    $r = Invoke-WorkerPipeRequest -PipeName $Pipe -Command $Command -ConnectTimeoutMilliseconds 4000 -ReadTimeoutMilliseconds 8000
    if (-not $r.Success) { throw "fake $Command failed: $($r.ErrorText)" }
    return $r.Payload
}
function Start-FakeGui([string]$Exe, [string]$Pipe, [bool]$Enabled, [bool]$BatteryOnly, [bool]$Write, [string]$Ready) {
    $argList = @($Pipe, $(if ($Enabled) { '1' } else { '0' }), $(if ($BatteryOnly) { '1' } else { '0' }), $(if ($Write) { '1' } else { '0' }), $Ready)
    return Start-Process -FilePath $Exe -ArgumentList $argList -WindowStyle Hidden -PassThru
}
function Stop-FakeGui($Proc) {
    if ($Proc) {
        try { if (-not $Proc.HasExited) { $Proc.Kill() | Out-Null; $Proc.WaitForExit(5000) | Out-Null } } catch { }
        try { $Proc.Dispose() } catch { }
    }
}
function Invoke-ScriptChild([string]$Script, [hashtable]$Params) {
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Script)
    foreach ($key in $Params.Keys) { $argList += @("-$key", [string]$Params[$key]) }
    $out = Join-Path $work ('child-' + [guid]::NewGuid().ToString('N') + '.txt')
    $p = Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput $out -RedirectStandardError ($out + '.err')
    if (-not $p.WaitForExit(60000)) {
        try { $p.Kill() | Out-Null } catch { }
        $p.WaitForExit() | Out-Null
    }
    $code = $p.ExitCode
    $text = ''
    if (Test-Path -LiteralPath $out) { $text = (Get-Content -LiteralPath $out -Raw) }
    $p.Dispose()
    return [pscustomobject]@{ ExitCode = $code; Output = $text }
}

try {
    $guiExe = Join-Path $work 'fake-gui.exe'
    $probeExe = Join-Path $work 'fake-probe.exe'
    Add-Type -TypeDefinition $fakeGuiSource -OutputAssembly $guiExe -OutputType ConsoleApplication -ReferencedAssemblies 'System.Web.Extensions'
    Add-Type -TypeDefinition $fakeProbeSource -OutputAssembly $probeExe -OutputType ConsoleApplication -ReferencedAssemblies 'System.Web.Extensions'
    Add-Result 'compile-fakes' $true 'fake GUI + probe compiled'

    $applyScript = Join-Path $native 'apply-power-policy-direct.ps1'
    $restoreScript = Join-Path $native 'restore-day-policy.ps1'

    # Test A: apply converges a STALE GUI (enabled=false, batteryOnly=true).
    $pipeA = 'amdContractA.' + [guid]::NewGuid().ToString('N')
    $readyA = Join-Path $work 'readyA.txt'
    $stateA = Join-Path $work 'stateA.json'
    $logA = Join-Path $work 'applyA.log'
    $guiProc = Start-FakeGui $guiExe $pipeA $false $true $true $readyA
    if (-not (Wait-Ready $readyA 10000)) { throw 'fake GUI A not ready' }
    $runA = Invoke-ScriptChild $applyScript @{ BatteryWatts = 10; AcWatts = 45; PipeName = $pipeA; GuiPath = $guiExe; StatePath = $stateA; LogPath = $logA }
    $polA = (Invoke-FakeCommand $pipeA 'getPowerPolicy').settings
    $guiA = Invoke-FakeCommand $pipeA 'getGuiState'
    $stateObjA = Get-Content -LiteralPath $stateA -Raw | ConvertFrom-Json
    $passA = ($runA.ExitCode -eq 0) -and $polA.enabled -and $polA.acEnabled -and
        ($polA.batteryTarget.stapmWatts -eq 10) -and ($polA.acTarget.stapmWatts -eq 45) -and
        $guiA.enabled -and (-not $guiA.batteryOnly) -and ($stateObjA.powerPolicy.enabled -eq $true)
    Add-Result 'apply-stale-gui-converges' $passA ("exit={0} enabled={1} acEnabled={2} saveCount={3} stateEnabled={4}" -f $runA.ExitCode, $polA.enabled, $polA.acEnabled, $guiA.saveCount, $stateObjA.powerPolicy.enabled)
    Stop-FakeGui $guiProc; $guiProc = $null

    # Test B: apply with an ALREADY-CORRECT GUI must not toggle unnecessarily.
    $pipeB = 'amdContractB.' + [guid]::NewGuid().ToString('N')
    $readyB = Join-Path $work 'readyB.txt'
    $stateB = Join-Path $work 'stateB.json'
    $logB = Join-Path $work 'applyB.log'
    $guiProc = Start-FakeGui $guiExe $pipeB $true $false $true $readyB
    if (-not (Wait-Ready $readyB 10000)) { throw 'fake GUI B not ready' }
    $runB = Invoke-ScriptChild $applyScript @{ BatteryWatts = 8; AcWatts = 8; PipeName = $pipeB; GuiPath = $guiExe; StatePath = $stateB; LogPath = $logB }
    $polB = (Invoke-FakeCommand $pipeB 'getPowerPolicy').settings
    $guiB = Invoke-FakeCommand $pipeB 'getGuiState'
    $passB = ($runB.ExitCode -eq 0) -and $polB.enabled -and $polB.acEnabled -and
        ($polB.batteryTarget.stapmWatts -eq 8) -and ($polB.acTarget.stapmWatts -eq 8) -and ($guiB.saveCount -eq 1)
    Add-Result 'apply-correct-gui-single-save' $passB ("exit={0} saveCount={1} battery={2} ac={3}" -f $runB.ExitCode, $guiB.saveCount, $polB.batteryTarget.stapmWatts, $polB.acTarget.stapmWatts)
    Stop-FakeGui $guiProc; $guiProc = $null

    # Test C: apply with NO GUI still sets + verifies the worker policy.
    $pipeC = 'amdContractC.' + [guid]::NewGuid().ToString('N')
    $readyC = Join-Path $work 'readyC.txt'
    $stateC = Join-Path $work 'stateC.json'
    $logC = Join-Path $work 'applyC.log'
    $guiProc = Start-FakeGui $guiExe $pipeC $false $true $true $readyC
    if (-not (Wait-Ready $readyC 10000)) { throw 'fake GUI C not ready' }
    $bogusGui = Join-Path $work 'does-not-exist.exe'
    $runC = Invoke-ScriptChild $applyScript @{ BatteryWatts = 12; AcWatts = 45; PipeName = $pipeC; GuiPath = $bogusGui; StatePath = $stateC; LogPath = $logC }
    $polC = (Invoke-FakeCommand $pipeC 'getPowerPolicy').settings
    $logCText = Get-Content -LiteralPath $logC -Raw
    $passC = ($runC.ExitCode -eq 0) -and $polC.enabled -and ($polC.batteryTarget.stapmWatts -eq 12) -and ($logCText -match 'guiSynced=False')
    Add-Result 'apply-no-gui-verified' $passC ("exit={0} enabled={1} guiSyncedFalse={2}" -f $runC.ExitCode, $polC.enabled, ($logCText -match 'guiSynced=False'))
    Stop-FakeGui $guiProc; $guiProc = $null

    # Test D: parameter range validation rejects out-of-range watts at binding.
    $bindingOk = $true; $bindingDetail = @()
    foreach ($script in @($applyScript, $restoreScript)) {
        foreach ($bad in @(4, 61)) {
            $rejected = $false
            try { & $script -BatteryWatts $bad -AcWatts 45 -LogPath (Join-Path $work 'noop.log') }
            catch { $rejected = $true }
            if (-not $rejected) { $bindingOk = $false }
            $bindingDetail += ("{0}:{1}={2}" -f (Split-Path $script -Leaf), $bad, $rejected)
        }
    }
    Add-Result 'param-range-validation' $bindingOk ($bindingDetail -join '; ')

    # Test E: restore converges a STALE GUI via the GUI-driven path + fake probe.
    $pipeE = 'amdContractE.' + [guid]::NewGuid().ToString('N')
    $readyE = Join-Path $work 'readyE.txt'
    $logE = Join-Path $work 'restoreE.log'
    $guiProc = Start-FakeGui $guiExe $pipeE $false $true $true $readyE
    if (-not (Wait-Ready $readyE 10000)) { throw 'fake GUI E not ready' }
    $runE = Invoke-ScriptChild $restoreScript @{ BatteryWatts = 10; AcWatts = 45; GuiPath = $guiExe; ProbePath = $probeExe; PipeName = $pipeE; LogPath = $logE }
    $polE = (Invoke-FakeCommand $pipeE 'getPowerPolicy').settings
    $guiE = Invoke-FakeCommand $pipeE 'getGuiState'
    $passE = ($runE.ExitCode -eq 0) -and $polE.enabled -and $polE.acEnabled -and
        ($polE.batteryTarget.stapmWatts -eq 10) -and ($polE.acTarget.stapmWatts -eq 45) -and $guiE.enabled
    Add-Result 'restore-stale-gui-converges' $passE ("exit={0} enabled={1} acEnabled={2} saveCount={3}" -f $runE.ExitCode, $polE.enabled, $polE.acEnabled, $guiE.saveCount)
    Stop-FakeGui $guiProc; $guiProc = $null

    # Test F: concurrent state read-modify-write under the named mutex stays valid.
    $pipeF = 'amdContractF.' + [guid]::NewGuid().ToString('N')
    $readyF = Join-Path $work 'readyF.txt'
    $stateF = Join-Path $work 'stateF.json'
    $guiProc = Start-FakeGui $guiExe $pipeF $true $false $true $readyF
    if (-not (Wait-Ready $readyF 10000)) { throw 'fake GUI F not ready' }
    $bogusGuiF = Join-Path $work 'absent.exe'
    $argCommon = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $applyScript, '-BatteryWatts', '10', '-AcWatts', '45', '-PipeName', $pipeF, '-GuiPath', $bogusGuiF, '-StatePath', $stateF)
    $p1 = Start-Process -FilePath 'powershell.exe' -ArgumentList ($argCommon + @('-LogPath', (Join-Path $work 'f1.log'))) -WindowStyle Hidden -PassThru
    $p2 = Start-Process -FilePath 'powershell.exe' -ArgumentList ($argCommon + @('-LogPath', (Join-Path $work 'f2.log'))) -WindowStyle Hidden -PassThru
    $p1.WaitForExit(); $p2.WaitForExit()
    $stateValid = $false; $stateEnabled = $false
    try {
        $stateFobj = Get-Content -LiteralPath $stateF -Raw | ConvertFrom-Json
        $stateValid = $true
        $stateEnabled = ($stateFobj.powerPolicy.enabled -eq $true) -and ($stateFobj.powerPolicy.batteryTarget.stapmWatts -eq 10)
    } catch { }
    $passF = ($p1.ExitCode -eq 0) -and ($p2.ExitCode -eq 0) -and $stateValid -and $stateEnabled
    Add-Result 'mutex-concurrent-state' $passF ("exit1={0} exit2={1} validJson={2} enabled={3}" -f $p1.ExitCode, $p2.ExitCode, $stateValid, $stateEnabled)
    $p1.Dispose(); $p2.Dispose()
    Stop-FakeGui $guiProc; $guiProc = $null
}
catch {
    Add-Result 'harness-error' $false $_.Exception.Message
}
finally {
    Stop-FakeGui $guiProc
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
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
if ($EvidencePath) { $record | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $EvidencePath -Encoding UTF8 }
$record | ConvertTo-Json -Depth 8
if ($failed.Count -gt 0) { exit 1 }
