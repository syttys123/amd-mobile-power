# Native Promo Capture

`capture-live-demo.ps1` records the Rust GUI from an isolated `--ui-fixture`
instance. It never talks to the deployed worker pipe and never writes hardware.
All generated files stay under the repository `artifacts` directory.

## Clips

The simple-mode command contract remains unchanged: three `command` events for
25 W, 45 W, and 10 W.

```powershell
pwsh -NoProfile -File .\media\promo-native\capture-live-demo.ps1 `
  -GuiExecutable <gui.exe> `
  -Mode simple `
  -UiFixture preset-success
```

The advanced preset clip edits preset 1 from 10 W to 12 W, saves, applies it,
changes it back to 10 W, saves again, and applies 10 W.

```powershell
pwsh -NoProfile -File .\media\promo-native\capture-live-demo.ps1 `
  -GuiExecutable <gui.exe> `
  -Mode advanced `
  -DemoType presets `
  -UiFixture preset-success
```

The advanced policy clip sets battery 25 W / external 45 W, enables and saves
the dual-line policy, switches to battery-only and saves, then restores and
saves the dual-line policy.

```powershell
pwsh -NoProfile -File .\media\promo-native\capture-live-demo.ps1 `
  -GuiExecutable <gui.exe> `
  -Mode advanced `
  -DemoType policy `
  -UiFixture preset-success
```

`-DemoType auto` resolves to the legacy simple clip or the advanced preset
clip. Use `-DemoType legacy` to retain the older advanced selection sequence.

## Completion Contract

Each event records:

- normalized center coordinates for its real control;
- the command or text action and dispatch status;
- a pre-dispatch baseline captured through the same real `PrintWindow` path as
  recorded frames, with a nonzero sampled-pixel count;
- the first captured frame whose sampled client pixels differ enough from the
  pre-dispatch baseline;
- the frame timestamp and changed-pixel count.

`Completed=true` appears only after that visual change is observed. A dispatch
that produces no visible change within `-VisualChangeTimeoutSeconds` fails the
capture instead of being reported as applied.

The isolated fixture title is replaced with a short privacy title before
recording. Client frames use `PW_CLIENTONLY | PW_RENDERFULLCONTENT`. The
recorder exits only its own fixture process, restores `LOCALAPPDATA`, and
removes only its private `artifacts\media\live-demo-state-<guid>` directory.
Cleanup first enumerates and validates every descendant, rejects any reparse
point, then deletes validated owned files and empty directories. A rejected
tree is left untouched.

## Contract Test

The contract test does not launch the GUI and does not write hardware:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\media\promo-native\test-capture-contract.ps1
pwsh.exe -NoProfile -File .\media\promo-native\test-capture-contract.ps1
```

Pass `-EvidencePath` to write the JSON result under `artifacts`.
