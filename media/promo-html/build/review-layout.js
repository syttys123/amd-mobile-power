// DOM bounds and contrast-oriented layout gate for every storyboard scene.
const { chromium } = require("playwright");
const fs = require("fs");
const path = require("path");
const { pathToFileURL } = require("url");

const output = path.resolve(process.argv[2]);
const configPath = path.resolve(process.argv[3]);
const config = JSON.parse(fs.readFileSync(configPath, "utf8").replace(/^\uFEFF/, ""));
const posters = {};
const clips = {};
for (const [kind, entry] of Object.entries(config.Clips)) {
  const manifestPath = path.resolve(path.dirname(configPath), entry.Manifest);
  const manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8").replace(/^\uFEFF/, ""));
  const directory = path.resolve(entry.FrameDirectory || manifest.FrameDirectory);
  const first = fs.readdirSync(directory).filter(name => /^frame-\d+\.png$/.test(name)).sort()[0];
  posters[kind] = `data:image/png;base64,${fs.readFileSync(path.join(directory, first)).toString("base64")}`;
  const events = kind === "diagnostics" ? [manifest.Event] : manifest.Events;
  clips[kind] = {
    Events: events.map(event => ({
      ...event, VisualAt: event.VisualAt - (entry.ClipOffset || 0),
    })),
    LeadSeconds: entry.LeadSeconds ?? 0.35,
  };
}

(async () => {
  const browser = await chromium.launch();
  try {
    const page = await browser.newPage({ viewport: { width: 1920, height: 1080 } });
    await page.goto(pathToFileURL(path.resolve(__dirname, "../index.html")).href);
    await page.evaluate(({ posters, clips }) => {
      window.__POSTERS__ = posters;
      window.__CLIPS__ = clips;
    }, { posters, clips });
    const scenes = await page.evaluate(() => window.__timeline);
    const results = [];
    for (const scene of scenes) {
      for (const fraction of [0.12, 0.5, 0.88]) {
        const time = scene.start + scene.duration * fraction;
        await page.evaluate(seconds => window.__seek(seconds), time);
        await page.evaluate(async () => {
          for (const image of document.images) await image.decode();
        });
        const audit = await page.evaluate(() => {
          const leaves = [...document.querySelectorAll("#root div")]
            .filter(node => node.children.length === 0 && node.textContent.trim());
          const overflow = leaves.map(node => {
            const rect = node.getBoundingClientRect();
            return {
              text: node.textContent,
              left: rect.left, top: rect.top, right: rect.right, bottom: rect.bottom,
              horizontal: node.scrollWidth > Math.ceil(rect.width) + 1,
              vertical: node.scrollHeight > Math.ceil(rect.height) + 1,
            };
          }).filter(item => item.horizontal || item.vertical ||
            item.left < -1 || item.top < -1 || item.right > 1921 || item.bottom > 1081);
          const images = [...document.images].map(image => ({
            id: image.id, naturalWidth: image.naturalWidth,
            naturalHeight: image.naturalHeight,
            complete: image.complete,
          })).filter(image => !image.complete || !image.naturalWidth);
          return { overflow, images };
        });
        results.push({ scene: scene.id, seconds: time, ...audit });
      }
    }
    const failures = results.filter(item => item.overflow.length || item.images.length);
    const report = {
      Verification: failures.length ? "FAIL" : "PASS",
      Scope: "DOM text/image bounds at three points per scene; pixel review is separate",
      Samples: results.length,
      Failures: failures,
    };
    fs.mkdirSync(path.dirname(output), { recursive: true });
    fs.writeFileSync(output, JSON.stringify(report, null, 2) + "\n");
    console.log(JSON.stringify(report));
    if (failures.length) process.exitCode = 1;
  } finally {
    await browser.close();
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
