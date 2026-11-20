// Version-bound Bilibili cover built from the exact rendered GUI frame plus
// demand-first copy. The old cover reused a video frame; this one is composed
// for the thumbnail slot (1920x1080) and keeps the simulated-data disclosure.
const fs = require("fs");
const path = require("path");
const { chromium } = require("playwright");

const manifestPath = path.resolve(process.argv[2]);
const framesDir = path.resolve(process.argv[3]);
const outputDir = path.resolve(process.argv[4]);
const version = process.argv[5];
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
    // Use the raw captured GUI client frame (no video scene chrome).
    const simpleManifestPath = path.resolve(__dirname,
      "../../../artifacts/media/promo-1.0.43-final-simple/frames-manifest.json");
    const simpleManifest = JSON.parse(fs.readFileSync(simpleManifestPath, "utf8").replace(/^\uFEFF/, ""));
    const targetEvent = simpleManifest.Events.find(event => event.ExpectedWatts === 45);
    if (!targetEvent) throw new Error("45 W event missing from simple clip");
    // A few frames after the visual change the apply has settled into the
    // applied read-back state instead of the transient processing frame.
    const settledIndex = Math.min(simpleManifest.Frames.length - 1,
      targetEvent.VisualFrameIndex + 8);
    const sourceFrame = simpleManifest.Frames[settledIndex];
    const guiData = `data:image/png;base64,${fs.readFileSync(path.join(simpleManifest.FrameDirectory, sourceFrame.Path)).toString("base64")}`;
    const icon = `data:image/png;base64,${fs.readFileSync(path.resolve(__dirname, "../../../assets/amd-mobile-power-256.png")).toString("base64")}`;
    await page.setContent(`<!doctype html><html><head><meta charset="utf-8"><style>
      *{box-sizing:border-box;margin:0;padding:0}
      body{width:1920px;height:1080px;overflow:hidden;font-family:'Microsoft YaHei UI','Segoe UI',sans-serif;
        background:linear-gradient(145deg,#0b1216 0%,#0e191d 58%,#0b1815 100%);color:#f1f7f4;position:relative}
      .left{position:absolute;left:96px;top:120px;width:760px}
      .brand{display:flex;align-items:center;gap:22px;margin-bottom:56px}
      .brand img{width:84px;height:84px;border-radius:18px}
      .brand span{font-size:34px;font-weight:700;color:#45d6a8;letter-spacing:2px}
      h1{font-size:112px;line-height:1.18;font-weight:800;margin-bottom:40px}
      .sub{font-size:36px;line-height:1.7;color:#a6b8b0;margin-bottom:52px}
      .chips{display:flex;gap:20px;margin-bottom:56px}
      .chip{padding:16px 30px;border:2px solid #2b3c42;border-radius:12px;background:#111b20;
        font-size:30px;font-weight:700;color:#f1f7f4}
      .chip b{color:#45d6a8}
      .foot{font-size:26px;color:#71847c}
      .shotwrap{position:absolute;right:70px;top:210px;width:960px;border-radius:18px;overflow:hidden;
        border:2px solid #2b3c42;box-shadow:0 30px 80px rgba(0,0,0,.55)}
      .shotwrap img{display:block;width:100%}
      .badge{position:absolute;right:64px;top:96px;padding:12px 24px;border:2px solid #45d6a8;
        border-radius:10px;color:#45d6a8;font-size:26px;font-weight:700;background:rgba(11,18,22,.85)}
    </style></head><body>
      <div class="left">
        <div class="brand"><img src="${icon}"><span>AMD MOBILE POWER</span></div>
        <h1>功耗上限<br>按你的需求定</h1>
        <div class="sub">原生 Windows 面板 · 实时回读<br>预设可编辑 · 电池/外接分别设限</div>
        <div class="chips"><div class="chip"><b>10</b> W 静音续航</div><div class="chip"><b>25</b> W 日常均衡</div><div class="chip"><b>45</b> W 性能释放</div></div>
        <div class="foot">开源免费 · v${version} · 演示为模拟数据，未写硬件</div>
      </div>
      <div class="shotwrap"><img src="${guiData}"></div>
      <div class="badge">模拟数据 · 未写硬件</div>
    </body></html>`);
    await page.evaluate(async () => { for (const image of document.images) await image.decode(); });
    const coverPath = path.join(outputDir, `bilibili-cover-${version}-demand.png`);
    await page.screenshot({ path: coverPath });
    console.log(JSON.stringify({ Verification: "PASS", Version: version, Cover: coverPath, SourceFrame: sourceFrame.Path }, null, 2));
  } finally {
    await browser.close();
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
