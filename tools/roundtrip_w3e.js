// Check the hand-written w3e encoder against a real map: parse with mdx-m3-viewer, re-encode, compare.
const fs = require('fs');
const P = 'mdx-m3-viewer/dist/cjs/parsers';
const MpqArchive = require(`${P}/mpq/archive`).default;
const W3E = require(`${P}/w3x/w3e/file`).default;
const { writeW3e } = require('./build_map');
const mpq = new MpqArchive();
mpq.load(new Uint8Array(fs.readFileSync(process.argv[2])), true);
const orig = mpq.get('war3map.w3e').bytes();
const w = new W3E(); w.load(orig);
const out = writeW3e({ tileset: w.tileset, custom: w.haveCustomTileset, groundTilesets: w.groundTilesets, cliffTilesets: w.cliffTilesets,
  width: w.mapSize[0], height: w.mapSize[1], offsetX: w.centerOffset[0], offsetY: w.centerOffset[1], corners: w.corners.flat() });
let diff = -1;
for (let i = 0; i < Math.max(orig.length, out.length); i++) if (orig[i] !== out[i]) { diff = i; break; }
console.log('w3e', orig.length, out.length, diff < 0 ? 'IDENTICAL' : 'first diff at ' + diff);
