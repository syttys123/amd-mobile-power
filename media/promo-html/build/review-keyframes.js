// Review representative frames from the actual rendered PNG sequence. This
// checks decoded output rather than re-rendering a potentially different DOM.
const fs = require("fs");
const path = require("path");
const { chromium } = require("playwright");

const framesDir = path.resolve(process.argv[2]);
const manifestPath = path.resolve(process.argv[3]);
const outputDir = path.resolve(process.argv[4]);
const manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8").replace(/^\uFEFF/, ""));
fs.mkdirSync(outputDir, { recursive: true });

(async () => {
  const browser = await chromium.launch();
  try {
    const page = await browser.newPage({ viewport: { width: manifest.Width, height: manifest.Height } });
    const results = [];
    for (const scene of manifest.Scenes) {
      const samples = [0.12, 0.5, 0.88].map(fraction =>
        Math.min(manifest.FrameCount - 1,
          Math.floor((scene.start + scene.duration * fraction) * manifest.Fps)));
      for (const frameIndex of samples) {
        const file = path.join(framesDir, `frame-${String(frameIndex).padStart(5, "0")}.png`);
        const source = `data:image/png;base64,${fs.readFileSync(file).toString("base64")}`;
        await page.setContent(`<body style="margin:0"><img src="${source}" style="display:block;width:${manifest.Width}px;height:${manifest.Height}px"></body>`);
        await page.evaluate(() => document.images[0].decode());
        const name = `${scene.id}-${String(frameIndex).padStart(5, "0")}.png`;
        await page.screenshot({ path: path.join(outputDir, name) });
        results.push({ scene: scene.id, frameIndex, seconds: frameIndex / manifest.Fps, file: name });
      }
    }
    fs.writeFileSync(path.join(outputDir, "review.json"), JSON.stringify({
      Verification: "PASS",
      Scope: "Rendered-frame extraction; human/agent visual inspection is recorded separately",
      Frames: results,
    }, null, 2) + "\n");
    console.log(JSON.stringify({ Verification: "PASS", Samples: results.length }));
  } finally {
    await browser.close();
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
