// Inspect a map with mdx-m3-viewer's parsers (formats used by Reforged 2.0.x ladder maps).
const fs = require('fs');
const P = 'mdx-m3-viewer/dist/cjs/parsers';
const MpqArchive = require(`${P}/mpq/archive`).default;
const W3E = require(`${P}/w3x/w3e/file`).default;
const W3I = require(`${P}/w3x/w3i/file`).default;
const DOO = require(`${P}/w3x/doo/file`).default;
const WPM = require(`${P}/w3x/wpm/file`).default;
const mpq = new MpqArchive();
mpq.load(new Uint8Array(fs.readFileSync(process.argv[2])), true);
const get = (n) => mpq.get(n).bytes();
const w3i = new W3I(); w3i.load(get('war3map.w3i'));
const short = {};
for (const [k, v] of Object.entries(w3i)) {
  if (Array.isArray(v)) short[k] = `array(${v.length})`;
  else if (v && typeof v === 'object' && !(v instanceof Uint8Array)) short[k] = JSON.stringify(v).slice(0, 120);
  else short[k] = v;
}
console.log('W3I', JSON.stringify(short, null, 0));
console.log('players', JSON.stringify(w3i.players).slice(0, 600));
console.log('forces', JSON.stringify(w3i.forces).slice(0, 300));
const w3e = new W3E(); w3e.load(get('war3map.w3e'));
console.log('W3E version', w3e.version, 'tileset', w3e.tileset, 'tiles', w3e.groundTilesets, 'cliffs', w3e.cliffTilesets, 'size', w3e.mapSize, 'offset', w3e.centerOffset);
const flat = w3e.corners.flat();
const hist = {};
for (const c of flat) { const k = `w${c.water} b${c.boundary} e${c.mapEdge} r${c.ramp} L${c.layerHeight}`; hist[k] = (hist[k] || 0) + 1; }
console.log('corner flags', hist);
const water = flat.filter(c => c.water);
console.log('water sample', water.slice(0, 2).map(c => JSON.stringify(c)));
console.log('dry sample', JSON.stringify(flat.find(c => !c.water && !c.boundary)));
console.log('height range', Math.min(...flat.map(c => c.groundHeight)), Math.max(...flat.map(c => c.groundHeight)));
const wpm = new WPM(); wpm.load(get('war3map.wpm'));
console.log('WPM', wpm.version, wpm.size, 'flags', [...new Set(wpm.flags)].map(x => x.toString(16)));
for (const bv of [6105, 6114, 6116]) { try { const d = new DOO(); d.load(get('war3map.doo'), bv); console.log('DOO buildVersion', bv, 'ok version', d.version, d.subversion, 'doodads', d.doodads.length, 'sample', JSON.stringify(d.doodads[0]).slice(0, 300)); break; } catch (e) { console.log('DOO', bv, 'fail', e.message); } }
