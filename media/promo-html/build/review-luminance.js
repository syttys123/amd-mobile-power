const fs = require('fs');
const samples = [];
let current;
for (const line of fs.readFileSync(process.argv[2], 'utf8').split(/\r?\n/)) {
  const frame = /^frame:(\d+)\s+pts:\S+\s+pts_time:([\d.]+)/.exec(line);
  if (frame) {
    current = { frame: Number(frame[1]), seconds: Number(frame[2]) };
    samples.push(current);
  }
  const mean = /^lavfi\.signalstats\.YAVG=([\d.]+)/.exec(line);
  if (mean && current) current.meanLuma = Number(mean[1]);
}
if (samples.length < 3 || samples.some(sample => !Number.isFinite(sample.meanLuma))) {
  throw new Error('Incomplete per-frame luminance data.');
}
const spikes = samples.filter((sample, index) => index > 0 && index < samples.length - 1 &&
  sample.meanLuma - Math.max(samples[index - 1].meanLuma, samples[index + 1].meanLuma) > 20);
const brightFrames = samples.filter(sample => sample.meanLuma > 210);
const result = {
  scope: 'Downscaled whole-frame luminance heuristic; does not prove absence of local flashes',
  frames: samples.length,
  isolatedSpikeThreshold: 20,
  brightFrameThreshold: 210,
  isolatedSpikes: spikes,
  brightFrames,
  minimum: Math.min(...samples.map(sample => sample.meanLuma)),
  maximum: Math.max(...samples.map(sample => sample.meanLuma)),
};
fs.writeFileSync(process.argv[3], JSON.stringify(result, null, 2));
console.log(JSON.stringify(result));
