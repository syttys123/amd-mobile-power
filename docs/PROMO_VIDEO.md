# Promotional Video Draft

The current review cut is the 42.5-second 1.0.39 render generated from the
HTML/Playwright pipeline in `media/promo-html`. The main interaction scene is a
screen recording of the isolated 1.0.39 GUI; the consent dialog, advanced
policy panel, and device panel are isolated 1.0.39 captures. Only the pointer,
captions, and transitions are composited. Rendering and reviewing the video
never write power limits.

## Current Draft

- Duration: 42.5 seconds.
- Format: 1920x1080, 30 fps, H.264 video; current review render is silent.
- Size: 3,435,299 bytes.
- SHA256:
  `16376c332a9a944bf0e951beeed7ee163462393b727494990e6ce2cd470e4944`.
- Scenes: 7 (hook, three-preset explanation, live UI demo, auto policy, write
  unlock safety, compatibility/diagnostics, closing).
- Narration: none. Simplified-Chinese subtitles are burned into the video.
- Audio: none in the current review render.
- Status: `DRAFT_FOR_HUMAN_REVIEW`; not approved for upload.

Local render:

```text
artifacts/media/promo-1.0.39-review/amd-mobile-power-1.0.39-review-silent.mp4
```

Machine-readable evidence:
`docs/evidence/media/native-promo-1.0.39-review-2026-11-17.json`.

## Review Assets

Scene keyframes are under `artifacts/media/review-1.0.39-scenes/`. The full
luminance review is under
`artifacts/media/promo-1.0.39-review/luminance-review.json`.

## Verification

The evidence file records the video hash, codec, dimensions, frame rate,
duration, full-decode result, scene count, keyframe review and luminance
screening. Re-check a local file without editing it:

```powershell
ffprobe -v error -show_entries `
  format=duration,size -show_entries `
  stream=codec_name,width,height,r_frame_rate,sample_rate,channels `
  -of json artifacts\media\promo-1.0.39-review\amd-mobile-power-1.0.39-review-silent.mp4
ffmpeg -v error -i artifacts\media\promo-1.0.39-review\amd-mobile-power-1.0.39-review-silent.mp4 -f null -
Get-FileHash `
  artifacts\media\promo-1.0.39-review\amd-mobile-power-1.0.39-review-silent.mp4 `
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
