# Worker IPC Protocol

This document describes the current native Rust GUI + C++ worker protocol.
The legacy .NET worker used the same message shape but a different pipe name
and `System.Text.Json`; it is no longer the deployed implementation. When this
document and the source tree differ, the source tree wins.

## Transport

The native worker listens on a message-type named pipe. The effective pipe
depends on who launches the worker:

```text
\\.\pipe\AmdMobilePower.RustGui.Worker.v1   GUI default; the deployed C:\RyzenAdj pipe
\\.\pipe\AmdMobilePower.NativeWorker.v1     worker standalone default (no --pipe-name)
```

The Rust GUI always passes `--pipe-name` to the worker it spawns, so the
deployed tray session uses `AmdMobilePower.RustGui.Worker.v1`. The maintenance
scripts `native/apply-power-policy-direct.ps1` and
`native/restore-day-policy.ps1` default to that same pipe. The headless probe's
raw `--command` mode still defaults to the historical
`\\.\pipe\AmdMobilePower.Worker.v1` for hand-started verifier workers; pass
`--pipe-name AmdMobilePower.RustGui.Worker.v1` to query the deployed worker.

The pipe is created with `FILE_FLAG_FIRST_PIPE_INSTANCE` and an explicit DACL:
the current process user gets `GENERIC_READ | GENERIC_WRITE | SYNCHRONIZE` and
`SYSTEM` keeps `GENERIC_ALL`. The worker refuses to start if the security
descriptor cannot be built; it never falls back to a permissive default DACL.

Both directions use UTF-8 JSON Lines:

- One request is one JSON object followed by `\n`.
- One response is one JSON object followed by `\n`.
- The native worker parses requests with a small bounded JSON extractor;
  unknown fields are ignored.
- Requests carry a unique `requestId`; every response echoes the same
  `requestId` and `protocolVersion: 1`.
- A request is capped at 64 KiB and must arrive within 5 s; the worker bounds
  each response send with a 5 s deadline and cancels synchronous I/O on expiry.

The Rust GUI client opens the pipe with `FILE_FLAG_OVERLAPPED`, bounds each
read/write with a 5 s I/O timeout (cancelling and reaping the overlapped
operation on expiry), rejects any response larger than 1 MiB, and retries a
busy pipe (`ERROR_PIPE_BUSY`) for up to 2 s before failing.

## Request

```json
{
  "protocolVersion": 1,
  "requestId": "a-unique-id",
  "command": "getHealth",
  "payload": null
}
```

## Response

Success:

```json
{
  "protocolVersion": 1,
  "requestId": "a-unique-id",
  "success": true,
  "payload": {
    "status": "ok",
    "protocolVersion": 1,
    "workerVersion": "0.6.0-native",
    "processId": 1234,
    "uptimeSeconds": 4.5,
    "hardwareInitialized": true
  },
  "error": null
}
```

Failure:

```json
{
  "protocolVersion": 1,
  "requestId": "a-unique-id",
  "success": false,
  "payload": null,
  "error": {
    "code": "hardware_writes_disabled",
    "message": "Hardware power-limit writes are disabled for this worker."
  }
}
```

## Commands

The native worker implements exactly the following commands. Any other command
returns `unsupported_command`.

| Command | Status | Hardware access |
|---|---|---|
| `getHealth` | implemented | no |
| `getProfiles` | implemented; returns the complete native profile catalog | no |
| `getCapabilities` | implemented; requires `--enable-hardware` | probe only |
| `getSnapshot` | implemented; requires `--enable-hardware` | read only |
| `applyTarget` | implemented; requires `--enable-hardware` and `--enable-write-controls`; validated with read-back/restore | read/write |
| `getPowerPolicy` | implemented | no |
| `setPowerPolicy` | implemented; requires `--enable-hardware` and `--enable-write-controls` | read/write |
| `shutdown` | implemented; acknowledges before graceful worker exit | no |

Not implemented by the native worker:

- `exportDiagnostics` is **not** a worker command. Diagnostics export is done
  GUI-side (`export_diagnostics` writes a sanitized JSON under
  `%LocalAppData%\AmdMobilePower\diagnostics`), and the headless probe produces
  compatibility reports with `--diagnose`. The legacy .NET worker implemented
  this command; the native worker does not.
- `refreshTelemetry`, `setPresets`, and `restartWorker` are reserved protocol
  names but are not implemented commands.

`applyTarget` and `setPowerPolicy` parse their watt fields with a safe base-10
integer extractor that rejects non-integers and any magnitude outside the
signed 32-bit range, then validate the target against the matched profile and
reported capabilities before any hardware write.

## PowerPolicyState

`getPowerPolicy` and a successful `setPowerPolicy` return the current policy
state as the response payload:

```json
{
  "settings": {
    "enabled": true,
    "batteryEnabled": true,
    "acEnabled": true,
    "batteryTarget": { "stapmWatts": 10, "fastWatts": 10, "slowWatts": 10 },
    "acTarget": { "stapmWatts": 45, "fastWatts": 45, "slowWatts": 45 }
  },
  "lastObservedPowerLine": "ac",
  "lastAttemptPowerLine": "battery",
  "lastAppliedPowerLine": "battery",
  "lastAppliedTarget": { "stapmWatts": 10, "fastWatts": 10, "slowWatts": 10 },
  "lastAttemptAt": "2026-11-18T00:00:00Z",
  "lastAttemptSucceeded": true,
  "lastError": null
}
```

Power-line fields use `"ac"`, `"battery"`, `"unknown"`, or `null`. Target
fields use the same camelCase shape as `applyTarget`, or `null`.

- `lastObservedPowerLine` is the most recent successful observation. It may
  advance without an apply attempt, for example when the newly observed line is
  excluded from the policy.
- `lastAttemptPowerLine` is the line of the latest apply attempt or known-line
  policy failure. An observation failure with no known line leaves it
  unchanged. `lastAppliedPowerLine` is the line of the latest successful apply
  and is retained across later failures.
- Clients must use the attempt or applied line for "last applied" text. They
  must not infer an applied line from `lastObservedPowerLine`.
- Workers released before 1.0.42 omit `lastAttemptPowerLine` and
  `lastAppliedPowerLine`. Clients must treat both as `null` and fall back to a
  line-less result instead of propagating the observed line.

## Development

Run the native worker with an isolated pipe (writes stay disabled unless both
flags are present):

```powershell
.\amdmobilepower_native_worker.exe --pipe-name AmdMobilePower.Dev --enable-hardware
```

Query it with the headless probe:

```powershell
.\amd-mobile-power-probe.exe --pipe-name AmdMobilePower.Dev --command getHealth
```

The C++ worker safety tests (`native/cpp-worker/tests/worker_safety_tests.cpp`)
and the Rust client tests exercise the pipe security descriptor, safe integer
parsing, owner-name detection, telemetry clamp/NaN filtering, and the client
I/O timeout without touching hardware.
