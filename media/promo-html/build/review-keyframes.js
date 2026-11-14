const { chromium } = require('playwright');
const fs = require('fs');
const path = require('path');
const { pathToFileURL } = require('url');

(async () => {
  const output = path.resolve(process.argv[2]);
  fs.mkdirSync(output, { recursive: true });
  const browser = await chromium.launch();
  try {
    const page = await browser.newPage({ viewport: { width: 1920, height: 1080 } });
    await page.goto(pathToFileURL(path.resolve(__dirname, '../index.html')).href);
    await page.waitForFunction(() => typeof window.__seek === 'function');
    const scenes = await page.evaluate(() => window.__SCENES__);
    const results = [];
    let start = 0;
    for (const scene of scenes) {
      await page.evaluate(time => window.__seek(time), start + scene.duration / 2);
      await page.evaluate(() => Promise.all([...document.images].map(image => image.decode().catch(() => {}))));
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
      results.push({ scene: scene.id, outOfBounds: bounds });
      start += scene.duration;
    }
    fs.writeFileSync(path.join(output, 'review.json'), JSON.stringify({
      scope: 'Mid-scene text bounds only; not full motion or footage validation',
      duration: start, results,
    }, null, 2));
    console.log(JSON.stringify(results));
    if (results.some(result => result.outOfBounds.length)) process.exitCode = 1;
  } finally { await browser.close(); }
})().catch(error => { console.error(error); process.exitCode = 1; });
