# Promotional Video Review

## Current 1.0.42 Review Cut

The current review cut is a 55-second silent, subtitled video generated from
the HTML/Playwright pipeline in `media/promo-html`. Every GUI interaction uses
the deployed 1.0.42 executable in an isolated hardware-free fixture. The
running tray GUI, worker pipe, saved policy, and hardware limits are not used
by the recorder.

- Duration: 55.0 seconds, exactly 1650 frames.
- Format: 1920x1080, 30 fps, H.264, no audio track.
- Status: `DRAFT_FOR_HUMAN_REVIEW`; not approved for upload.
- Scenes: hook, safety, ui-demo, presets, auto-policy, firmware, compat,
  closing.
- Subtitles: Simplified Chinese, burned into the video.
- Music: none. The earlier synthesized music was removed.

Local render and evidence paths are recorded in
`docs/evidence/media/native-promo-1.0.42-review-2026-11-18.json`.

## What The Video Demonstrates

1. Read-only default, consent checkbox, enabled confirm button, and the
   resulting unlocked state. The application owns the normal worker restart;
   the video does not ask users to run a special command.
2. Immediate 25 / 45 / 10 W preset application with matching target and
   STAPM/Fast/Slow read-back. Current draw remains below the requested cap.
3. Editing preset 1 from 10 W to 12 W, saving it, and applying the updated
   button. The clip later restores 10 W in the isolated fixture.
4. Battery 25 W / external 45 W policy, enable/save, battery-only save, and
   restoration of dual-line control. It explicitly notes that power banks are
   usually reported as external power.
5. A separate firmware-clamp example: requested 12 W, STAPM effective limit
   10 W, Fast/Slow effective limits 12 W.
6. Diagnostics export click and visible success state. The exported fixture
   report contains no local paths, account names, process IDs, serial numbers,
   logs, or upload behavior.
7. The compatibility boundary: only one physical 8845HS has complete evidence;
   other AMD models remain experimental until verified.

The auto-policy scene demonstrates configuration and saved scope. It does not
claim to show a physical unplug/replug transition; that hardware behavior has
separate supervised evidence outside the video.

## Capture And Pointer Contract

`media/promo-native/capture-live-demo.ps1` records simple, advanced preset, and
advanced policy clips. Each event stores the real control center, action,
dispatch time, first visible-change frame, changed-pixel count, and nonblank
baseline count. A blank baseline or an action without a visible change fails
the capture. The old empty-bitmap baseline bug is covered by regression tests.

`capture-consent-flow.ps1` records the real modal checkbox/confirm sequence.
`capture-diagnostics-flow.ps1` records the export command and checks the
isolated JSON privacy block. Fixture window titles are sanitized before
capture; internal pipe GUIDs are not published.

The multi-clip recorder binds each pointer to its own manifest and actual
control coordinates. It never assumes uniform clip timing. Scene transitions
crossfade over an opaque previous scene, avoiding the black boundary frames
found in the historical v2 cut.

## Verification

The current evidence records:

- exact video SHA256, size, codec, dimensions, frame rate, and full decode;
- 1.0.42 GUI identity across all five clips;
- event/visual-frame/pointer bindings and feature coverage;
- 24 rendered keyframes plus focused interaction crops;
- DOM text/image bounds at three points per scene;
- whole-frame, GUI-region, and 960x540 luminance screens;
- attempted independent pojia visual/claim audit (blocked by upstream quota;
  not counted as an independent PASS);
- PowerShell 5.1 and 7 capture-contract results;
- document-link and whitespace checks.

Luminance screening is a heuristic, not proof that every local pixel is
flicker-free. The cover and contact sheet are generated from the exact rendered
frame sequence by `build/make-review-assets.js`; historical assets are not
substituted. Human owner review remains required before publication.

## Rebuild

```powershell
# Record isolated clips with the deployed GUI.
.\media\promo-native\capture-live-demo.ps1 -GuiExecutable C:\RyzenAdj\amd-mobile-power-gui.exe -Mode simple -DemoType legacy -UiFixture preset-success
.\media\promo-native\capture-live-demo.ps1 -GuiExecutable C:\RyzenAdj\amd-mobile-power-gui.exe -Mode advanced -DemoType presets -UiFixture preset-success
.\media\promo-native\capture-live-demo.ps1 -GuiExecutable C:\RyzenAdj\amd-mobile-power-gui.exe -Mode advanced -DemoType policy -UiFixture preset-success
.\media\promo-native\capture-consent-flow.ps1 -GuiExecutable C:\RyzenAdj\amd-mobile-power-gui.exe
.\media\promo-native\capture-diagnostics-flow.ps1 -GuiExecutable C:\RyzenAdj\amd-mobile-power-gui.exe

# Update build/clips-1.0.42.json to the reviewed manifests, then render.
node .\media\promo-html\build\record.js `
  .\media\promo-html\index.html `
  .\artifacts\media\promo-1.0.42-review-final\frames `
  --clips-config .\media\promo-html\build\clips-1.0.42.json
```

Encode exactly the manifest frame count with FFmpeg, then run
`verify-demo-sync.js`, `review-layout.js`, `review-keyframes.js`, full decode,
and luminance screening. Do not substitute historical assets or reuse an old
video hash after changing copy, timing, or captures.

## Publication Gate

- Keep the simulated-data disclosure visible.
- Do not claim universal AMD support or a physical power-bank distinction.
- Do not add music without a suitable license and owner approval.
- No terminal, personal path, account name, notification, or unrelated desktop
  content may appear.
- The owner reviews pacing, subtitles, claims, and cover before any GitHub
  Release or authenticated Bilibili upload.
