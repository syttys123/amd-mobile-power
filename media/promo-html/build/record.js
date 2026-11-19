// Frame-exact multi-clip recorder. Every clip is bound to its own manifest;
// no uniform-frame assumption or synthetic success state is allowed.
const { chromium } = require("playwright");
const fs = require("fs");
const path = require("path");

function arg(name, fallback) {
  const index = process.argv.indexOf(name);
  return index === -1 ? fallback : process.argv[index + 1];
}

const htmlPath = path.resolve(process.argv[2]);
const framesDir = path.resolve(process.argv[3]);
const configPath = path.resolve(arg("--clips-config", ""));
const fps = Number(arg("--fps", "30"));
const width = Number(arg("--width", "1920"));
const height = Number(arg("--height", "1080"));
if (!fs.existsSync(configPath)) throw new Error("--clips-config is required");

function readJson(file) {
  return JSON.parse(fs.readFileSync(file, "utf8").replace(/^\uFEFF/, ""));
}

function dataUrl(file) {
  return `data:image/png;base64,${fs.readFileSync(file).toString("base64")}`;
}

function frameFiles(directory) {
  return fs.readdirSync(directory)
    .filter(name => /^(frame|clip)-\d+\.png$/i.test(name)).sort();
}

function validateManifest(manifest, files, kind) {
  if (!manifest.SimulatedData || manifest.HardwareAccess === true) {
    throw new Error(`${kind}: fixture must be simulated and hardware-free`);
  }
  if (!Array.isArray(manifest.Frames) || manifest.Frames.length !== files.length) {
    throw new Error(`${kind}: frame count mismatch`);
  }
  manifest.Frames.forEach((frame, index) => {
    if (frame.Index !== index || frame.Path !== files[index] ||
        !Number.isFinite(frame.At) || frame.At < 0 ||
        (index && frame.At <= manifest.Frames[index - 1].At)) {
      throw new Error(`${kind}: invalid frame ${index}`);
    }
  });
  const events = kind === "diagnostics" ? [manifest.Event] : manifest.Events;
  if (!Array.isArray(events) || !events.length) throw new Error(`${kind}: events missing`);
  events.forEach((event, index) => {
    if (event.Completed !== true || !Number.isFinite(event.ActualAt) ||
        !Number.isInteger(event.VisualFrameIndex) ||
        event.VisualFrameIndex < 0 || event.VisualFrameIndex >= files.length ||
        Math.abs(manifest.Frames[event.VisualFrameIndex].At - event.VisualAt) > 1e-6 ||
        event.VisualAt < event.ActualAt ||
        !Number.isFinite(event.ClickX) || event.ClickX < 0 || event.ClickX > 1 ||
        !Number.isFinite(event.ClickY) || event.ClickY < 0 || event.ClickY > 1 ||
        (index && event.ActualAt <= events[index - 1].ActualAt)) {
      throw new Error(`${kind}: invalid event ${index}`);
    }
  });
  return events;
}

(async () => {
  fs.mkdirSync(framesDir, { recursive: true });
  const config = readJson(configPath);
  const clips = {};
  const posters = {};
  for (const [kind, entry] of Object.entries(config.Clips)) {
    const manifestPath = path.resolve(path.dirname(configPath), entry.Manifest);
    const manifest = readJson(manifestPath);
    const directory = path.resolve(entry.FrameDirectory || manifest.FrameDirectory);
    const files = frameFiles(directory);
    const events = validateManifest(manifest, files, kind);
    if (kind === "simple" && (manifest.Fixture !== "preset-success" ||
        events.length !== 3 || events.some((event, index) =>
          event.Command !== [102, 103, 101][index] ||
          event.ExpectedWatts !== [25, 45, 10][index]))) {
      throw new Error("simple: expected clean 25/45/10 W preset-success events");
    }
    if (kind === "consent" && (manifest.Flow !== "consent-unlock" ||
        events.length !== 2 || events[0].Control !== 401 || events[1].Control !== 402)) {
      throw new Error("consent: expected checkbox then confirm flow");
    }
    if (kind === "policy" && (manifest.DemoType !== "policy" || events.length !== 8)) {
      throw new Error("policy: expected eight-step dual-line/battery-only flow");
    }
    if (kind === "presets" && (manifest.DemoType !== "presets" || events.length !== 6)) {
      throw new Error("presets: expected six-step edit/save/apply flow");
    }
    if (kind === "diagnostics" && (manifest.Flow !== "diagnostics-export" ||
        manifest.Privacy?.containsLocalPaths !== false ||
        manifest.Privacy?.containsAccountNames !== false ||
        manifest.Privacy?.containsProcessIds !== false ||
        manifest.Privacy?.uploaded !== false)) {
      throw new Error("diagnostics: export/privacy contract failed");
    }
    const lead = Number(entry.LeadSeconds ?? 0.35);
    clips[kind] = {
      kind, manifestPath, directory, files,
      times: manifest.Frames.map(frame => frame.At),
      urls: files.map(file => dataUrl(path.join(directory, file))),
      Events: events.map(event => ({
        ...event, VisualAt: event.VisualAt - (entry.ClipOffset || 0),
      })),
      LeadSeconds: lead,
      ClientWidth: manifest.ClientWidth,
      ClientHeight: manifest.ClientHeight,
      Fixture: manifest.Fixture,
      GuiSha256: manifest.GuiSha256 || manifest.GuiSHA256,
      ClipOffset: entry.ClipOffset || 0,
      ClipEnd: entry.ClipEnd || null,
    };
    posters[kind] = clips[kind].urls[0];
  }

  const browser = await chromium.launch();
  try {
    const page = await browser.newPage({ viewport: { width, height } });
    await page.goto(`file:///${htmlPath.replace(/\\/g, "/")}`);
    await page.waitForFunction(() => typeof window.__totalDuration === "function");
    await page.evaluate(({ clips: metadata, posters: images, version }) => {
      window.__CLIPS__ = metadata;
      window.__POSTERS__ = images;
      window.__VERSION__ = version;
    }, {
      clips: Object.fromEntries(Object.entries(clips).map(([kind, clip]) => [kind, {
        Events: clip.Events, LeadSeconds: clip.LeadSeconds,
        ClientWidth: clip.ClientWidth, ClientHeight: clip.ClientHeight,
      }])),
      posters,
      version: config.Version,
    });
    const total = await page.evaluate(() => window.__totalDuration());
    const scenes = await page.evaluate(() => window.__timeline);
    const frameCount = Math.ceil(total * fps);
    const concat = [];
    for (let index = 0; index < frameCount; index++) {
      const time = index / fps;
      await page.evaluate(seconds => window.__seek(seconds), time);
      const scene = scenes.find(item => time >= item.start && time < item.end) || scenes.at(-1);
      if (scene.clip) {
        const clip = clips[scene.clip];
        const local = time - scene.start + (scene.clipOffset || 0);
        if (scene.clipEnd && local > scene.clipEnd) {
          throw new Error(`${scene.id}: clip end exceeded`);
        }
        let clipIndex = 0;
        for (let j = 0; j < clip.times.length; j++) {
          if (clip.times[j] <= local + 1e-9) clipIndex = j;
          else break;
        }
        const id = `${scene.clip}-frame`;
        await page.evaluate(({ id, source }) => {
          const image = document.getElementById(id);
          if (!image) throw new Error(`Missing frame element ${id}`);
          image.src = source;
        }, { id, source: clip.urls[clipIndex] });
      }
      await page.evaluate(async () => {
        for (const image of document.images) {
          if (!image.getAttribute("src")) throw new Error("Empty image source");
          await image.decode();
          if (!image.naturalWidth) throw new Error("Image has no pixels");
        }
      });
      const name = `frame-${String(index).padStart(5, "0")}.png`;
      await page.screenshot({ path: path.join(framesDir, name), type: "png" });
      concat.push(`file '${name}'`, `duration ${(1 / fps).toFixed(6)}`);
      if (index % 60 === 0) process.stdout.write(`\rframe ${index}/${frameCount}`);
    }
    concat.push(`file 'frame-${String(frameCount - 1).padStart(5, "0")}.png'`);
    fs.writeFileSync(path.join(framesDir, "concat.txt"), concat.join("\n") + "\n");
    fs.writeFileSync(path.join(framesDir, "render-manifest.json"), JSON.stringify({
      SchemaVersion: 2,
      Version: config.Version,
      GuiSha256: config.GuiSha256,
      Fps: fps, Width: width, Height: height,
      TotalSeconds: total, FrameCount: frameCount, Scenes: scenes,
      Clips: Object.fromEntries(Object.entries(clips).map(([kind, clip]) => [kind, {
        ManifestPath: clip.manifestPath,
        FrameDirectory: clip.directory,
        Fixture: clip.Fixture,
        GuiSha256: clip.GuiSha256,
        FrameCount: clip.files.length,
        LeadSeconds: clip.LeadSeconds,
        ClipOffset: clip.ClipOffset,
        ClipEnd: clip.ClipEnd,
        Events: clip.Events,
      }])),
      RecordedAt: new Date().toISOString(),
    }, null, 2) + "\n");
    console.log(`\nDone. ${frameCount} frames -> ${framesDir}`);
  } finally {
    await browser.close();
  }
})().catch(error => {
  console.error(error);
  process.exitCode = 1;
});
