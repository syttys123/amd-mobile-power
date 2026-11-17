// Contract gate for the preset demo: the main clip must use the clean
// preset-success fixture, pointer clicks must bind to recorded visual-change
// frames, and the review copy must not reintroduce known misleading claims.
const fs = require("fs");

function readJson(file) {
  return JSON.parse(fs.readFileSync(file, "utf8").replace(/^\uFEFF/, ""));
}

const clip = readJson(process.argv[2]);
const render = readJson(process.argv[3]);
const engine = fs.readFileSync(process.argv[4], "utf8");
const scenesText = fs.readFileSync(process.argv[5], "utf8");
const errors = [];
const check = (condition, message) => { if (!condition) errors.push(message); };

check(clip.SimulatedData === true, "Clip must be simulated fixture data");
check(clip.Fixture === "preset-success", "Main demo must use preset-success");
check(render.Clip && render.Clip.Fixture === "preset-success", "Render must use preset-success");
check(Array.isArray(clip.Frames) && clip.Frames.length > 0, "Clip frames missing");
check(clip.Frames.every((frame, index) =>
  frame.Index === index && Number.isFinite(frame.At) &&
  (index === 0 || frame.At > clip.Frames[index - 1].At)), "Clip timestamps not monotonic");

const expected = [
  { command: 102, watts: 25 },
  { command: 103, watts: 45 },
  { command: 101, watts: 10 },
];
check(Array.isArray(clip.Events) && clip.Events.length === 3, "Expected three preset events");
clip.Events.forEach((event, index) => {
  const want = expected[index];
  check(event.Command === want.command && event.ExpectedWatts === want.watts,
    `Event ${index} preset mismatch`);
  check(event.Completed === true, `Event ${index} incomplete`);
  check(Number.isInteger(event.VisualFrameIndex) &&
    event.VisualFrameIndex >= 0 && event.VisualFrameIndex < clip.Frames.length,
    `Event ${index} visual frame out of range`);
  check(Math.abs(clip.Frames[event.VisualFrameIndex].At - event.VisualAt) < 1e-6,
    `Event ${index} visual timestamp mismatch`);
  check(event.VisualAt >= event.ActualAt, `Event ${index} visual precedes command`);
  check(event.ClickX >= 0 && event.ClickX <= 1 && event.ClickY >= 0 && event.ClickY <= 1,
    `Event ${index} click point out of bounds`);
});

if (render.Clip) {
  const lead = render.Clip.LeadSeconds;
  clip.Events.forEach((event, index) => {
    check(Math.abs(render.Clip.ClickTimes[index] - (event.VisualAt + lead)) < 1e-6,
      `Render click ${index} not bound to visual frame`);
    check(Math.abs(render.Clip.ClickPoints[index].x - event.ClickX) < 1e-9 &&
      Math.abs(render.Clip.ClickPoints[index].y - event.ClickY) < 1e-9,
      `Render click ${index} point mismatch`);
  });
}

const ids = render.Scenes.map(scene => scene.id);
const required = ["hook", "safety", "ui-demo", "firmware", "auto-policy", "compat", "closing"];
check(required.every(id => ids.includes(id)), "Missing required scene");
check(ids.indexOf("safety") < ids.indexOf("ui-demo"), "Safety must precede the write demo");
check(ids.indexOf("firmware") > ids.indexOf("ui-demo"), "Firmware caveat must follow the clean demo");
const uiScene = render.Scenes.find(scene => scene.id === "ui-demo");
const lastClick = Math.max(...render.Clip.ClickTimes);
check(uiScene && uiScene.duration >= lastClick + 1.0, "Demo ends too soon after the last click");

const banned = [
  "目标已写入，但固件回读低于请求值",
  "Music: Deliberate Thought",
  "下载即用",
  "全自动",
  "ONE-CLICK PRESETS",
];
for (const text of banned) {
  check(!engine.includes(text) && !scenesText.includes(text), `Misleading copy present: ${text}`);
}
check(engine.includes("模拟数据"), "Simulated-data disclosure missing");
check(scenesText.includes("默认只读"), "Read-only default disclosure missing");
check(scenesText.includes("解锁后"), "Auto-policy unlock prerequisite missing");

const result = {
  Verification: errors.length ? "FAIL" : "PASS",
  Errors: errors,
  ClipFixture: clip.Fixture,
  ClickTimes: render.Clip ? render.Clip.ClickTimes : null,
  ClickPoints: render.Clip ? render.Clip.ClickPoints : null,
  SceneOrder: ids,
  DurationSeconds: render.TotalSeconds,
};
if (process.argv[6]) {
  fs.writeFileSync(process.argv[6], JSON.stringify(result, null, 2) + "\n", "utf8");
}
console.log(JSON.stringify(result, null, 2));
if (errors.length) process.exit(1);
