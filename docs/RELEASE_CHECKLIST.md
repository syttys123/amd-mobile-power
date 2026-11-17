# Release Checklist

## Deployed Stable 1.0.42 (2026-11-18)

Current target: **1.0.42**, status **STABLE_LOCAL_DEPLOYED_PENDING_PUBLICATION**.
The exact gated ZIP comes from `927a1bb`, SHA256
`35384501e2cf4b5808ba8796d212fb4b7394d49455153e817fefed1c11b44998`
(795,340 bytes). Binary identities: GUI `612a883e`, worker `ffec2afc`, probe
`00369735`.

- [x] Policy state exposes separate observed, attempt, and applied power lines;
      GUI text uses the attempt/applied line and labels manual write targets.
- [x] Maintenance scripts prefer the new fields, require a fresh attempt, and
      fail closed on observation-only stale success; legacy fallback is tested.
- [x] Promotion binds expected ZIP SHA256/source commit, verifies all payload
      checksums after install, scopes process stops and cleanup, and records
      previous/same-version backup identity.
- [x] Driver-free checks: Rust GUI 74, probe 7, C++ power-policy 18 plus three
      other suites, policy script contract 13/13, observation contract 6/6,
      promotion contract 16/16 in PowerShell 5.1 and 7, request bounds,
      helper/recovery/install-scope contracts, formatting, Clippy, docs, and
      `git diff --check`.
- [x] Clean commit and exact `build-package.ps1 -Version 1.0.42` package.
- [x] Formal release gate with reproducibility, shell integration, no-change
      policy, worker-hang, DPI/work-area/maximize fixtures, and sanitization.
- [x] Reversible promotion with a new previous-stable backup and live read-back:
      `C:\RyzenAdj.before-20261118-054742205-v1.0.41-6bf8144`.
- [x] Hosted Windows CI run `44181123711` for `927a1bb` completed successfully.
- [x] Deployed GUI/tray/mode/write-control regression and publication-readiness
      local checks PASS. Current battery read-back is 15/15/15 W.
- [ ] Second AMD device, real OS DPI sessions, clean-Windows WinRing0 baseline,
      owner media review, and explicit publication approval.

Current package gates:

- [x] Formal release gate:
      `evidence/packaging/v1.0.42-release-gate-2026-11-18.json`.
- [x] Clean package, fixture isolation, shell integration, reproducibility:
      `evidence/packaging/v1.0.42-clean-2026-11-18.json`,
      `evidence/packaging/v1.0.42-fixture-policy-isolation-2026-11-18.json`,
      `evidence/packaging/v1.0.42-shell-integration-2026-11-18.json`,
      `evidence/build/reproducibility-1.0.42-2026-11-18.json`.
- [x] Current-value policy and worker-hang replacement:
      `evidence/hardware/v1.0.42-power-policy-no-change-2026-11-18.json`,
      `evidence/hardware/v1.0.42-worker-hang-2026-11-18.json`.
- [x] Deployment, night restore, packaged UI, hosted CI, sanitization, and
      publication readiness:
      `evidence/packaging/v1.0.42-deployment-2026-11-18.json`,
      `evidence/hardware/v1.0.42-night-policy-restore-2026-11-18.json`,
      `evidence/ui/native-packaged-1.0.42-ui-2026-11-18.json`,
      `evidence/build/hosted-ci-1.0.42-2026-11-18.json`,
      `evidence/release/public-sanitization-1.0.42-2026-11-18.json`,
      `evidence/release/native-publication-readiness-1.0.42-2026-11-18.json`.

## Previous Stable 1.0.41 (Rollback)

Previous target: **1.0.41**, preserved at
`C:\RyzenAdj.before-20261118-054742205-v1.0.41-6bf8144`.
It adds high-side Fast/Slow drift correction while ignoring lower firmware
clamps, STAPM-only movement, and missing/non-finite samples. The exact gated ZIP
comes from `6bf8144`, SHA256
`f376e1a28746a376e0f2f8a0ff72ed87c70bd5271821885b1ef36ec7098dc847`
(793,163 bytes). Binary identities: GUI
`27b17ece3b9a313ac0affd911848d79c37a0301a5535c04182cfc58a76715cfc`,
worker
`e14c58c83493546c34f3a6b691b536bdf916c3a052867fb60c6bb9865141f258`,
probe
`00369735f7d3623592ad4806973a115161744e42c304ca3cbd52d322300ec353`.

- [x] Rust GUI 69 tests, probe 7 tests, formatting, and Clippy pass.
- [x] C++ 4 policy/cleanup/worker-safety tests and worker request bounds pass.
- [x] Helper contract and Markdown/document links pass; `verify-docs.ps1`
      checked 53 files and 40 relative links, and `git diff --check` is clean.
- [x] Source commit `6bf8144` contains the four release commits; unrelated
      untracked demo assets stay out.
- [x] Clean `build-package.ps1 -Version 1.0.41` produced the exact candidate
      ZIP and records its SHA256, source commit, and binary identities.
- [x] Formal native gate passed with reproducibility, shell integration,
      no-change policy, and worker-hang checks.
- [x] Exact ZIP promoted with rollback and live probe read-back; current-stable
      documentation is updated to real 1.0.41 evidence.
- [x] Rollback to the previous stable `1.0.40` tree:
      `C:\RyzenAdj.before-20261118-032150`. A second same-version promotion
      left `C:\RyzenAdj.before-20261118-032310`; it also contains `1.0.41`
      and is not the previous-stable rollback.
- [x] Live state: GUI PID `44884`, worker PID `31924`, `enabled=true`, all six
      battery/AC targets at `15 W`, AC STAPM/Fast/Slow read-back
      `15/15/15 W`.
- [x] Night policy 23:00-07:00 is `15/15 W`; day policy 07:00-23:00 is battery
      `25 W` / AC `45 W`:
      `evidence/hardware/v1.0.41-night-policy-restore-2026-11-18.json`.
- [ ] Hosted Windows CI for `6bf8144` has not been run for 1.0.41; do not reuse
      earlier release runs.
- [ ] Real OS 100%/150% DPI transitions, second AMD device, and clean-Windows
      WinRing0 baseline remain pending.
- [ ] Owner approves final GitHub Release and Bilibili publication.

Current package gates:

- [x] Formal release gate PASS:
      `evidence/packaging/v1.0.41-release-gate-2026-11-18.json`.
- [x] Clean package and fixture policy isolation PASS:
      `evidence/packaging/v1.0.41-clean-2026-11-18.json`,
      `evidence/packaging/v1.0.41-fixture-policy-isolation-2026-11-18.json`.
- [x] Shell integration and byte reproducibility PASS:
      `evidence/packaging/v1.0.41-shell-integration-2026-11-18.json`,
      `evidence/build/reproducibility-1.0.41-2026-11-18.json`.
- [x] Current-value no-change policy and worker-hang replacement PASS:
      `evidence/hardware/v1.0.41-power-policy-no-change-2026-11-18.json`,
      `evidence/hardware/v1.0.41-worker-hang-2026-11-18.json`.
- [x] DPI 100/125/150, 1366x768/200% work area, and maximize-scroll fixtures
      PASS: `evidence/ui/native-dpi-100-125-150-2026-11-18.json`,
      `evidence/ui/native-workarea-200-1366x768-2026-11-18.json`,
      `evidence/ui/native-maximize-scroll-2026-11-18.json`.
- [x] Public-sanitization scan PASS:
      `evidence/release/public-sanitization-1.0.41-2026-11-18.json`.
- [x] Deployment and promotion records:
      `evidence/packaging/v1.0.41-deployment-2026-11-18.json`,
      `evidence/packaging/v1.0.41-promotion-2026-11-18.json`.

## Previous Stable 1.0.40 (Rollback)

Previous target: **1.0.40**. Its full tree is preserved at
`C:\RyzenAdj.before-20261118-032150`. The exact gated ZIP comes from
`ca64f37`, SHA256
`957f8a56dbf31d9d914d1c6eb1dec75262af8bd38e26b438d565315dbac0da8e`
(793,042 bytes). Binary identities: GUI `27b17ece`, worker `6e9cc6a9`,
probe `00369735`.

- [x] Formal release gate PASS:
      `evidence/packaging/v1.0.40-release-gate-2026-11-17.json`.
- [x] Rust tests: `69` (`37` library + `32` GUI); probe `7/7`; Clippy
      `-D warnings`; C++ policy/cleanup/worker-safety suites; worker
      request-bounds handles/threads unchanged.
- [x] Clean package runtime, compatibility collector/markdown, headless probe,
      install flow, shell integration, and byte reproducibility.
- [x] Current-value no-change policy gate at 10 W:
      `evidence/hardware/v1.0.40-power-policy-no-change-2026-11-17.json`.
- [x] Worker-hang replacement PASS: `34.6 s`, 16 responsive samples, 0
      failures, policy restored:
      `evidence/hardware/v1.0.40-worker-hang-2026-11-17.json`.
- [x] Logical DPI 100/125/150 fixture PASS and 1366x768/200% work-area /
      maximize-scroll fixture PASS. These are test-only logical overrides, not
      real OS DPI transitions.
- [x] Exact ZIP promoted with rollback; deployed hashes and live read-back
      verified:
      `evidence/packaging/v1.0.40-deployment-2026-11-18.json`.
- [x] Night policy changed to 10 W on both lines; night task action is
      battery 10 / AC 10 with `-AllowGuiAutoStart -RefreshGui`, last result 0;
      day task remains 07:00 battery 25 / AC 45:
      `evidence/hardware/v1.0.40-night-policy-restore-2026-11-18.json`.
- [x] Contract harness PASS `6/6`:
      `evidence/hardware/remediation-policy-script-contract-2026-11-18.json`.
- [ ] Hosted Windows CI for `ca64f37` has not been run for 1.0.40; do not reuse
      the old 1.0.39 runs.
- [ ] Real OS 100%/150% DPI transitions, second AMD device, and clean-Windows
      WinRing0 baseline remain pending.
- [ ] Owner approves final GitHub Release and Bilibili publication.

Current review media is historical 1.0.39 fixture material, not a live 1.0.41
package capture: `artifacts/media/promo-review-20261117-v2/amd-mobile-power-review-v2-silent.mp4`
(39.5 s, `DRAFT_FOR_HUMAN_REVIEW`). Its preset demo uses the hardware-free
`preset-success` fixture. See `PROMO_VIDEO.md`.

## Historical Checklist

Release under review: `1.0.33-native`

Branch: `release/1.0.33`

Status: `HARDWARE_GATE_PASS_PROMOTED_PENDING_HUMAN_REVIEW`

## Source And Build

- [x] Branch worktree is clean before the candidate package build.
- [x] Rust tests pass: 51/51 (28 library + 23 GUI).
- [x] Rust probe tests pass: 7/7.
- [x] Rust formatting and Clippy with `-D warnings` pass.
- [x] C++ power-limit and power-policy tests pass.
- [x] Release build completes with the packaged icon present.
- [x] Package source commit and SHA256 match the clean evidence.
      SHA256 `17fef8f89445a0c13436ffaca04334d4ed58d17aeff34515ecf5c50c2620aaa9`,
      source commit `6ca4d19b9221fc18918d977219af879a0e296b28`.
- [x] 1.0.33 UI polish is covered by the packaged runtime verification:
      `MinimumResizeBounds`, `AdvancedScroll`, and `PolicySave` pass against the
      extracted 1.0.33 package, and the scrolled advanced view no longer shows
      dark field backgrounds or stale text.
- [x] The layout/redraw fix is covered by the packaged runtime verification:
      `MinimumResizeBounds`, `AdvancedScroll`, and `PolicySave` all pass against
      the extracted 1.0.32 package.
- [x] Rebuild from the same tree is byte-identical: GUI `18f82690`, worker
      `67af1d41`, probe `9750418f`, ZIP `33486b2d`.
- [x] Isolated install/overwrite/uninstall flow passes.
- [x] Installer process-scope regression passes while the deployed
      GUI/worker are running.
- [x] Real shell-integration install/startup/Start-menu/uninstall flow passes
      for 1.0.31 and cleans up without residual state.
- [x] Hosted Windows CI passes for the native commit
      (run `43534100849`, commit `92c1821`).
- [x] Hosted Windows CI passes for the release-material commit
      (run `43535933200`, commit `fd45c21`).
- [x] Hosted Windows CI passes for the current branch HEAD
      (run `43547898436`, commit `28092ea`).
- [x] Full `verify-release.ps1 -Version 1.0.31` hardware gate.

## Hardware Evidence

- [x] Read-only capability and telemetry are re-run for this exact package.
- [x] Controlled current-value policy probe passes at the current safe limits
      (`41/45/45 W`, firmware-dynamic STAPM).
- [x] Worker-hang replacement and policy restore pass for this package.
- [x] The worker disables policy and shuts down cleanly after the probe.
- [x] No second hardware owner remains after verification.
- [ ] A fresh battery-to-AC-to-battery transition is re-run for this revision.
- [ ] A second physical AMD laptop has read-only evidence.
- [ ] Clean Windows WinRing0 baseline evidence is recorded.

## UI Evidence

- [x] Extracted packaged GUI lifecycle checks pass: modes, topmost, preset
      editing, target draft retention, focus notifications, minimum bounds,
      advanced scrolling, close-to-tray, tray restore, and single-instance
      wake.
- [x] Packaged UI evidence is recorded:
      `docs/evidence/ui/native-packaged-1.0.31-ui-2026-11-14.json`
      (`BackgroundGuiRelaunched=1`, `WriteControls=PASS`).
- [x] Logical 100/125/150% DPI fixtures are re-run for the 1.0.31 package.
- [x] The 1366x768/200% work-area fixture is re-run.
- [x] Maximize/scroll regression is re-run for the 1.0.31 package.
- [ ] Real OS-level 100%/150% sessions and monitor transitions are recorded.
- [x] Deployed GUI binary matches the packaged UI evidence hashes
      (`18f82690` GUI / `67af1d41` worker), so the promoted tree carries the
      same interaction suite that was verified from the package.

## Local Deployment

- [x] Promoted to `C:\RyzenAdj` with the reversible helper:
      rollback `C:\RyzenAdj.before-20261114-110034`,
      evidence `docs/evidence/packaging/v1.0.31-native-deployment-2026-11-14.json`.
- [x] Deployed `BUILD-INFO.txt` reports `1.0.31`, commit `28092ea`.
- [x] Deployed tray GUI relaunched with `--simple-mode --max-target-watts 45`;
      probe read-back is `45/45/45 W` on AC with policy enabled.
- [x] `verify-publication-readiness.ps1 -Version 1.0.31` reports
      `LocalReadiness=PASS` and `PublicReleaseReadiness=READY_FOR_HUMAN_REVIEW`.

## Release Media

- [x] Seven-scene promo v9 is verified: 1920x1080, 30 fps, 42.5 s, burned-in
      captions, licensed music, and full `ffmpeg` decode.
- [x] Video, cover, and contact-sheet paths, sizes, and hashes match the
      1.0.31 release manifest.
- [x] 1.0.31 release notes, launch copy, candidate dossier, runbook, and media
      evidence are prepared.
- [ ] Owner reviews pacing, captions, claims, cover, and final copy.
- [ ] Public GitHub Release is explicitly approved.
- [ ] Bilibili upload is explicitly approved and uses an authenticated session.

## Safety And Licensing

- [x] The portable package starts read-only by default.
- [x] Hardware writes require the in-app lock or tray unlock consent.
- [x] Every write has a read-back; Fast/Slow failures attempt restoration.
- [x] Existing process, mutex, and scheduled-task owners are documented.
- [x] The driver bootstrap reuses an existing valid WinRing0 service.
- [x] The driver bootstrap waits for an app-owned service to reach `Stopped`.
- [x] The driver uninstaller removes only this installation's driver path.
- [x] RyzenAdj, InpOut32, and WinRing0 notices are present in the ZIP.
- [x] Driver security behavior and unsigned-driver risks are documented.
- [x] Public-sanitization scan passes for tracked files and the 1.0.31 ZIP
      (no personal home paths, internal agent markers, common secrets, or
      private-key headers).

## Promotion

- [ ] Promotion dry run reviewed.
- [ ] Promotion applied with a timestamped recoverable backup.
- [ ] Deployed GUI/worker/probe hashes match the 1.0.31 deployment evidence.
- [ ] Shortcut arguments reviewed against `native/gui-cli-contract.json`.
- [ ] Publication readiness refreshed to `LocalReadiness=PASS` with no local
      blockers.
- [ ] Branch fast-forwarded into `main`.
- [ ] Old automation-named remote branch removed after `release/1.0.31` is
      merged; deletion requires explicit owner approval.
