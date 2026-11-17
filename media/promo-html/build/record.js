// Frame-exact Playwright recorder for the promo HTML timeline.
// Usage:
//   node record.js <html-path> <frames-dir> [--fps 30] [--width 1920]
//       [--height 1080] [--clip-frames <dir>] [--clip-scene ui-demo]
//           [--clip-fps 30] [--clip-lead 0.4] [--clip-manifest <json>]
//           [--clip-events <json>]
// Captures one PNG per frame and writes a ffmpeg concat file.
// When --clip-frames is given, frames extracted from the recorded GUI demo
// clip (clip-%04d.png or frame-%04d.png) are injected into the named scene's
// #live-demo-frame <img> element. With --clip-manifest, injection follows the
// captured per-frame timestamps and the synthetic pointer uses the recorded
// button centers and first visual-change frames instead of assuming uniform
// frame timing.

const { chromium } = require("playwright");
const fs = require("fs");
const path = require("path");

function arg(name, fallback) {
  const i = process.argv.indexOf(name);
  return i === -1 ? fallback : process.argv[i + 1];
}

const htmlPath = path.resolve(process.argv[2]);
const framesDir = path.resolve(process.argv[3]);
const fps = parseInt(arg("--fps", "30"), 10);
const width = parseInt(arg("--width", "1920"), 10);
const height = parseInt(arg("--height", "1080"), 10);
const clipFramesDir = arg("--clip-frames", null);
const clipSceneId = arg("--clip-scene", "ui-demo");
const clipFps = parseInt(arg("--clip-fps", "30"), 10);
const clipLead = parseFloat(arg("--clip-lead", "0.4"));
const clipEventsPath = arg("--clip-events", null);
const clipManifestPath = arg("--clip-manifest", null);

(async () => {
  fs.mkdirSync(framesDir, { recursive: true });

  let clipFrames = [];
  if (clipFramesDir) {
    clipFrames = fs
      .readdirSync(clipFramesDir)
      .filter((f) => /^(clip|frame)-\d+\.png$/i.test(f))
      .sort();
    if (clipFrames.length === 0) {
      throw new Error(`No clip frames in ${clipFramesDir}`);
    }
  }

  let clipManifest = null;
  let clipFrameTimes = null;
  let clickTimes = null;
  let clickPoints = null;
  const expectedCommands = [102, 103, 101];
  const expectedWatts = [25, 45, 10];

  if (clipManifestPath) {
    clipManifest = JSON.parse(
      fs.readFileSync(path.resolve(clipManifestPath), "utf8").replace(/^\uFEFF/, "")
    );
    if (!clipManifest.SimulatedData || clipManifest.Fixture !== "preset-success") {
      throw new Error("The main preset demo requires the preset-success fixture");
    }
    if (!Number.isFinite(clipManifest.ClientWidth) || clipManifest.ClientWidth <= 0 ||
        !Number.isFinite(clipManifest.ClientHeight) || clipManifest.ClientHeight <= 0) {
      throw new Error("Clip manifest is missing the captured client size");
    }
    if (!Array.isArray(clipManifest.Frames) || clipManifest.Frames.length !== clipFrames.length) {
      throw new Error("Clip manifest frame count does not match the frame directory");
    }
    clipFrameTimes = clipManifest.Frames.map((frame, index) => {
      if (frame.Index !== index || frame.Path !== clipFrames[index] ||
          !Number.isFinite(frame.At) || frame.At < 0 ||
          (index > 0 && frame.At <= clipManifest.Frames[index - 1].At)) {
        throw new Error(`Invalid clip manifest frame ${index}`);
      }
      return frame.At;
    });
    const events = clipManifest.Events;
    if (!Array.isArray(events) || events.length !== 3 ||
        events.some((event, index) =>
          event.Completed !== true ||
          event.Command !== expectedCommands[index] ||
          event.ExpectedWatts !== expectedWatts[index] ||
          !Number.isFinite(event.ActualAt) || event.ActualAt < 0 ||
          !Number.isInteger(event.VisualFrameIndex) ||
          event.VisualFrameIndex < 0 || event.VisualFrameIndex >= clipFrameTimes.length ||
          Math.abs(clipFrameTimes[event.VisualFrameIndex] - event.VisualAt) > 1e-6 ||
          event.VisualAt < event.ActualAt ||
          !Number.isFinite(event.ClickX) || event.ClickX < 0 || event.ClickX > 1 ||
          !Number.isFinite(event.ClickY) || event.ClickY < 0 || event.ClickY > 1 ||
          (index > 0 && event.ActualAt <= events[index - 1].ActualAt))) {
      throw new Error("Invalid recorded preset events in clip manifest");
    }
    clickTimes = events.map((event) => event.VisualAt + clipLead);
    clickPoints = events.map((event) => ({ x: event.ClickX, y: event.ClickY }));
  } else if (clipEventsPath) {
    const evidence = JSON.parse(
      fs.readFileSync(path.resolve(clipEventsPath), "utf8").replace(/^\uFEFF/, "")
    );
    const events = evidence.Events;
    if (!evidence.SimulatedData || evidence.Fixture !== "preset-success" ||
        !Array.isArray(events) || events.length !== 3 ||
        events.some((event, index) => event.Completed !== true ||
          event.Command !== expectedCommands[index] ||
          !Number.isFinite(event.ActualAt) || event.ActualAt < 0 ||
          (index > 0 && event.ActualAt <= events[index - 1].ActualAt))) {
      throw new Error("Invalid recorded preset events");
    }
    clickTimes = events.map((event) => event.ActualAt + clipLead);
  }

  if (clipFrames.length > 0 && clipSceneId === "ui-demo" && !clickTimes) {
    throw new Error("The ui-demo scene requires --clip-manifest or --clip-events");
  }

  const browser = await chromium.launch();
  try {
  const page = await browser.newPage({ viewport: { width, height } });
  await page.goto(`file:///${htmlPath.replace(/\\/g, "/")}`);
  await page.waitForFunction(() => typeof window.__totalDuration === "function");
  if (clickTimes) {
    await page.evaluate(({ times, points, clientSize }) => {
      window.__PRESET_CLICK_TIMES__ = times;
      if (points) window.__PRESET_CLICK_POINTS__ = points;
      if (clientSize) window.__CLIP_CLIENT_SIZE__ = clientSize;
    }, {
      times: clickTimes,
      points: clickPoints,
      clientSize: clipManifest ? {
        width: clipManifest.ClientWidth,
        height: clipManifest.ClientHeight,
      } : null,
    });
  }

  const total = await page.evaluate(() => window.__totalDuration());
  const scenes = await page.evaluate(() => window.__SCENES__);
  const frameCount = Math.ceil(total * fps);
  console.log(
    JSON.stringify({ total, fps, frameCount, width, height, clipFrames: clipFrames.length })
  );

  // Locate the clip scene's time window.
  let clipStart = null;
  let clipEnd = null;
  if (clipFrames.length > 0) {
    let cursor = 0;
    for (const scene of scenes) {
      if (scene.id === clipSceneId) {
        clipStart = cursor;
        clipEnd = cursor + scene.duration;
        break;
      }
      cursor += scene.duration;
    }
    if (clipStart === null) {
      throw new Error(`Scene ${clipSceneId} not found in storyboard`);
    }
    if (clipManifest) {
      const sceneDuration = clipEnd - clipStart;
      if (sceneDuration - clipLead > clipManifest.DurationSeconds) {
        throw new Error("Clip manifest is shorter than the ui-demo scene");
      }
      if (clickTimes.some((time) => time < 0 || time >= sceneDuration)) {
        throw new Error("Recorded click times fall outside the ui-demo scene");
      }
    }
  }

  const concatLines = [];
  const frameDuration = 1 / fps;

  // Cache clip frames as data URLs up front: the scene renderer wipes the
  // DOM on every seek, so the <img> must be re-populated every single frame.
  const clipDataUrls = clipFrames.map((f) => {
    const png = fs.readFileSync(path.join(clipFramesDir, f));
    return `data:image/png;base64,${png.toString("base64")}`;
  });

  for (let i = 0; i < frameCount; i++) {
    const t = i * frameDuration;
    await page.evaluate((s) => window.__seek(s), t);

    if (clipStart !== null && t >= clipStart && t < clipEnd) {
      const clipTime = t - clipStart - clipLead;
      let clipIndex = 0;
      if (clipFrameTimes) {
        for (let j = 0; j < clipFrameTimes.length; j++) {
          if (clipFrameTimes[j] <= clipTime + 1e-9) clipIndex = j;
          else break;
        }
      } else {
        clipIndex = Math.max(
          0,
          Math.min(clipFrames.length - 1, Math.floor(clipTime * clipFps))
        );
      }
      await page.evaluate((src) => {
        const img = document.getElementById("live-demo-frame");
        if (img) img.src = src;
      }, clipDataUrls[clipIndex]);
      await page.evaluate(() => {
        const img = document.getElementById("live-demo-frame");
        if (!img) throw new Error("Demo frame element missing");
        return img.decode();
      });
    }

    await page.evaluate(async () => {
      await Promise.all(Array.from(document.images).map(async image => {
        if (!image.getAttribute("src")) return;
        await image.decode();
        if (!image.naturalWidth) throw new Error("Rendered image has no pixels");
      }));
    });

    const name = `frame-${String(i).padStart(5, "0")}.png`;
    const file = path.join(framesDir, name);
    await page.screenshot({ path: file, type: "png" });
    concatLines.push(`file '${name}'`);
    concatLines.push(`duration ${frameDuration.toFixed(6)}`);
    if (i % 60 === 0) {
      process.stdout.write(`\rframe ${i}/${frameCount}`);
    }
  }
  // concat demuxer needs the last file repeated without a duration line.
  const lastName = `frame-${String(frameCount - 1).padStart(5, "0")}.png`;
  concatLines.push(`file '${lastName}'`);

  fs.writeFileSync(
    path.join(framesDir, "concat.txt"),
    concatLines.join("\n") + "\n",
    "utf8"
  );
  fs.writeFileSync(
    path.join(framesDir, "render-manifest.json"),
    JSON.stringify({
      SchemaVersion: 1,
      Fps: fps,
      FrameCount: frameCount,
      TotalSeconds: total,
      Width: width,
      Height: height,
      Scenes: scenes,
      Clip: clipManifest ? {
        ManifestPath: path.resolve(clipManifestPath),
        Fixture: clipManifest.Fixture,
        FrameCount: clipFrames.length,
        LeadSeconds: clipLead,
        ClickTimes: clickTimes,
        ClickPoints: clickPoints,
        FrameTimes: clipFrameTimes,
        ClientWidth: clipManifest.ClientWidth,
        ClientHeight: clipManifest.ClientHeight,
      } : null,
      RecordedAt: new Date().toISOString(),
    }, null, 2) + "\n",
    "utf8"
  );

  console.log(`\nDone. ${frameCount} frames -> ${framesDir}`);
  } finally { await browser.close(); }
})().catch((err) => {
  console.error(err);
  process.exit(1);
});
