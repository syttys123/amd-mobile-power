// Build a version-bound cover and contact sheet from rendered video frames.
const fs = require("fs");
const path = require("path");
const { chromium } = require("playwright");

const manifestPath = path.resolve(process.argv[2]);
const framesDir = path.resolve(process.argv[3]);
const outputDir = path.resolve(process.argv[4]);
const version = process.argv[5];
const buildDate = process.argv[6] || new Date().toISOString().slice(0, 10);
if (!version || !/^\d+\.\d+\.\d+(?:[-.][A-Za-z0-9]+)*$/.test(version)) {
  throw new Error("A package version is required");
}
const manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8").replace(/^\uFEFF/, ""));
if (manifest.Version !== version) throw new Error("Render/version mismatch");
fs.mkdirSync(outputDir, { recursive: true });

function frameData(frameIndex) {
  const file = path.join(framesDir, `frame-${String(frameIndex).padStart(5, "0")}.png`);
  return `data:image/png;base64,${fs.readFileSync(file).toString("base64")}`;
}

(async () => {
  const browser = await chromium.launch();
  try {
    const page = await browser.newPage({ viewport: { width: 1920, height: 1080 } });
    const coverFrame = Math.floor(1.75 * manifest.Fps);
    const coverPath = path.join(outputDir, `bilibili-cover-${version}-${buildDate}.png`);
    await page.setContent(`<body style="margin:0;background:#0b1216"><img src="${frameData(coverFrame)}" style="display:block;width:1920px;height:1080px"></body>`);
    await page.evaluate(() => document.images[0].decode());
    await page.screenshot({ path: coverPath });

    const samples = manifest.Scenes.map(scene => ({
      id: scene.id,
      seconds: scene.start + scene.duration / 2,
      frame: Math.floor((scene.start + scene.duration / 2) * manifest.Fps),
    }));
    const cells = samples.map(sample => `
      <figure>
        <img src="${frameData(sample.frame)}">
        <figcaption><b>${sample.id}</b><span>${sample.seconds.toFixed(1)} s</span></figcaption>
      </figure>`).join("");
    await page.setViewportSize({ width: 1920, height: 820 });
    await page.setContent(`<!doctype html><html><head><meta charset="utf-8"><style>
      *{box-sizing:border-box}body{margin:0;padding:42px;background:#0b1216;color:#f1f7f4;font-family:'Microsoft YaHei UI','Segoe UI',sans-serif}
      header{display:flex;justify-content:space-between;align-items:end;margin-bottom:28px}h1{font-size:38px;margin:0}p{font-size:20px;color:#a6b8b0;margin:8px 0 0}.version{font-size:24px;color:#45d6a8;font-weight:700}
      main{display:grid;grid-template-columns:repeat(4,1fr);gap:22px}figure{margin:0;background:#111b20;border:1px solid #2b3c42;border-radius:8px;overflow:hidden}img{display:block;width:100%;aspect-ratio:16/9;object-fit:contain}figcaption{height:58px;padding:14px 16px;display:flex;justify-content:space-between;font-size:18px}span{color:#a6b8b0}
      footer{margin-top:26px;color:#a6b8b0;font-size:18px;display:flex;justify-content:space-between}
    </style></head><body><header><div><h1>AMD Mobile Power · 宣传片审查联系表</h1><p>真实渲染帧 · 隔离模拟数据 · 无声字幕审查版</p></div><div class="version">${version}</div></header><main>${cells}</main><footer><span>1920×1080 · 30 fps · ${manifest.TotalSeconds.toFixed(1)} s · ${manifest.FrameCount} frames</span><span>尚未批准公开发布</span></footer></body></html>`);
    await page.evaluate(async () => { for (const image of document.images) await image.decode(); });
    const contactPath = path.join(outputDir, `native-promo-${version}-contact-sheet-${buildDate}.png`);
    await page.screenshot({ path: contactPath, fullPage: true });
    const result = {
      Verification: "PASS", Version: version, RenderManifest: manifestPath,
      Cover: coverPath, CoverFrame: coverFrame, ContactSheet: contactPath,
      Samples: samples,
      Scope: "Assets are copied/composed from the exact rendered frame sequence; visual approval remains separate",
    };
    fs.writeFileSync(path.join(outputDir, `review-assets-${version}.json`), JSON.stringify(result, null, 2) + "\n");
    console.log(JSON.stringify(result, null, 2));
  } finally {
    await browser.close();
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
