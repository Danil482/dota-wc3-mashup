const fs = require('fs');
const P = 'mdx-m3-viewer/dist/cjs/parsers';
const MpqArchive = require(`${P}/mpq/archive`).default;
const WPM = require(`${P}/w3x/wpm/file`).default;
const W3E = require(`${P}/w3x/w3e/file`).default;
const mpq = new MpqArchive();
mpq.load(new Uint8Array(fs.readFileSync(process.argv[2])), true);
const wpm = new WPM(); wpm.load(mpq.get('war3map.wpm').bytes());
const h = {};
for (const v of wpm.pathing) h[v.toString(16)] = (h[v.toString(16)] || 0) + 1;
console.log('wpm values', h);
const w3e = new W3E(); w3e.load(mpq.get('war3map.w3e').bytes());
// sample a water corner position and the wpm cells around it
const W = w3e.mapSize[0];
let found = null;
for (let y = 0; y < w3e.corners.length && !found; y++) for (let x = 0; x < W; x++) { const c = w3e.corners[y][x]; const z = (c.groundHeight + (c.layerHeight - 2)) * 128; const wz = c.waterHeight * 128 - 89.6; if (c.water && wz > z + 30) { found = [x, y]; break; } }
console.log('first deep water corner', found, 'cell value', wpm.pathing[(found[1] * 4) * wpm.size[0] + found[0] * 4].toString(16));
const c0 = w3e.corners[0][0]; console.log('corner[0][0]', JSON.stringify(c0));
const cm = w3e.corners[64][64]; console.log('corner[64][64]', JSON.stringify(cm), 'cell', wpm.pathing[(64 * 4) * wpm.size[0] + 64 * 4].toString(16));
