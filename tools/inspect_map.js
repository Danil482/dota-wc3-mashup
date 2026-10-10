// Inspect an existing map: file list, w3i/w3e versions, terrain flag usage.
const fs = require('fs');
const { default: MpqArchive } = require('mdx-m3-viewer/dist/cjs/parsers/mpq/archive');
const { TerrainTranslator, InfoTranslator } = require('wc3maptranslator');
const buf = fs.readFileSync(process.argv[2]);
const mpq = new MpqArchive();
mpq.load(new Uint8Array(buf), true);
const names = ['war3map.w3i', 'war3map.w3e', 'war3map.wpm', 'war3map.shd', 'war3map.doo', 'war3mapUnits.doo', 'war3map.j', 'war3map.lua', 'war3map.mmp', 'war3mapMap.blp', 'war3mapMisc.txt', 'war3map.w3u', 'war3map.w3a', 'war3map.wts', '(listfile)'];
for (const n of names) {
  const f = mpq.get(n);
  if (!f) { console.log('missing', n); continue; }
  const b = f.bytes();
  console.log(n, b ? b.length : 'unreadable', b ? Buffer.from(b.slice(0, 8)).toString('hex') : '');
}
const w3e = Buffer.from(mpq.get('war3map.w3e').bytes());
const t = TerrainTranslator.warToJson(w3e).json;
console.log('tileset', t.tileset, 'palette', t.tilePalette, 'cliffs', t.cliffTilePalette, 'size', t.map);
const count = {};
t.flags.forEach((f, i) => { const k = f.toString(16) + (t.waterHeight[i] > t.groundHeight[i] ? ' w>g' : ''); count[k] = (count[k] || 0) + 1; });
console.log('flags histogram', count);
console.log('groundHeight range', Math.min(...t.groundHeight), Math.max(...t.groundHeight), 'water', Math.min(...t.waterHeight), Math.max(...t.waterHeight));
console.log('layer heights', [...new Set(t.layerHeight)], 'cliffTex', [...new Set(t.cliffTexture)], 'gvar', [...new Set(t.groundVariation)].slice(0, 8));
try { const info = InfoTranslator.warToJson(Buffer.from(mpq.get('war3map.w3i').bytes())).json; console.log('w3i ok', info.gameVersion, info.scriptLanguage, info.supportedModes, info.map.playableArea, info.camera); } catch (e) { console.log('w3i err', e.message); }
