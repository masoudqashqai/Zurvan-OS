// Combine the PNGs in shots/ into docs/panel.gif (run via render.ps1,
// or directly: node assemble.js). Frames sort by filename; the login page
// is named 9-* so it closes the loop instead of opening it.
const fs = require('fs');
const path = require('path');
const { PNG } = require('pngjs');
const { GIFEncoder, quantize, applyPalette } = require('gifenc');

const dir = path.join(__dirname, 'shots');
const out = path.join(__dirname, '..', '..', 'docs', 'panel.gif');
const files = fs.readdirSync(dir).filter(f => /^\d+-.*\.png$/.test(f)).sort();
const frames = files.map(f => PNG.sync.read(fs.readFileSync(path.join(dir, f))));

// Uniform canvas: common width, fixed height (crop the top of each page).
const W = Math.min(...frames.map(f => f.width));
const H = 680;
const BG = [0x0f, 0x11, 0x15];   // the panel's page background

function normalize(png) {
  const outPx = new Uint8Array(W * H * 4);
  for (let i = 0; i < W * H; i++) {
    outPx[i*4] = BG[0]; outPx[i*4+1] = BG[1]; outPx[i*4+2] = BG[2]; outPx[i*4+3] = 255;
  }
  const cw = Math.min(W, png.width), ch = Math.min(H, png.height);
  for (let y = 0; y < ch; y++) for (let x = 0; x < cw; x++) {
    const s = (y*png.width + x)*4, d = (y*W + x)*4;
    outPx[d] = png.data[s]; outPx[d+1] = png.data[s+1]; outPx[d+2] = png.data[s+2]; outPx[d+3] = 255;
  }
  return outPx;
}

const gif = GIFEncoder();
files.forEach((f, idx) => {
  const rgba = normalize(frames[idx]);
  const palette = quantize(rgba, 256);
  const index = applyPalette(rgba, palette);
  const delay = idx === 0 ? 2800 : 2100;   // linger on the opening (Overview) frame
  gif.writeFrame(index, W, H, { palette, delay });
  console.log('frame', idx, f);
});
gif.finish();
fs.writeFileSync(out, Buffer.from(gif.bytes()));
console.log('wrote', out, W + 'x' + H, files.length, 'frames');
