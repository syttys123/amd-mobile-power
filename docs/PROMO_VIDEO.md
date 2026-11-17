# Promotional Video Draft

The current review cut is the 39.5-second v2 render generated from the
HTML/Playwright pipeline in `media/promo-html`. The main preset interaction is
a screen recording of an isolated development fixture GUI running the
hardware-free `preset-success` fixture; the consent dialog, advanced policy
panel, and device panel are isolated 1.0.39 captures. Only the pointer,
captions, and transitions are composited. Rendering and reviewing the video
never write power limits.

This v2 cut supersedes the earlier `promo-1.0.39-review` render. That first
1.0.39 review mixed the `firmware-clamp` fixture into the main preset demo (so
25/45 W clicks still showed a 10 W STAPM ceiling), assumed uniform clip-frame
pointer timing, and carried a false music credit. The firmware limitation is
now a separate scene, the pointer is bound to recorded visual-change frames,
and the music credit was removed.

## Current Draft

- Duration: 39.5 seconds (exactly 1185 frames).
- Format: 1920x1080, 30 fps, H.264 video; silent review render.
- Size: 3,382,806 bytes.
- SHA256:
  `99d618749ac31b965681b3d964cc37b0b9ff4255ffc67838d0a713ac5760d82c`.
- Scenes: 7, in order: hook, safety, ui-demo, firmware, auto-policy, compat,
  closing.
- Narration: none. Simplified-Chinese subtitles are burned into the video.
- Audio: none in the current review render.
- Status: `DRAFT_FOR_HUMAN_REVIEW`; not approved for upload.

Local render:

```text
artifacts/media/promo-review-20261117-v2/amd-mobile-power-review-v2-silent.mp4
```

Machine-readable evidence:
`docs/evidence/media/native-promo-review-v2-2026-11-17.json`.

The main preset demo uses the `preset-success` fixture: clicking 25 / 45 / 10 W
reads back 25/25/25, 45/45/45 and 10/10/10 W with no firmware clamp, while
current draw stays below the requested cap. Pointer clicks are bound to
recorded visual-change frames and actual button centers
(`demo-sync-review.json`, PASS). The separate firmware scene uses the
`firmware-clamp` fixture. All GUI captures use a development fixture build with
an isolated single-instance mutex, not the deployed `C:\RyzenAdj` 1.0.39
package; the data is simulated and no hardware is touched. The auto-policy
scene states the write-unlock prerequisite and notes that power banks are
usually seen as external power.

## Review Assets

Scene keyframes are under
`artifacts/media/promo-review-20261117-v2/keyframes`. Click before/click/after
GUI crops are under `artifacts/media/promo-review-20261117-v2/click-crops`.
The luminance screens are
`artifacts/media/promo-review-20261117-v2/luminance-review.json` (whole frame)
and `artifacts/media/promo-review-20261117-v2/luminance-gui-region-review.json`
(GUI region); both report no isolated spikes or near-white frames. These are
downscaled luminance heuristics, not proof of absence of local flicker.

## Verification

The evidence file records the video hash, codec, dimensions, frame rate,
duration, full-decode result, scene count, demo-sync contract, keyframe
review, visual crop review and luminance screening. Re-check a local file
without editing it:

```powershell
ffprobe -v error -show_entries `
  format=duration,size -show_entries `
  stream=codec_name,width,height,r_frame_rate,sample_rate,channels `
  -of json artifacts\media\promo-review-20261117-v2\amd-mobile-power-review-v2-silent.mp4
ffmpeg -v error -i artifacts\media\promo-review-20261117-v2\amd-mobile-power-review-v2-silent.mp4 -f null -
Get-FileHash `
  artifacts\media\promo-review-20261117-v2\amd-mobile-power-review-v2-silent.mp4 `
  -Algorithm SHA256
```

The full decode must produce no output and exit with code 0.

## Rebuild Notes

The HTML pipeline lives in `media/promo-html`:

- `index.html` and `src/scenes.js` define scene order, durations, and subtitle
  text.
- `build/record.js` drives Chromium through Playwright and records frames.
- The current review render is silent; audio can be added after owner review.
- Frames are encoded with FFmpeg; the historical working files stay under the
  ignored `media/promo-html/build` directory.

## Review Gate

- The video is labelled as a development preview.
- It states that only one physical AMD laptop has full evidence.
- It does not claim universal AMD laptop support.
- It does not imply that development builds are ready for unsupervised writes.
- No terminal, personal path, account name, notification, or unrelated desktop
  content appears.
- The project owner reviews pacing, subtitles, audio, claims, and cover before
  any authenticated upload.
