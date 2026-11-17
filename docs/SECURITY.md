# Security And Hardware Safety

## Current Boundary

AMD Mobile Power changes firmware-facing CPU power limits through RyzenAdj and
low-level Windows driver interfaces. Incorrect values can cause overheating,
instability, shutdowns, battery wear, data loss, or hardware damage.

The engineering redistribution review is recorded in `LICENSING_REVIEW.md`, and
the release package includes the reviewed license texts. Public release still
requires the remaining hardware evidence and project-owner approval; this review
is not legal advice.

## Deployment Note

The deployed `C:\RyzenAdj` package is `1.0.41` (source `6bf8144`), package
SHA256
`f376e1a28746a376e0f2f8a0ff72ed87c70bd5271821885b1ef36ec7098dc847`.
It includes the explicit pipe DACL, legacy-mutex and known-process conflict
detection, the five-consecutive-`refresh_failed` terminal-fault latch, the
kill-on-close Job Object, expanded NaN/Inf telemetry filtering, the persistent
last-target clamp, the UI-state mutex, overlapped pipe I/O with deadlines, and
the pipe-stall watchdog fix. The own-mutex single-owner guard, the
first-pipe-instance flag, and worker supervision/watchdog were already present
in 1.0.39.

The 1.0.41 policy controller re-reads STAPM, Fast, and Slow on each enabled
tick. It re-asserts the configured target only when Fast or Slow is above the
high-side tolerance; lower firmware clamps are accepted, and STAPM-only drift
does not trigger writes. The rollback to the previous stable `1.0.40` tree is
`C:\RyzenAdj.before-20261118-032150`. The later
`C:\RyzenAdj.before-20261118-032310` backup also contains `1.0.41`.

## Default Read-Only Mode

The GUI defaults to read-only. Hardware writes require both:

- The user unlocking writes through the in-app consent dialog (or the
  development-only `amd-mobile-power-gui.exe --enable-write-controls` override).
- The GUI passing `--enable-write-controls` to the worker it launches.

The worker also requires `--enable-hardware`. A normal package launch passes
only `--enable-hardware`, so `applyTarget` and policy writes are rejected. The
persisted unlock state is handed to the worker at launch exactly like the flag.

This is a deliberate double gate, not a claim that the GUI cannot display
writable capabilities.

## Single Hardware Owner

The native worker:

- Acquires the named mutex `Local\AmdMobilePower.HardwareOwner.v1` and refuses
  to start when it already exists (`ERROR_ALREADY_EXISTS`), so a second AMD
  Mobile Power / RyzenAdj hardware owner cannot run. (The legacy .NET worker
  used a named event for the same purpose; the native worker uses a mutex held
  for the process lifetime.)
- Detects the legacy `Local\RyzenAdjPowerWorker` mutex used by the PowerShell
  worker, and fails closed if that mutex cannot be inspected.
- Enumerates running processes and refuses to start when a known owner is
  present: `RyzenPower`, `ryzenadj`, and `AMD Ryzen Master` (case-insensitive,
  with or without a trailing `.exe`).
- Runs these ownership checks before loading the RyzenAdj/WinRing0/InpOut
  runtime DLLs, so a known owner never sees a second driver initialization from
  this process.
- Creates its pipe with `FILE_FLAG_FIRST_PIPE_INSTANCE`, so a second worker
  cannot silently share the same pipe name.

The legacy .NET worker also detected running scheduled tasks such as
`\AMD\RyzenAdjWatch`; the native worker relies on the mutex and process checks
above rather than scheduled-task enumeration.

Do not bypass this protection. Concurrent RyzenAdj owners have caused an
uncatchable native access violation during development. Closing the legacy GUI
is not sufficient when its logon task still has a hidden worker running.

If an owning worker must be force-terminated, treat the WinRing0/inpout/SMU
state as tainted. Reboot before probing or writing again; repeated calls can
raise an access violation inside `init_ryzenadj`.

Restarting the WinRing0 and inpout services does not reliably clear this state.
On the development laptop both services restarted successfully, but
`ryzenadj.exe --info` still hung in SMU polling.

The GUI latches a terminal worker fault after five consecutive hardware read
failures where a responsive worker returns `refresh_failed` for the current
application session. It stops the monitor, terminates the worker, and does not
automatically relaunch it, preventing a crash/restart loop; the status asks the
user to close other RyzenAdj tools and reboot Windows. A worker that stops
answering, holds the pipe busy, or times out is not treated as a hardware read
failure: those transport stalls suppress the watchdog heartbeat and the worker
is replaced after 30 s. The terminal fault is reserved for a worker that keeps
answering while hardware refresh fails.

The GUI binds the worker to a kill-on-close Job Object, so if the GUI dies
without running its cleanup the worker is killed instead of left as an orphan
hardware owner. If the job cannot be created or assigned, the freshly spawned
worker is terminated (fail-closed).

## Write Validation

When write controls are explicitly enabled, the worker:

- Validates the target against the profile and reported capabilities.
- Writes Fast and Slow as the required enforcement pair and treats STAPM as a
  best-effort value because firmware may manage it dynamically.
- Refreshes the PM table and reads every value back.
- Requires Fast and Slow transport success and matching read-back before
  reporting a successful application.
- Reports firmware clamps separately from transport success.
- Attempts to restore the previous three-value target after a write or
  read-back failure.

Controlled 10 W and 12 W writes completed on the development laptop on
2026-11-10 and are recorded in `HARDWARE_MATRIX.md`. The packaged `0.1.3-dev`
GUI/worker also passed the separate 12 W no-change write gate with identical
initial, requested, read-back, and final STAPM/Fast/Slow limits. See
`docs/evidence/hardware/mechrevo-wujie15-8845hs-no-change-2026-11-10.json`.

USB-C power banks are often reported by Windows as AC/external power. The
automatic battery/AC policy cannot identify that case, so a power bank will use
the AC target. Prefer manual conservative targets when operating from a power
bank.

## Process And IPC Model

- The GUI runs at the current user's privilege level.
- The worker is a hidden child process launched by the GUI and bound to a
  kill-on-close Job Object.
- The worker pipe uses an explicit DACL: the current process user gets
  `GENERIC_READ | GENERIC_WRITE | SYNCHRONIZE` and `SYSTEM` keeps `GENERIC_ALL`.
  The worker refuses to start if the descriptor cannot be built; it never falls
  back to a permissive default DACL. (This explicit least-privilege DACL is part
  of the post-freeze hardening.)
- Commands are a fixed set; there is no arbitrary shell execution endpoint.
- Requests and responses use versioned UTF-8 JSON Lines with request IDs. The
  GUI client bounds pipe I/O at 5 s and caps responses at 1 MiB; the worker
  caps requests at 64 KiB and bounds request reads and response sends at 5 s.

The current implementation does not elevate the worker. RyzenAdj still requires
the WinRing0 kernel driver. The development driver helper installs a small
current-user logon task whose only action is to start the already-installed
driver service with highest privileges. The GUI and worker remain non-elevated.

## Data And Diagnostics

- UI presets and policy live in
  `%LocalAppData%\AmdMobilePower\rust-ui-state.json`, serialized by the
  `Local\AmdMobilePower.UiState.v1` named mutex and written atomically. (The
  legacy .NET GUI used `ui-state.json`.)
- Diagnostics are saved under
  `%LocalAppData%\AmdMobilePower\diagnostics` by default.
- GUI and worker lifecycle/error logs are stored under
  `%LocalAppData%\AmdMobilePower\logs` with daily files and seven-day retention.
- GUI and portable-collector diagnostics include hardware capability,
  telemetry, OS/process architecture, and runtime-file hashes.
- Public diagnostic exports exclude executable/log directories, process IDs,
  account names, and recent log excerpts. Known paths and remaining absolute
  Windows/UNC paths are replaced with privacy tokens.
- Diagnostics do not include credentials or provider secrets.

Review diagnostics before attaching them to a public issue. Device names and
firmware versions may still be sensitive even after path redaction.

## Driver And License Risk

RyzenAdj is LGPL-3.0 and is loaded as a separate shared library. Packages include
the upstream LGPL text, the canonical GPL-3.0 text referenced by LGPL-3.0, a
pinned source commit, and instructions for replacing `worker\libryzenadj.dll`
with a compatible build. The bundled InpOut32 and WinRing0 terms are recorded in
`THIRD_PARTY_NOTICES.md` and `LICENSING_REVIEW.md`.

This is an engineering redistribution review, not a legal opinion. WinRing0
remains old kernel driver software and may be blocked or unloaded by Windows
security software; license compliance does not establish runtime safety.
Current host, signature, Defender, and service evidence is recorded in
`WINDOWS_DRIVER_SECURITY.md`.

## Public-Release Gate

Do not publish or promote write-capable builds until:

- The supervised no-change write test passes. Development 8845HS passed.
- Initial and final STAPM/Fast/Slow limits match. Development 8845HS passed at
  12/12/12 W.
- Process cleanup and conflict behavior are verified.
- The driver redistribution review is complete for the package contents
  recorded in `LICENSING_REVIEW.md`.
- The public-sanitization scan passes for tracked files and the portable ZIP:
  no personal Windows home paths, internal agent markers, common API keys or
  tokens, or private-key headers.
- A recovery procedure has been tested on the target device.
