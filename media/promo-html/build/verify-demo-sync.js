// Multi-clip identity, event, pointer and claim gate for the review cut.
const fs = require("fs");
const path = require("path");
const crypto = require("crypto");

const renderPath = path.resolve(process.argv[2]);
const configPath = path.resolve(process.argv[3]);
const enginePath = path.resolve(process.argv[4]);
const scenesPath = path.resolve(process.argv[5]);
const outputPath = process.argv[6] ? path.resolve(process.argv[6]) : null;
const readJson = file => JSON.parse(fs.readFileSync(file, "utf8").replace(/^\uFEFF/, ""));
const sha256 = file => crypto.createHash("sha256").update(fs.readFileSync(file)).digest("hex");
const render = readJson(renderPath);
const config = readJson(configPath);
const engine = fs.readFileSync(enginePath, "utf8");
const scenes = fs.readFileSync(scenesPath, "utf8");
const errors = [];
const check = (condition, message) => { if (!condition) errors.push(message); };

const expectedVersion = process.env.PROMO_VERSION || "1.0.43";
check(render.Version === expectedVersion, `Render version must be ${expectedVersion}`);
check(config.Version === expectedVersion, `Config version must be ${expectedVersion}`);
check(render.GuiSha256 === config.GuiSha256, "GUI identity mismatch");
check(render.FrameCount === Math.ceil(render.TotalSeconds * render.Fps), "Frame count mismatch");
check(render.TotalSeconds >= 30 && render.TotalSeconds <= 70, "Review duration out of range");
const required = ["hook", "safety", "ui-demo", "presets", "auto-policy", "firmware", "compat", "closing"];
const ids = render.Scenes.map(scene => scene.id);
check(JSON.stringify(ids) === JSON.stringify(required), "Scene order mismatch");
check(ids.indexOf("safety") < ids.indexOf("ui-demo"), "Safety must precede writes");

for (const kind of ["consent", "simple", "presets", "policy", "diagnostics"]) {
  const clip = render.Clips?.[kind];
  check(Boolean(clip), `${kind}: render clip missing`);
  if (!clip) continue;
  const source = readJson(clip.ManifestPath);
  check(source.SimulatedData === true && source.HardwareAccess !== true,
    `${kind}: must be simulated and hardware-free`);
  const sourceGuiHash = source.GuiSha256 || source.GuiSHA256;
  check(clip.GuiSha256 === config.GuiSha256 && sourceGuiHash === config.GuiSha256,
    `${kind}: GUI hash mismatch`);
  check(clip.FrameCount === source.FrameCount, `${kind}: frame count mismatch`);
  check(source.Frames.every((frame, index) =>
    frame.Index === index && Number.isFinite(frame.At) &&
    (!index || frame.At > source.Frames[index - 1].At)),
  `${kind}: frame timestamps invalid`);
  const events = kind === "diagnostics" ? [source.Event] : source.Events;
  check(Array.isArray(events) && events.length > 0, `${kind}: events missing`);
  events.forEach((event, index) => {
    check(event.Completed === true, `${kind}: event ${index} incomplete`);
    check(event.VisualAt >= event.ActualAt, `${kind}: visual precedes action ${index}`);
    check(Number.isInteger(event.VisualFrameIndex) &&
      Math.abs(source.Frames[event.VisualFrameIndex].At - event.VisualAt) < 1e-6,
    `${kind}: visual frame binding ${index}`);
    check(event.ClickX >= 0 && event.ClickX <= 1 && event.ClickY >= 0 && event.ClickY <= 1,
      `${kind}: pointer bounds ${index}`);
    const rendered = clip.Events[index];
    check(rendered && Math.abs(rendered.VisualAt -
      (event.VisualAt - clip.ClipOffset)) < 1e-6,
    `${kind}: render event offset ${index}`);
    check(rendered && rendered.ClickX === event.ClickX && rendered.ClickY === event.ClickY,
      `${kind}: render pointer identity ${index}`);
  });
  if (kind === "simple") {
    check(source.Fixture === "preset-success", "simple: wrong fixture");
    check(events.length === 3 && events.every((event, index) =>
      event.Command === [102, 103, 101][index] &&
      event.ExpectedWatts === [25, 45, 10][index]), "simple: preset sequence mismatch");
    const scene = render.Scenes.find(item => item.id === "ui-demo");
    check(scene.duration >= Math.max(...clip.Events.map(event =>
      event.VisualAt + clip.LeadSeconds)) + 1, "simple: insufficient readback tail");
  }
  if (kind === "consent") {
    check(events.length === 2 && events[0].Control === 401 && events[1].Control === 402,
      "consent: checkbox/confirm sequence mismatch");
  }
  if (kind === "policy") {
    check(events.length === 8 && events.some(event =>
      event.Control === 318 || event.ControlId === 318),
      "policy: battery-only operation missing");
  }
  if (kind === "diagnostics") {
    check(source.Privacy?.containsLocalPaths === false &&
      source.Privacy?.containsAccountNames === false &&
      source.Privacy?.containsProcessIds === false &&
      source.Privacy?.uploaded === false, "diagnostics: privacy contract failed");
  }
}

const firmware = path.resolve(path.dirname(enginePath), "../assets/firmware-clamp-1.0.42-client.png");
check(fs.existsSync(firmware), "Firmware 1.0.42 asset missing");
const firmwareEvidence = readJson(path.resolve(path.dirname(enginePath),
  "../../../docs/evidence/ui/promo-1.0.42-clean-firmware-2026-11-18.json"));
check(firmwareEvidence.FixtureTargetWatts === 12 &&
  firmwareEvidence.FixtureApplyStatus.includes("固件限制"),
"Firmware evidence must show a requested 12 W clamp");
check(firmwareEvidence.Simple.Width === 752 && firmwareEvidence.Simple.Height === 489,
  "Firmware source capture dimensions changed");
check(fs.existsSync(path.resolve(path.dirname(enginePath),
  "../assets/firmware-clamp-1.0.42.png")), "Reviewed firmware source asset missing");
for (const banned of ["1.0.39", "Music:", "下载即用", "全 AMD 通用", "插拔自动切换"]) {
  check(!engine.includes(banned) && !scenes.includes(banned), `Misleading/stale copy: ${banned}`);
}
check(engine.includes("模拟数据"), "Simulated-data disclosure missing");
check(scenes.includes("默认只读"), "Read-only default disclosure missing");
check(scenes.includes("仅电池"), "Battery-only feature disclosure missing");
check(engine.includes("充电宝") || scenes.includes("充电宝"),
  "Power-bank limitation missing");
check(scenes.includes("一台 8845HS"), "Single-device compatibility limit missing");

const result = {
  Verification: errors.length ? "FAIL" : "PASS",
  Errors: errors,
  Version: render.Version,
  GuiSha256: render.GuiSha256,
  DurationSeconds: render.TotalSeconds,
  Frames: render.FrameCount,
  SceneOrder: ids,
  ClipKinds: Object.keys(render.Clips),
  FirmwareAssetSha256: sha256(firmware),
  Scope: "Identity, manifest/event/pointer bindings, claims and asset hash; visual review remains separate",
};
if (outputPath) fs.writeFileSync(outputPath, JSON.stringify(result, null, 2) + "\n");
console.log(JSON.stringify(result, null, 2));
if (errors.length) process.exitCode = 1;
