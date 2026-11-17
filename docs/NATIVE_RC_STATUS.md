# Native Release Candidate Status

Status: `STABLE_LOCAL_DEPLOYED_1.0.41_CANDIDATE_1.0.42_SOURCE_READY`

This document tracks the native Rust GUI + C++ worker package and its
stable-local deployment. `C:\RyzenAdj` currently holds `1.0.41`
(source commit `6bf8144`, limits-aware drift repair). The real rollback to the
previous stable `1.0.40` tree is `C:\RyzenAdj.before-20261118-032150`.
A later same-version promotion left
`C:\RyzenAdj.before-20261118-032310`, which also contains `1.0.41` and is not
the previous-stable rollback. The `1.0.39` tree is preserved as
`C:\RyzenAdj.before-20261118-001504`; the `1.0.33` tree remains at
`C:\RyzenAdj.before-20261117-035509`.
`1.0.30-native` (source commit `2f04605`, BOM-tolerant state loading) previously
held this target. `1.0.29-native` is
preserved as `C:\RyzenAdj.before-20261114-072507`, `1.0.28-native` as
`C:\RyzenAdj.before-20261114-054523` and `1.0.27-native` as
`C:\RyzenAdj.before-20261114-025845`. `1.0.23-native` shipped the maximize
scroll clamp, page-step alignment, and fractional-DPI header alignment;
`1.0.22-native` is preserved as
`C:\RyzenAdj.before-20261113-024133`, `1.0.21-native` as
`C:\RyzenAdj.before-20261113-012141`, `1.0.20-native` as
`C:\RyzenAdj.before-20261113-004532`, `1.0.19-native` as
`C:\RyzenAdj.before-v1.0.20-native-20261112-ui`, `1.0.18-native` as
`C:\RyzenAdj.before-v1.0.19-native-20261112-ui`. The
previous native `1.0.17-native` build is preserved as
`C:\RyzenAdj.before-20261112-074413`, `1.0.16-native` as
`C:\RyzenAdj.before-20261112-070824`, `1.0.15-native` as
`C:\RyzenAdj.before-20261112-064143`, `1.0.14-native` as
`C:\RyzenAdj.before-20261112-063328`, `1.0.13-native` as
`C:\RyzenAdj.before-20261112-062726`, `1.0.12-native` as
`C:\RyzenAdj.before-20261112-055844`, `1.0.11-native` as
`C:\RyzenAdj.before-20261112-055115`, `1.0.10-native` as
`C:\RyzenAdj.before-20261112-052733`, `1.0.9-native` as
`C:\RyzenAdj.before-20261112-041014`, `1.0.8-native` as
`C:\RyzenAdj.before-20261112-033749`, and `1.0.7-native` as
`C:\RyzenAdj.before-20261112-025316`, `1.0.6-native` as
`C:\RyzenAdj.before-20261112-023730`, `1.0.5-native` as
`C:\RyzenAdj.before-20261112-022356`, the earlier `1.0.4-native` build as
`C:\RyzenAdj.before-20261112-015439`, the `1.0.3-native` builds as
`C:\RyzenAdj.before-20261112-011649` and
`C:\RyzenAdj.before-20261112-005635`, `1.0.2-native` as
`C:\RyzenAdj.before-20261112-003929`, and `1.0.1-native` as
`C:\RyzenAdj.before-20261111-233609`, `1.0.0-native` as
`C:\RyzenAdj.before-20261111-232010`, and the .NET `1.0.4` package as
`C:\RyzenAdj.before-20261111-223017`.

Decision (2026-11-18): the native line has a fully gated stable-local
deployment for the verified 8845HS platform, and `C:\RyzenAdj` contains the
`1.0.41` package (source `6bf8144`) with the full post-1.0.39 safety
remediation and limits-aware drift repair. Broader AMD generation support
remains experimental. Public release remains `READY_FOR_HUMAN_REVIEW` and is
not approved; real OS DPI transitions, a second AMD device, a clean Windows
WinRing0 baseline, hosted CI for this source, and owner media review are still
open. Current per-gate status for 1.0.41 is tracked in `RELEASE_CHECKLIST.md`.
Evidence:
`docs/evidence/packaging/v1.0.41-release-gate-2026-11-18.json`,
`docs/evidence/packaging/v1.0.41-deployment-2026-11-18.json`,
`docs/evidence/hardware/v1.0.41-night-policy-restore-2026-11-18.json`.

## Source Candidate 1.0.42

The working tree contains a source-ready, not yet packaged candidate. It adds
explicit policy attempt/applied power-line fields, separates the automatic
policy target from the most recent manual write target, hardens the maintenance
scripts against observation-only stale success, and binds promotion to the
verified ZIP identity and installed payload checksums. The promotion helper is
compatible with Windows PowerShell 5.1 and PowerShell 7 and distinguishes a
same-version backup from the previous-stable rollback.

Driver-free checks pass: Rust GUI 74 tests, probe 7 tests, C++ power-policy 18
cases plus the other three C++ suites, policy script contract 13/13, policy
observation contract 6/6, promotion contract 16/16 in both PowerShell hosts,
worker request bounds, helper/recovery/install-scope contracts, formatting,
Clippy, document links, and `git diff --check`. No 1.0.42 ZIP, formal hardware
gate, deployment, or publication exists yet. The stable deployment remains
1.0.41 with night 15/15 W and day battery 25 W / AC 45 W.

Note (2026-11-12): `1.0.18-native` is the first package gated with
`-VerifyWorkerHang`, which runs the maintained hang verifier against the
expanded package. `1.0.17-native` added hung-worker replacement on top of the
30 s heartbeat watchdog. A worker that stops answering is terminated from a
background thread and respawned, then the saved battery/AC policy is restored;
the GUI window remains responsive even while a driver-bound worker is being
replaced. `1.0.16-native` added worker supervision with automatic
policy restore and a probe that retries `ERROR_PIPE_BUSY`. `1.0.13-native` added the packaged headless
`amd-mobile-power-probe.exe` and makes the GUI, probe, worker, and portable ZIP
byte-reproducible from the same commit. `1.0.12-native` was the first release
whose deployed binaries matched a verified rebuild. `1.0.10-native` supersedes `1.0.9-native` by keeping the
target editor synchronized with the active preset at startup and during policy
refresh. `1.0.9-native` itself superseded `1.0.8-native` by correcting the
target input after profile clamping. `1.0.8-native` supersedes `1.0.7-native`
by waiting for an
app-owned driver to reach `Stopped` before replacing its `.sys` file and by
making the UI verifier wait for advanced-mode policy controls. `1.0.7-native`
added a safe `uninstall-driver-bootstrap.ps1` and an installer that reuses an
existing WinRing0 service rather than replacing another installation's binary
path.
`1.0.6-native` added the package-local elevated `install-driver-bootstrap.ps1`
for fresh Windows hosts. `1.0.5-native` added deterministic 100/125/150%
logical DPI layout fixtures executed against the packaged GUI.
`1.0.4-native` added the family-indexed multi-generation profile catalog,
read-only `getProfiles`, complete-catalog compatibility reports, and
report-import validation. Every RyzenAdj family `0-15` maps to exactly one
conservative fallback while `8845HS + 4c0009` remains the sole verified device
profile. Worker version is `0.6.0-native`. The reviewed local shortcut launches
with `--simple-mode --max-target-watts 45`; saved presets are `10/25/45 W`,
the automatic battery/AC policy is armed, and temporary local caps are runtime
state rather than package defaults. `1.0.3-native` added per-monitor DPI awareness, a
resizable native window, hand cursors, a protected metric band, and the
uniform policy. `1.0.2-native` added the embedded
PE icon (`RT_ICON` + `RT_GROUP_ICON` 1). `1.0.1-native` fixed the desktop
shortcut exiting immediately with `unknown argument: --simple-mode`. The native
parser accepts `--simple-mode` / `--advanced-mode`,
`--max-target-watts <N>`, and `--uniform-target-watts <N>`;
`native/gui-cli-contract.json` remains the single source of truth, and the
publication-readiness gate launches the deployed GUI with the real shortcut
arguments under an isolated `%LocalAppData%` and a unique worker pipe.
`1.0.0-native` remains the
historical candidate: it contains the complete
break-and-rebuild UI: one continuous dark command deck shared by simple and
advanced modes, a flat simple telemetry ledger, a split advanced workspace,
and live STAPM/Fast/Slow read-back. It also adds test-only failure-state
fixtures for worker offline, firmware clamp, unsupported platform, and long
error, with write-control state assertions. The advanced policy now supports
`仅电池`, which skips AC/external writes entirely. The new high-contrast
fixture renders the complete shell with black surfaces, white text, yellow
structure, and black text on yellow primary actions without changing Windows
accessibility settings.

## Stable Candidate 1.0.41

The exact `1.0.41` package passed the formal gate, was promoted from a clean
source tree, and is deployed to `C:\RyzenAdj`. It adds limits-aware drift repair
to the C++ worker policy controller:

- After a successful apply, Fast or Slow above the configured ceiling plus the
  read-back tolerance re-applies the same line target.
- Lower Fast/Slow values are treated as firmware clamps and do not reapply.
- STAPM-only movement, missing values, and non-finite samples do not trigger
  writes; failed repairs retain the five-second backoff.
- A power-line change still applies the new line target immediately.

```text
artifacts/native-packages/amd-mobile-power-v1.0.41-win-x64-native-preview.zip
```

- Size: `793,163` bytes.
- SHA256:
  `f376e1a28746a376e0f2f8a0ff72ed87c70bd5271821885b1ef36ec7098dc847`.
- Source commit: `6bf8144ebdfbf1805eaac8a4472ee2f939560e2d`.
- Working tree at build time: clean.
- Binary identities: GUI
  `27b17ece3b9a313ac0affd911848d79c37a0301a5535c04182cfc58a76715cfc`,
  worker
  `e14c58c83493546c34f3a6b691b536bdf916c3a052867fb60c6bb9865141f258`,
  probe
  `00369735f7d3623592ad4806973a115161744e42c304ca3cbd52d322300ec353`.
- Formal gate: `Verification=PASS` for package runtime/compatibility/headless/
  install, shell integration, current-value no-change policy, worker-hang,
  DPI 100/125/150, 1366x768/200% work area, maximize scroll, and byte
  reproducibility. Stable GUI recovery is also `PASS`.
- Deployed live state: GUI PID `44884`, worker PID `31924`, automatic policy
  `enabled=true`, battery and AC targets all six limits at `15 W`, and current
  AC STAPM/Fast/Slow read-back `15/15/15 W`.
- Policy schedule: night 23:00-07:00 is `15/15 W`; day 07:00-23:00 is battery
  `25 W` / AC `45 W`.
- Rollback: `C:\RyzenAdj.before-20261118-032150` contains the previous stable
  `1.0.40` tree. `C:\RyzenAdj.before-20261118-032310` is a second same-version
  promotion backup containing `1.0.41`.

## Previous Stable Candidate 1.0.40

```text
artifacts/native-packages/amd-mobile-power-v1.0.40-win-x64-native-preview.zip
```

- Size: `793,042` bytes.
- SHA256:
  `957f8a56dbf31d9d914d1c6eb1dec75262af8bd38e26b438d565315dbac0da8e`.
- Source commit: `ca64f37e757bb99ffaf3df2572f82841bd8b3ad6`.
- Working tree at build time: clean (frozen candidate).
- Binary identities: GUI `27b17ece`, worker `6e9cc6a9`, probe `00369735`;
  independent mapped rebuilds and the frozen ZIP repack match exactly.
- Formal gate: `Verification=PASS` for package runtime/compatibility/headless/
  install, shell integration, current-value no-change policy, worker-hang,
  DPI 100/125/150, 1366x768/200% work area, maximize scroll, and byte
  reproducibility.
- Worker-hang replacement: PASS on 2026-11-17 (`34.6 s`, 16 responsive
  samples, 0 failures, isolated 10 W policy restored).
- Rust tests at freeze: `69` (`37` library + `32` GUI); probe self-tests:
  `7/7`; Clippy `-D warnings` and C++ policy/cleanup/worker-safety suites PASS;
  worker request-bounds handles/threads unchanged.
- Live policy after deployment: automatic policy `enabled=true`,
  `lastAttemptSucceeded=true`; day 07:00 battery 25 W / AC 45 W, night
  23:00 both lines 10 W. AC read-back at 00:40 was STAPM/Fast/Slow
  `10/10/10 W` with measured `9.999/10.004/9.997 W`.
- The exact ZIP was deployed to `C:\RyzenAdj` before the `1.0.41` promotion.
  Its full tree is preserved at `C:\RyzenAdj.before-20261118-032150`; the
  previous `1.0.39` tree remains at
  `C:\RyzenAdj.before-20261118-001504`.

## Evidence Records

Current 1.0.41 records:

```text
docs/evidence/packaging/v1.0.41-release-gate-2026-11-18.json
docs/evidence/packaging/v1.0.41-clean-2026-11-18.json
docs/evidence/packaging/v1.0.41-shell-integration-2026-11-18.json
docs/evidence/packaging/v1.0.41-fixture-policy-isolation-2026-11-18.json
docs/evidence/build/reproducibility-1.0.41-2026-11-18.json
docs/evidence/hardware/v1.0.41-worker-hang-2026-11-18.json
docs/evidence/hardware/v1.0.41-power-policy-no-change-2026-11-18.json
docs/evidence/hardware/v1.0.41-night-policy-restore-2026-11-18.json
docs/evidence/packaging/v1.0.41-deployment-2026-11-18.json
docs/evidence/packaging/v1.0.41-promotion-2026-11-18.json
docs/evidence/ui/native-dpi-100-125-150-2026-11-18.json
docs/evidence/ui/native-workarea-200-1366x768-2026-11-18.json
docs/evidence/ui/native-maximize-scroll-2026-11-18.json
docs/evidence/release/public-sanitization-1.0.41-2026-11-18.json
```

These are local release/deployment records, not a public release. The latest
prepared review bundle under `artifacts/native-release-review/` remains
`v1.0.33` (historical).

## Deployed Safety Remediation

The 1.0.41 package includes the safety remediation introduced after the 1.0.39
freeze and the limits-aware drift repair:

- Rust worker client: 5 s overlapped pipe I/O timeout with cancellation and
  reap, a 1 MiB response cap, and a 2 s busy-pipe retry.
- Rust GUI: a kill-on-close Job Object binds the worker so a GUI crash cannot
  leave an orphan hardware owner (fail-closed if assignment fails); five
  consecutive `refresh_failed` responses from a responsive worker latch a
  terminal fault that stops the monitor, terminates the worker, and disables
  automatic restart until the app is restarted; restart backoff is bounded at
  5/10/20/40/60 s and the heartbeat watchdog forces replacement after 30 s
  without a completed sample. Pipe timeouts and `ERROR_PIPE_BUSY` stalls
  suppress the heartbeat instead of counting as hardware failures.
- Rust GUI state: the single-instance mutex is
  `Local\AmdMobilePower.RustGui.Migration.v1` (fixtures use a `.Fixture.<pid>`
  suffix); the shared UI-state file lock is `Local\AmdMobilePower.UiState.v1`,
  with atomic writes, BOM-tolerant loading, and corrupt-state backup.
- Consent dialog: high-contrast system-color palette, full keyboard navigation
  (Tab/Esc/Enter, focus rectangle), work-area-aware scaling with a 60% floor,
  and a confirm button disabled until the consent checkbox is ticked.
  Read-only high-contrast (150%) and normal (100%) consent captures:
  `docs/evidence/ui/remediation-consent-hc-2026-11-17.json`,
  `docs/evidence/ui/remediation-consent-normal-2026-11-17.json`.
- C++ worker: an explicit pipe DACL (current user read/write/synchronize,
  SYSTEM full control) that fails closed; `FILE_FLAG_FIRST_PIPE_INSTANCE`;
  hardware-owner conflict detection (legacy `Local\RyzenAdjPowerWorker` mutex,
  known-process enumeration, and its own
  `Local\AmdMobilePower.HardwareOwner.v1` mutex) before any driver load;
  NaN/Inf telemetry filtering; a persistent last-applied target that drives the
  firmware-clamp flag (0.5 W STAPM / 0.75 W PPT tolerance); and safe signed
  32-bit integer request parsing.
- Local verification at the 1.0.41 freeze: Rust `cargo test --release` 69
  passed (37 library + 32 GUI); probe 7/7; C++ `power_limit_policy`,
  `power_policy`, `hardware_cleanup`, and `worker_safety` tests all PASS
  (driver-free).
- Deployed policy behavior: 1.0.40 cached `last_applied_target` and did not
  re-read the actual limits on every tick. Stable 1.0.41 now checks STAPM,
  Fast, and Slow each enabled-policy tick and re-asserts a target only when
  Fast or Slow is above the configured high-side tolerance. Lower firmware
  clamps and STAPM-only movement do not force writes.

Historical candidate `1.0.7-native` remains recorded with package SHA256
`a018e1af1a82a5be1dc1cee4fa54cf419d35a778cd056a16a5a35a34262635c4`
and source commit `01cdb506415b0b7fc4b39d7e328f8f282c9696cf`.

Historical candidate `1.0.6-native` remains recorded with package SHA256
`1bb6fbb5e3ff0dd7223cd47a95211fed4b71c6d360f4343700fb2999fbb7321d`
and source commit `a9c02aa1dcc7722c71ccc37a9f55ce82ae32ee6e`.

Historical candidate `1.0.5-native` remains recorded with package SHA256
`a0db74b65be3be165c3587beeb61682d7a44db3b584c04622f23d1ca4102ba60`
and source commit `22a062479a1c9f162ca8baf6cd21309684681b20`.

Historical candidate `1.0.4-native` remains recorded with package SHA256
`0f6889803372c70436d3e61b16b544a53ec7b9b87de75d563fd11a117ddcc70e`
and source commit `6e9e10c3207660fd5f878b389187ceaa91c9f396`.

Historical candidate `1.0.3-native` remains recorded with package SHA256
`2935779907f89d38c0ca7d1a46a9661de6a18b32b6bf8bb7083bedff74807b8e`
and source commit `e26ede44aab40bea8b2470edf9203f9c94b70054`.

Historical candidate `1.0.2-native` remains recorded with package SHA256
`614743257e66c002b5873e3bc5f36f57a874bf763e6a3cb728a28225eec16d9c`
and source commit `545f6bcc2e116e667cad0f87331d97b5b9284c2a`.

Historical candidate `1.0.1-native` remains recorded with its exact package
SHA256
`992290ffb2337038c937932e2a4888db19946df46c2678b7a32b33285f997cad`
and source commit `442309753f6965a4ba01ff0ae4f34e81280f34e5`.

Historical candidate `1.0.0-native` remains recorded with its exact package
SHA256
`f3fd6ea1d1b0292c6ec9ea7445f191adc302066f78a728528a3722923c73a0bf`
and source commit `ddb7d9cba3195f4a16df1299215a9e26cd18544f`.

## Passed Gates

These are accumulated gates from the native release history. The current
candidate's per-gate status is tracked in `RELEASE_CHECKLIST.md`; older counts
below (for example the 48/48 Rust figure) are historical, not 1.0.39 figures.

- Rust GUI lifecycle, three Win32 minimize/restore cycles, close-to-tray, tray
  restore, single-instance wake-up, diagnostics export, view switching,
  topmost, and editable preset persistence.
- Rust unit tests: 48/48 passed, including a contract test that parses every
  entry in `native/gui-cli-contract.json` and a regression test for the
  desktop shortcut arguments and uniform 10 W policy.
- Rust probe tests: 7/7 passed.
- Rust formatting and Clippy with `-D warnings`.
- C++ power-limit policy and battery/AC policy tests.
- Read-only hardware capability and telemetry probe on Ryzen 7 8845HS on AC:
  Hawk Point family `10`, PM table `4c0009`, profile
  `hawk-point-8845hs`, limits `10/10/10 W`.
- `1.0.18-native` clean package verification (19 checksum entries), isolated
  install/uninstall, shell integration, DPI fixtures, packaged headless probe,
  and a controlled current-value policy probe pass. The deployed UI shows
  target editor `10`, effective range `5-10 W`, one visible `10 W` preset, and
  live `10/10/10 W` read-back.
- The headless probe runs from the expanded ZIP with the GUI closed:
  `collectionStatus=PASS`, `hardwareInitialized=true`, write controls disabled,
  matched `hawk-point-8845hs`, live AC `10/10/10 W`.
- Reproducibility gate: GUI, probe, C++ worker, and the portable ZIP are
  byte-identical across two builds of the same commit.
- Worker supervision: killing the deployed worker produced a replacement in
  `1.3 s`; the saved policy was re-applied (`enabled=true`, both targets
  `10/10/10`) and the pipe served `10/10/10 W` again. The probe answered
  `30/30` calls while the GUI polled.
- Hung-worker replacement: `NtSuspendProcess` held the isolated worker for
  `34.5 s`; the GUI stayed `Responding=true`, a replacement worker appeared,
  and the saved policy was re-applied (`enabled=true`, both targets
  `10/10/10`, `lastAttemptSucceeded=true`). Termination and the bounded wait
  run off the UI thread.
- The hang check is now repeatable: `native/verify-worker-hang.ps1` refuses to
  run beside another hardware owner, starts an isolated GUI/worker pair,
  suspends the worker, samples GUI responsiveness every second, and requires
  the replacement to restore the 10 W policy. `verify-release.ps1
  -VerifyWorkerHang` runs it against the expanded package.
- `1.0.18-native` is the first package gated with `-VerifyWorkerHang`:
  replacement in `34.9 s`, `28/28` responsive samples, zero failures, and the
  10/10/10 W policy restored.
- Native read-only write guard: invalid target rejected, no write requested.
- Battery-authorized dry-run write guard: PASS with
  `ExecuteNoChangeWrite=Not requested`.
- `1.0.8-native` clean package verification with 18 checksum entries,
  isolated install/overwrite/uninstall, extracted GUI/worker read-only
  verification, compatibility JSON/Markdown collection, and
  `PolicyWriteVerification=Skipped`.
- The package includes safe WinRing0 install and uninstall helpers; package
  verification requires both, and all 19 deployed payload files match.
- The driver bootstrap waits for an app-owned service to stop before replacing
  its `.sys` file and attempts a restart if replacement/configuration fails.
- The UI verifier passed three consecutive policy-control runs after adding
  readiness waits for the battery-only and policy-enable buttons.
- Real current-user Start menu, Startup shortcut, and uninstall-entry
  create/remove cycle.
- Cross-version upgrade from `rc.17` to `1.0.0-native`: installed payload matched the
  new archive, upgraded GUI/worker passed read-only verification, and uninstall
  removed the installation directory.
- Foreground-verified screenshot capture for simple, advanced, and read-only
  states at 125% Windows scaling.
- Failure-state and battery-only screenshots with machine-checked
  target/preset/diagnostics availability. No hardware worker is started for
  these fixtures.
- Focused-input captures with the actual child focus verified, plus diagnostics
  checks for active mode, topmost state, taskbar icon availability, and tray
  icon id.
- High-contrast simple and advanced captures with `ui.highContrast=true`, no
  hardware worker startup, and the same target/preset/diagnostics availability
  checks as the other write-controls fixtures.
- Extracted `1.0.8-native` packaged GUI/worker verification with GUI and worker
  hashes, three minimize/restore cycles, close-to-tray, tray restore,
  single-instance wake, `taskbarIconAvailable=true`, `trayIconId=1`, and the
  persisted `simple` to `advanced` mode transition.
- Controlled policy probe requested the live AC limits `10/10/10 W`, verified
  the worker read-back, disabled the policy, and shut down cleanly. Live limits
  remained `10/10/10 W`.
- Embedded-icon gate: the built, staged, and deployed GUI each carry
  `RT_GROUP_ICON` 1 with 9 `RT_ICON` images, and the 32x32 icon extracted from
  the deployed exe matches `assets/amd-mobile-power.ico` with zero pixel
  differences. `build.ps1`, `build-package.ps1`, and the readiness gate all fail
  on a missing icon.
- The verified package is deployed at `C:\RyzenAdj` with the prior
  `1.0.7-native` build at
  `C:\RyzenAdj.before-20261112-025316`, `1.0.6-native` at
  `C:\RyzenAdj.before-20261112-023730`, `1.0.5-native` at
  `C:\RyzenAdj.before-20261112-022356`, `1.0.4-native` at
  `C:\RyzenAdj.before-20261112-015439`, earlier `1.0.3-native` builds at
  `C:\RyzenAdj.before-20261112-011649` and
  `C:\RyzenAdj.before-20261112-005635`, `1.0.2-native` at
  `C:\RyzenAdj.before-20261112-003929`, and `1.0.1-native` at
  `C:\RyzenAdj.before-20261111-233609`, `1.0.0-native` at
  `C:\RyzenAdj.before-20261111-232010`, and the .NET `1.0.4` directory at
  `C:\RyzenAdj.before-20261111-223017`. The deployed GUI/worker passed
  read-only worker, lifecycle, tray, single-instance, mode, preset,
  battery-only, and diagnostics checks; the desktop shortcut keeps
  `--enable-write-controls --simple-mode --max-target-watts 45`.
- Profile-catalog gate: the worker reports 10 entries, exactly one verified
  profile, and exactly one family fallback for every RyzenAdj family `0-15`.
  The packaged read-only collector returned `PASS` with worker
  `0.6.0-native`, matched `hawk-point-8845hs`, and live `10/10/10 W` limits;
  the importer accepted the report and rejected a synthetic catalog missing
  family `8`.
- DPI layout gate: the packaged GUI rendered simple and advanced shells at
  logical 100/125/150% with exact client sizes `640x392`/`780x680`,
  `800x490`/`975x850`, and `960x588`/`1170x1020`. Separate region inspection
  found no clipped header, target, preset, metric, or status text. Real
  100%/150% Windows sessions remain an external open gate.
- Desktop-shortcut launch gate: the promotion helper launched the promoted GUI
  with the real shortcut arguments under an isolated `%LocalAppData%` and a
  unique worker pipe, and reported `LaunchVerification=PASS` with window title
  `AMD Mobile Power`. The final readiness gate performs the same check against
  `C:\RyzenAdj`, including value-bearing `--max-target-watts 10` and
  `--uniform-target-watts 10`, and reports `LocalReadiness=PASS`,
  `PublicReleaseReadiness=READY_FOR_HUMAN_REVIEW`, and
  `BlockersFromLocalChecks=[]`.
- Added a local compatibility-report importer that rejects non-read-only,
  incomplete-privacy, path-leaking, and duplicate reports; the first rc.17
  report is archived under `docs/evidence/compatibility` and indexed in
  `docs/COMPATIBILITY_REPORTS.md`.

## Evidence

- `docs/evidence/packaging/v1.0.40-release-gate-2026-11-17.json`
- `docs/evidence/packaging/v1.0.40-shell-integration-2026-11-17.json`
- `docs/evidence/packaging/v1.0.40-clean-2026-11-17.json`
- `docs/evidence/packaging/v1.0.40-deployment-2026-11-18.json`
- `docs/evidence/packaging/v1.0.40-promotion-2026-11-18.json`
- `docs/evidence/hardware/v1.0.40-worker-hang-2026-11-17.json`
- `docs/evidence/hardware/v1.0.40-power-policy-no-change-2026-11-17.json`
- `docs/evidence/hardware/v1.0.40-night-policy-restore-2026-11-18.json`
- `docs/evidence/hardware/remediation-policy-script-contract-2026-11-18.json`
- `docs/evidence/build/reproducibility-1.0.40-2026-11-17.json`
- `docs/evidence/release/candidate-1.0.39-frozen-2026-11-17.json`
- `docs/evidence/release/candidate-1.0.39-identity-2026-11-17.json`
- `docs/evidence/release/public-sanitization-1.0.39-2026-11-17.json`
- `docs/evidence/packaging/v1.0.39-clean-2026-11-17.json`
- `docs/evidence/packaging/v1.0.39-deployment-2026-11-17.json`
- `docs/evidence/packaging/v1.0.39-fixture-policy-isolation-2026-11-17.json`
- `docs/evidence/hardware/mechrevo-wujie15-8845hs-1.0.39-15w-write-2026-11-17.json`
- `docs/evidence/hardware/v1.0.39-worker-hang-2026-11-17.json`
- `docs/evidence/ui/native-dpi-1.0.39-2026-11-17.json`
- `docs/evidence/ui/native-workarea-200-1.0.39-2026-11-17.json`
- `docs/evidence/ui/native-resource-1.0.39-2026-11-17.json`
- `docs/evidence/ui/frozen-1.0.39-consent-2026-11-17.json`
- `docs/evidence/ui/frozen-1.0.39-demo-2026-11-17.json`
- `docs/evidence/ui/frozen-1.0.39-panels-2026-11-17.json`
- `docs/evidence/build/reproducibility-1.0.39-2026-11-17.json`
- `docs/evidence/build/hosted-ci-1.0.39-2026-11-17.json`
- `docs/evidence/build/hosted-ci-post-deployment-2026-11-17.json`
- `docs/evidence/media/native-promo-review-v2-2026-11-17.json`
- `docs/evidence/packaging/v1.0.30-release-gate-2026-11-14.json`
- `docs/evidence/packaging/v1.0.30-clean-2026-11-14.json`
- `docs/evidence/packaging/v1.0.30-shell-integration-2026-11-14.json`
- `docs/evidence/packaging/v1.0.30-native-deployment-2026-11-14.json`
- `docs/evidence/hardware/v1.0.30-power-policy-no-change-2026-11-14.json`
- `docs/evidence/hardware/v1.0.30-worker-hang-2026-11-14.json`
- `docs/evidence/ui/native-packaged-1.0.30-ui-2026-11-14.json`
- `docs/evidence/build/reproducibility-1.0.30-2026-11-14.json`
- `docs/evidence/build/hosted-ci-2026-11-14.json`
- `docs/evidence/release/native-publication-readiness-2026-11-14.json`
- `docs/evidence/packaging/v1.0.23-native-clean-2026-11-13.json`
- `docs/evidence/packaging/v1.0.23-native-release-gate-2026-11-13.json`
- `docs/evidence/packaging/v1.0.23-native-shell-integration-2026-11-13.json`
- `docs/evidence/packaging/v1.0.23-native-deployment-2026-11-13.json`
- `docs/evidence/hardware/v1.0.23-native-power-policy-no-change-2026-11-13.json`
- `docs/evidence/hardware/v1.0.23-native-worker-hang-2026-11-13.json`
- `docs/evidence/ui/native-packaged-1.0.23-native-ui-2026-11-13.json`
- `docs/evidence/ui/native-deployed-1.0.23-native-ui-2026-11-13.json`
- `docs/evidence/ui/native-maximize-scroll-1.0.22-baseline-2026-11-13.json`
- `docs/evidence/ui/native-maximize-scroll-2026-11-13.json`
- `docs/evidence/media/native-promo-1.0.23-draft-2026-11-13.json`
- `docs/evidence/packaging/v1.0.22-native-release-gate-2026-11-13.json`
- `docs/evidence/packaging/v1.0.22-native-shell-integration-2026-11-13.json`
- `docs/evidence/packaging/v1.0.22-native-deployment-2026-11-13.json`
- `docs/evidence/hardware/v1.0.22-native-power-policy-no-change-2026-11-13.json`
- `docs/evidence/hardware/v1.0.22-native-worker-hang-2026-11-13.json`
- `docs/evidence/ui/native-packaged-1.0.22-native-ui-2026-11-13.json`
- `docs/evidence/ui/native-deployed-1.0.22-native-ui-2026-11-13.json`
- `docs/evidence/ui/native-workarea-200-1366x768-2026-11-13.json`
- `docs/evidence/media/native-promo-1.0.23-draft-2026-11-13.json`
- `docs/evidence/release/native-publication-readiness-2026-11-13.json`
- `docs/evidence/packaging/v1.0.17-native-watchdog-hang-2026-11-12.json`
- `docs/evidence/packaging/v1.0.17-native-clean-2026-11-12.json`
- `docs/evidence/packaging/v1.0.17-native-release-gate-2026-11-12.json`
- `docs/evidence/packaging/v1.0.17-native-shell-integration-2026-11-12.json`
- `docs/evidence/packaging/v1.0.17-native-deployment-2026-11-12.json`
- `docs/evidence/hardware/v1.0.17-native-power-policy-no-change-2026-11-12.json`
- `docs/evidence/hardware/v1.0.17-native-worker-hang-verifier-2026-11-12.json`
- `docs/evidence/ui/native-packaged-1.0.17-native-ui-2026-11-12.json`
- `docs/evidence/packaging/v1.0.16-native-clean-2026-11-12.json`
- `docs/evidence/packaging/v1.0.16-native-release-gate-2026-11-12.json`
- `docs/evidence/packaging/v1.0.16-native-shell-integration-2026-11-12.json`
- `docs/evidence/packaging/v1.0.16-native-deployment-2026-11-12.json`
- `docs/evidence/hardware/v1.0.16-native-power-policy-no-change-2026-11-12.json`
- `docs/evidence/ui/native-packaged-1.0.16-native-ui-2026-11-12.json`
- `docs/evidence/packaging/v1.0.13-native-clean-2026-11-12.json`
- `docs/evidence/packaging/v1.0.13-native-release-gate-2026-11-12.json`
- `docs/evidence/packaging/v1.0.13-native-shell-integration-2026-11-12.json`
- `docs/evidence/packaging/v1.0.13-native-deployment-2026-11-12.json`
- `docs/evidence/hardware/v1.0.13-native-power-policy-no-change-2026-11-12.json`
- `docs/evidence/build/reproducibility-2026-11-12.json`
- `docs/evidence/diagnostics/headless-probe-8845hs-live-2026-11-12.json`
- `docs/evidence/packaging/v1.0.10-native-clean-2026-11-12.json`
- `docs/evidence/packaging/v1.0.10-native-release-gate-2026-11-12.json`
- `docs/evidence/packaging/v1.0.10-native-shell-integration-2026-11-12.json`
- `docs/evidence/hardware/v1.0.10-native-power-policy-no-change-2026-11-12.json`
- `docs/evidence/ui/native-deployed-1.0.10-capture-2026-11-12.json`
- `docs/evidence/packaging/v1.0.8-native-clean-2026-11-12.json`
- `docs/evidence/packaging/v1.0.8-native-release-gate-2026-11-12.json`
- `docs/evidence/packaging/v1.0.8-native-shell-integration-2026-11-12.json`
- `docs/evidence/hardware/v1.0.8-native-power-policy-no-change-2026-11-12.json`
- `docs/evidence/packaging/v1.0.8-native-deployment-2026-11-12.json`
- `docs/evidence/ui/native-packaged-1.0.8-native-ui-2026-11-12.json`
- `docs/evidence/ui/native-deployed-1.0.8-native-ui-2026-11-12.json`
- `docs/evidence/ui/native-dpi-100-125-150-2026-11-12.json`
- `docs/evidence/compatibility/mechrevo-wujie15-pro-20261112-011617.json`
- `docs/evidence/release/native-publication-readiness-1.0.18-2026-11-12.json`
- `docs/assets/native-exe-icon-2026-11-11.png`
- `native/rust-gui/build.rs`
- `native/check-exe-icon.ps1`
- `docs/evidence/packaging/v1.0.1-native-clean-2026-11-11.json`
- `docs/evidence/packaging/v1.0.1-native-release-gate-2026-11-11.json`
- `docs/evidence/packaging/v1.0.1-native-shell-integration-2026-11-11.json`
- `docs/evidence/hardware/v1.0.1-native-power-policy-no-change-2026-11-11.json`
- `docs/evidence/packaging/v1.0.1-native-deployment-2026-11-11.json`
- `docs/evidence/ui/native-packaged-1.0.1-native-ui-2026-11-11.json`
- `docs/evidence/ui/native-deployed-1.0.1-native-ui-2026-11-11.json`
- `native/gui-cli-contract.json`
- `docs/evidence/packaging/v1.0.0-native-clean-2026-11-11.json`
- `docs/evidence/packaging/v1.0.0-native-release-gate-2026-11-11.json`
- `docs/evidence/packaging/v1.0.0-native-shell-integration-2026-11-11.json`
- `docs/evidence/packaging/v1.0.0-native-cross-version-upgrade-2026-11-11.json`
- `docs/evidence/hardware/v1.0.0-native-power-policy-no-change-2026-11-11.json`
- `docs/evidence/packaging/v1.0.0-native-deployment-2026-11-11.json`
- `docs/COMPATIBILITY_REPORTS.md`
- `docs/evidence/compatibility/index.json`
- `docs/evidence/ui/native-redesign-2026-11-11.json`
- `docs/evidence/ui/native-ui-failure-states-2026-11-11.json`
- `docs/evidence/ui/native-battery-only-policy-2026-11-11.json`
- `docs/evidence/ui/native-battery-only-capture-2026-11-11.json`
- `docs/evidence/ui/native-focus-2026-11-11.json`
- `docs/evidence/ui/native-high-contrast-2026-11-11.json`
- `docs/evidence/ui/native-packaged-1.0.0-ui-2026-11-11.json`
- `assets/native-gui-redesign-simple-2026-11-11.png`
- `assets/native-gui-redesign-advanced-2026-11-11.png`
- `assets/native-gui-redesign-readonly-simple-2026-11-11.png`
- `assets/native-gui-redesign-readonly-advanced-2026-11-11.png`
- `assets/native-battery-only-simple-2026-11-11.png`
- `assets/native-battery-only-advanced-2026-11-11.png`
- `assets/native-focus-simple-2026-11-11.png`
- `assets/native-focus-advanced-2026-11-11.png`
- `assets/native-high-contrast-simple-2026-11-11.png`
- `assets/native-high-contrast-advanced-2026-11-11.png`

Superseded candidates keep their exact historical package and evidence.

## Open Gates

- Obtain read-only compatibility evidence from a different AMD laptop or
  generation when a second device becomes available; no second machine is
  currently available.
- Logical UI layout fixtures now pass at 100%, 125%, and 150% without changing
  system settings; repeat the matrix in real 100%/150% Windows sessions, plus
  focused-input states.
- Verify WinRing0 behavior under a clean Windows security baseline.
- Complete human review of the video, claims, cover, and public-release copy.
- Obtain explicit owner approval for the GitHub Release and Bilibili upload.
- Add a limits-aware policy re-assert in the worker so firmware/EC resets are
  corrected within the supervision interval instead of waiting for the next
  power-line change or scheduled task.

## Promotion Rule

The native package is stable-local for the verified 8845HS platform.
`C:\RyzenAdj` is replaced only through
`native/promote-stable-deployment.ps1`, which requires the verified package,
keeps a full pre-promotion backup, retargets the existing desktop shortcut while
keeping only `native/gui-cli-contract.json` arguments, launches the promoted GUI
with those real arguments, and rolls back on failure.

Public GitHub Release and Bilibili upload remain unapproved.
