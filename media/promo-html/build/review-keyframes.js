const { chromium } = require('playwright');
const fs = require('fs');
const path = require('path');
const { pathToFileURL } = require('url');

(async () => {
  const output = path.resolve(process.argv[2]);
  const poster = process.argv[3]
    ? `data:image/png;base64,${fs.readFileSync(path.resolve(process.argv[3])).toString('base64')}`
    : null;
  const clipDirectory = process.argv[4] ? path.resolve(process.argv[4]) : null;
  const clipFrames = clipDirectory ? fs.readdirSync(clipDirectory)
    .filter(name => /^frame-\d+\.png$/.test(name)).sort() : [];
  if (clipDirectory && !clipFrames.length) throw new Error('No recorded frames found.');
  fs.mkdirSync(output, { recursive: true });
  const browser = await chromium.launch();
  try {
    const page = await browser.newPage({ viewport: { width: 1920, height: 1080 } });
    await page.goto(pathToFileURL(path.resolve(__dirname, '../index.html')).href);
    await page.waitForFunction(() => typeof window.__seek === 'function');
    if (poster) await page.evaluate(value => { window.__CLIP_POSTER__ = value; }, poster);
    const scenes = await page.evaluate(() => window.__SCENES__);
    const results = [];
    let start = 0;
    for (const scene of scenes) {
      await page.evaluate(time => window.__seek(time), start + scene.duration / 2);
      if (scene.id === 'ui-demo' && clipFrames.length) {
        const frameIndex = Math.min(clipFrames.length - 1,
          Math.max(0, Math.floor((scene.duration / 2 - 0.4) * 10)));
        const source = `data:image/png;base64,${fs.readFileSync(path.join(clipDirectory, clipFrames[frameIndex])).toString('base64')}`;
        await page.evaluate(value => { document.getElementById('live-demo-frame').src = value; }, source);
      }
      const missingImages = await page.evaluate(async () => {
        const failed = [];
        for (const image of document.images) {
          try { await image.decode(); }
          catch { failed.push(image.id || image.getAttribute('src') || 'empty image'); }
          if (!image.naturalWidth && !failed.includes(image.id || image.getAttribute('src') || 'empty image')) {
            failed.push(image.id || image.getAttribute('src') || 'empty image');
          }
        }
        return failed;
      });
      const bounds = await page.evaluate(() => {
        const captions = [...document.querySelectorAll('#root div')].filter(node =>
          node.children.length === 0 && node.textContent.trim());
        return captions.map(node => {
          const rect = node.getBoundingClientRect();
          return { text: node.textContent, left: rect.left, top: rect.top,
            right: rect.right, bottom: rect.bottom,
            overflow: node.scrollWidth > node.clientWidth + 1 || node.scrollHeight > node.clientHeight + 1 };
        }).filter(item => item.overflow || item.left < -1 || item.top < -1 || item.right > 1921 || item.bottom > 1081);
      });
      await page.screenshot({ path: path.join(output, `${scene.id}.png`) });
      results.push({ scene: scene.id, outOfBounds: bounds, missingImages });
      start += scene.duration;
    }
    fs.writeFileSync(path.join(output, 'review.json'), JSON.stringify({
      scope: 'Mid-scene text bounds only; not full motion or footage validation',
      duration: start, results,
    }, null, 2));
    console.log(JSON.stringify(results));
    if (results.some(result => result.outOfBounds.length || result.missingImages.length)) process.exitCode = 1;
  } finally { await browser.close(); }
})().catch(error => { console.error(error); process.exitCode = 1; });
