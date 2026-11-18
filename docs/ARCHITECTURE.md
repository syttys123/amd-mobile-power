# Architecture

This document separates the current implementation from the longer-term target.
`DEV_STATUS.md` and the source tree remain authoritative when behavior differs.

The current implementation is the native line: a Rust GUI
(`amd-mobile-power-gui.exe`) and a separate C++ worker
(`amdmobilepower_native_worker.exe`). The earlier .NET WinForms GUI / worker /
Core stack is legacy and is no longer deployed. The deployed `C:\RyzenAdj`
package is `1.0.42` (source `927a1bb`); it includes the safety remediation,
limits-aware drift repair, and explicit policy-line semantics described below. Its full gate and deployment passed
on 2026-11-18. See `NATIVE_RC_STATUS.md` for the exact evidence set.

## Processes

### Rust GUI (amd-mobile-power-gui.exe)

- Runs at the current user's privilege level.
- Owns the main window, tray icon, settings, presets, and notifications.
- Never accesses the hardware driver directly.
- Sends validated commands to the worker through a named pipe.
- Starts visibly on a normal launch or hidden with `--tray` at login.
- Defaults to read-only. Writes require the in-app lock/unlock consent (or the
  development-only `--enable-write-controls` override); the consent is persisted.
- Starts the worker as a hidden child process when a pipe command cannot reach
  an existing worker, and binds it to a kill-on-close Job Object so a GUI crash
  cannot leave an orphan hardware owner or policy ticker behind.
- Supervises the worker: bounded-backoff respawn on exit (5/10/20/40/60 s),
  heartbeat-watchdog replacement of a hung worker after 30 s without a completed
  sample, and saved-policy re-push after replacement. Pipe timeouts, busy-pipe
  (`ERROR_PIPE_BUSY`) and other transport stalls suppress the heartbeat instead
  of feeding it, so a worker that stops reading is still replaced.
- Uses fail-closed recovery only for a worker that keeps answering with
  `refresh_failed`: after five consecutive hardware read failures it latches a
  terminal fault, stops the monitor, terminates the worker, blocks automatic
  restart for the current session, and asks for a Windows reboot. Transport
  stalls do not latch this terminal fault; they are handled by the watchdog.
- Holds the single-instance mutex `Local\AmdMobilePower.RustGui.Migration.v1`;
  UI fixtures use an isolated `.Fixture.<pid>` mutex so captures do not wake the
  stable tray GUI.

### C++ worker (amdmobilepower_native_worker.exe)

- Currently runs as a hidden child of the GUI at the current user's privilege
  level. A privileged service or scheduled-task worker is a future deployment
  option, not current behavior.
- Owns the RyzenAdj handle and periodic hardware refresh.
- Applies validated STAPM, PPT Fast, and PPT Slow targets when both
  `--enable-hardware` and `--enable-write-controls` are present.
- Monitors the battery/AC power line when a policy is enabled and applies the
  validated target for that line when the line is enabled, with duplicate-write
  suppression and a five-second failure backoff. Once a line/target is applied,
  the controller re-asserts only when the observed Fast or Slow limit is above
  the configured ceiling plus the read-back tolerance. Lower values are treated
  as firmware clamps; STAPM-only movement and missing/non-finite readings do not
  trigger writes. Battery-only policy leaves the AC/external line untouched.
- Exposes `lastObservedPowerLine`, `lastAttemptPowerLine`, and
  `lastAppliedPowerLine` separately. Observation may advance without an apply;
  clients must use the attempt/applied line for application status. Workers
  before 1.0.42 omit the latter two fields, and clients default them to null.
- Publishes telemetry snapshots to the GUI; filters non-finite (NaN/Inf) reads
  to null and reports the firmware-clamp flag against the persistent
  last-applied target.
- Rejects invalid or unsupported commands; parses watt fields with a safe
  signed 32-bit integer extractor.
- Detects known hardware owners (the legacy `Local\RyzenAdjPowerWorker` mutex,
  known RyzenAdj-based processes, and its own
  `Local\AmdMobilePower.HardwareOwner.v1` mutex) before loading the driver.
- Attempts to restore previous required Fast/Slow limits when a write or
  read-back fails.

### Shared contracts

- The native profile catalog is compiled into the worker and exposed read-only
  through `getProfiles`. Validation, telemetry parsing, and the pipe protocol
  live in the worker; the GUI keeps its own pipe client and UI-state
  persistence.
- The legacy .NET `AmdMobilePower.Core` shared library is not part of the native
  line.

## IPC

Use a named pipe (see `IPC.md` for the full contract):

```text
\\.\pipe\AmdMobilePower.RustGui.Worker.v1   GUI default / deployed pipe
\\.\pipe\AmdMobilePower.NativeWorker.v1     worker standalone default
```

Protocol requirements:

- Versioned request and response messages with request IDs and structured errors.
- Explicit timeout and cancellation on both sides (the GUI client bounds pipe
  I/O at 5 s and caps responses at 1 MiB; the worker bounds request reads and
  response sends at 5 s).
- No arbitrary command-line execution.
- The worker pipe uses an explicit DACL (current user read/write/synchronize,
  SYSTEM full control) and `FILE_FLAG_FIRST_PIPE_INSTANCE`; it fails closed if
  the security descriptor cannot be built.
- An incomplete client connection is isolated to that request and cannot
  terminate the worker.

Implemented commands: `getHealth`, `getProfiles`, `getCapabilities`,
`getSnapshot`, `applyTarget` (write flag), `getPowerPolicy`, `setPowerPolicy`
(write flag), and `shutdown`. `exportDiagnostics` is not a worker command;
diagnostics export is GUI-side. `refreshTelemetry`, `setPresets`, and
`restartWorker` are reserved protocol names but are not implemented commands.
See `IPC.md`.

## Data Locations

Current native installed and portable mode:

```text
%LocalAppData%\AmdMobilePower\rust-ui-state.json
%LocalAppData%\AmdMobilePower\diagnostics\
%LocalAppData%\AmdMobilePower\logs\
```

The legacy .NET GUI used `ui-state.json`; the native GUI uses
`rust-ui-state.json`, serialized by the `Local\AmdMobilePower.UiState.v1` named
mutex and written atomically (BOM-tolerant loading, corrupt-state backup). The
native worker compiles its profile catalog into the executable and exposes it
read-only through `getProfiles`; the current implementation does not read an
external `worker\profiles` directory, persistent worker config, or ProgramData
directory. GUI and worker diagnostic logs are local rolling daily files and are
not included in GUI or portable-collector compatibility exports. The worker's
local diagnostic response may contain paths and recent logs for in-process
support, but public exports use a field whitelist and path redaction.

Future service or machine-wide deployment may use:

```text
%ProgramData%\AmdMobilePower\config.json
%ProgramData%\AmdMobilePower\profiles\
%ProgramData%\AmdMobilePower\logs\
<app>\data\config.json
<app>\data\logs\
```

## Development and Stable Deployment

```text
D:\amd-mobile-power    source, tests, CI, experimental builds
C:\RyzenAdj            current stable-local native deployment (1.0.42)
```

Promotion is one-way through `native/promote-stable-deployment.ps1` and requires
the verified package, a recoverable timestamped backup, and the hardware and
runtime gates in `DEPLOYMENT.md` and `RELEASE_CHECKLIST.md`. Stable deployment
files are never edited as source. The current stable-local deployment is
`1.0.42`; public release remains unapproved. The rollback to the previous
stable `1.0.41` tree is
`C:\RyzenAdj.before-20261118-054742205-v1.0.41-6bf8144`.

`native/verify-release.ps1` is the release-gate wrapper for this ownership
boundary. It records the initial stable GUI/arguments, clears only test
GUI/worker processes rooted under repository artifacts, and always restores the
stable `C:\RyzenAdj` tray from `finally`. The recovery uses
`apply-power-policy-direct.ps1 -AllowGuiAutoStart -RefreshGui`, applies the
current 07:00-23:00 (`25/45 W`) or night (`15/15 W`) policy, and independently
probes `enabled=true` and the current Fast/Slow limits. A failed recovery is
reported as a composite error; it does not replace the original gate failure.
The contract test parses this structure and injects body/recovery failures into
the extracted `catch`/`finally` blocks; it never touches the stable processes
or hardware.

Host-specific day/night maintenance has three triggers: 07:00, 23:00, and
current-user logon plus 20 seconds. The logon path uses
`native/restore-current-policy.ps1` to choose the configured window from the
local clock, then delegates to the same verified direct-policy helper. This
closes the gap where an unexpected reboot between boundaries left no GUI,
worker, or policy ticker. The logon task is limited/interactive, runs on
battery, ignores overlapping instances, and is installed only by an explicit
`install-current-policy-task.ps1 -Apply`; it is not a package-wide default.

## Capability Detection

The worker reports:

- CPU family/model name.
- SMU BIOS interface version.
- PM table version.
- Supported limit fields.
- AC and battery state.
- Requested and effective values.
- Separate firmware-limit readback for STAPM, Fast, and Slow.

The GUI must show unsupported capabilities rather than writing blindly.

## Hardware Safety

- No skin-temperature, current, voltage, or clock changes in the initial scope.
- Apply PPT Fast and Slow as the required power caps. Attempt STAPM as a
  best-effort diagnostic/control value because firmware may manage it
  dynamically or reject low values independently.
- Read back every value.
- Require Fast and Slow transport success and read-back to match. If STAPM is
  clamped or rejected, keep the command successful but surface the effective
  limit and warning.
- Use conservative defaults and a hard user-configurable ceiling.
- Refuse concurrent ownership with known RyzenAdj-based tools or another
  AMD Mobile Power worker.

## Packaging

- GUI and worker target Windows x64.
- Worker and hardware dependencies remain separate from the GUI executable.
- The portable ZIP includes a README and checksums.
- The installer creates current-user startup, Start-menu, and uninstall entries;
  the driver bootstrap uses a current-user logon task to start the driver
  service with highest privileges while the GUI and worker stay non-elevated.
- Development packages launch read-only by default.
