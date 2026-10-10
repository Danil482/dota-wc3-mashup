// Assemble the .w3x: map info, terrain, pathing, trees, object data, script.
// Usage: node build_map.js <out folder> <war3map.lua> [objects.json]
// File formats follow Reforged 2.0 ladder maps (w3i v31, w3e v11, doo v8/11).
const fs = require('fs');
const path = require('path');
const P = 'mdx-m3-viewer/dist/cjs/parsers';
const W3I = require(`${P}/w3x/w3i/file`).default;
const W3IPlayer = require(`${P}/w3x/w3i/player`).default;
const W3IForce = require(`${P}/w3x/w3i/force`).default;
const WPM = require(`${P}/w3x/wpm/file`).default;
const DOO = require(`${P}/w3x/doo/file`).default;
const Doodad = require(`${P}/w3x/doo/doodad`).default;
const UnitsDoo = require(`${P}/w3x/unitsdoo/file`).default;
const DooUnit = require(`${P}/w3x/unitsdoo/unit`).default;

const ROOT = path.resolve(__dirname, '..');
const [outPath, luaPath, objectsPath] = process.argv.slice(2);
const terrain = JSON.parse(fs.readFileSync(path.join(ROOT, 'build', 'terrain.json'), 'utf8'));
const mapdata = JSON.parse(fs.readFileSync(path.join(ROOT, 'src', 'data', 'mapdata.json'), 'utf8'));

const TILES = terrain.tiles;
const N = TILES + 1;
const PLAY = terrain.playable;
const MARGIN_TILES = (terrain.offset * -1 - PLAY) / 128;

let infoForUnits = null;

function buildInfo() {
  const w3i = new W3I();
  w3i.version = 31;
  w3i.saves = 1;
  w3i.editorVersion = 6115;
  w3i.buildVersion.set([1, 35, 0, 19887]);
  w3i.name = 'Dota vs Commander';
  w3i.author = 'Melty mashup';
  w3i.description = 'Up to five Dota 2 heroes against one Warcraft III commander. Needs Dota 2 installed for hero icons and voices.';
  w3i.recommendedPlayers = '1-6';
  // camera margins as the World Editor sets them: 512 left/right, 256 top/bottom
  const cx = PLAY - 512, cy = PLAY - 256;
  w3i.cameraBounds.set([-cx, -cy, cx, cy, -cx, cy, cx, -cy]);
  w3i.cameraBoundsComplements.set([MARGIN_TILES, MARGIN_TILES, MARGIN_TILES, MARGIN_TILES]);
  w3i.playableSize.set([TILES - 2 * MARGIN_TILES, TILES - 2 * MARGIN_TILES]);
  // masked areas partially visible, custom forces,
  // properties opened, water waves, item classification
  w3i.flags = 0x0010 | 0x0040 | 0x0400 | 0x0800 | 0x1000 | 0x8000;
  w3i.tileset = 'L';
  w3i.campaignBackground = -1;
  w3i.loadingScreen = 0;      // preset 0 like Blizzard maps; -1 expects a custom model
  w3i.fogHeight.set([3000, 5000]);
  w3i.fogDensity = 0.5;
  w3i.fogColor.set([0, 0, 0, 255]);
  w3i.waterVertexColor.set([255, 255, 255, 255]);
  w3i.scriptMode = 1;     // Lua
  w3i.graphicsMode = 3;   // SD and HD
  w3i.unknown1 = 1;       // game data: The Frozen Throne

  const f = mapdata.dota.fountain, s = mapdata.commander.start, a = mapdata.dota.ancient;
  const slots = [
    [0, 1, 1, 'Dota 1', f], [1, 1, 1, 'Dota 2', f], [2, 1, 1, 'Dota 3', f], [3, 1, 1, 'Dota 4', f],
    [4, 1, 1, 'Dota 5', f], [5, 1, 1, 'Commander', s],
    [6, 2, 4, 'The Ancients', a], [7, 2, 1, 'Commander AI', s], [8, 2, 2, 'Horde', s],
  ];
  for (const [id, type, race, name, pos] of slots) {
    const p = new W3IPlayer();
    p.id = id;
    p.type = type;
    p.race = race;
    p.isFixedStartPosition = 1;
    p.name = name;
    p.startLocation.set([pos.x, pos.y]);
    w3i.players.push(p);
  }
  const dota = new W3IForce();
  dota.flags = 0x07;                       // allied, allied victory, shared vision
  dota.playerMasks = 0b001011111;          // slots 0-4 and 6
  dota.name = 'Dota';
  const cmd = new W3IForce();
  cmd.flags = 0x07;
  cmd.playerMasks = 0b110100000;           // slots 5, 7, 8
  cmd.name = 'Commander';
  w3i.forces.push(dota, cmd);
  infoForUnits = w3i;
  return w3i.save();
}

// war3map.w3e v11. Written by hand: mdx-m3-viewer's Corner.save mis-encodes
// the water/edge word and the flag bits (see tools/roundtrip.js).
function writeW3e({ tileset, custom = 0, groundTilesets, cliffTilesets, width, height, offsetX, offsetY, corners }) {
  const header = 4 + 4 + 1 + 4 + 4 + 4 * groundTilesets.length + 4 + 4 * cliffTilesets.length + 16;
  const buf = Buffer.alloc(header + corners.length * 7);
  let o = 0;
  o += buf.write('W3E!', o, 'ascii');
  o = buf.writeInt32LE(11, o);
  o += buf.write(tileset, o, 'ascii');
  o = buf.writeInt32LE(custom, o);
  o = buf.writeInt32LE(groundTilesets.length, o);
  for (const t of groundTilesets) o += buf.write(t, o, 'ascii');
  o = buf.writeInt32LE(cliffTilesets.length, o);
  for (const t of cliffTilesets) o += buf.write(t, o, 'ascii');
  o = buf.writeInt32LE(width, o);
  o = buf.writeInt32LE(height, o);
  o = buf.writeFloatLE(offsetX, o);
  o = buf.writeFloatLE(offsetY, o);
  for (const c of corners) {
    o = buf.writeInt16LE(Math.round(c.groundHeight * 512 + 8192), o);
    o = buf.writeInt16LE((Math.round(c.waterHeight * 512 + 8192) & 0x3FFF) | (c.mapEdge ? 0x4000 : 0), o);
    o = buf.writeUInt8((c.ramp ? 0x10 : 0) | (c.blight ? 0x20 : 0) | (c.water ? 0x40 : 0) | (c.boundary ? 0x80 : 0) | (c.groundTexture & 0x0F), o);
    o = buf.writeUInt8(((c.cliffVariation & 7) << 5) | (c.groundVariation & 0x1F), o);
    o = buf.writeUInt8(((c.cliffTexture & 0x0F) << 4) | (c.layerHeight & 0x0F), o);
  }
  return new Uint8Array(buf);
}

function buildTerrain() {
  const corners = terrain.corners.map((src) => ({
    groundHeight: src.h, waterHeight: 0, mapEdge: src.edge, ramp: false, blight: false,
    water: src.water, boundary: false, groundTexture: src.tex, cliffVariation: 0,
    groundVariation: src.var, cliffTexture: 15, layerHeight: 2,
  }));
  return writeW3e({
    tileset: 'L', groundTilesets: terrain.tilePalette, cliffTilesets: ['CLdi', 'CLgr'],
    width: N, height: N, offsetX: terrain.offset, offsetY: terrain.offset, corners,
  });
}

// Start locations as the World Editor stores them (one 'sloc' per player).
function buildUnits(info) {
  const doo = new UnitsDoo();
  doo.version = 8;
  doo.subversion = 11;
  let editorId = 0;
  for (const p of info.players) {
    const u = new DooUnit();
    u.id = 'sloc';
    u.skin = 'sloc';
    u.variation = 0;
    u.location.set([p.startLocation[0], p.startLocation[1], 0]);
    u.angle = 4.712389;
    u.flags = 2;
    u.player = p.id;
    u.hitpoints = -1;
    u.mana = -1;
    u.droppedItemTable = -1;
    u.goldAmount = 0;
    u.targetAcquisition = 0;
    u.randomFlag = 0;
    u.level.set([1, 0, 0]);
    u.customTeamColor = -1;
    u.waygate = -1;
    u.creationNumber = editorId++;
    doo.units.push(u);
  }
  return doo.save(6105);
}

function buildPathing() {
  const wpm = new WPM();
  wpm.version = 0;
  wpm.size.set([TILES * 4, TILES * 4]);
  wpm.pathing = new Uint8Array(Buffer.from(terrain.pathing, 'base64'));
  return wpm.save();
}

function buildDoodads() {
  const doo = new DOO();
  doo.version = 8;
  doo.u1.set([11, 0, 0, 0]);
  let id = 0;
  let seed = 1234567;
  const rnd = () => (seed = (seed * 1103515245 + 12345) % 2147483648) / 2147483648;
  for (const [x, y] of terrain.trees) {
    const d = new Doodad();
    d.id = 'LTlt';
    d.skin = 'LTlt';
    d.variation = Math.floor(rnd() * 10);
    d.location.set([x, y, 0]);
    d.angle = 4.712389;
    const s = 0.9 + rnd() * 0.25;
    d.scale.set([s, s, s]);
    d.flags = 2;
    d.life = 100;
    d.itemTable = -1;
    d.editorId = id++;
    doo.doodads.push(d);
  }
  return doo.save(132);
}

function main() {
  const files = {
    'war3map.w3i': buildInfo(),
    'war3map.w3e': buildTerrain(),
    'war3map.wpm': buildPathing(),
    'war3map.shd': new Uint8Array(TILES * 4 * TILES * 4),
    'war3map.doo': buildDoodads(),
    'war3mapUnits.doo': buildUnits(infoForUnits),
    'war3map.lua': fs.readFileSync(luaPath, 'utf8'),
  };
  if (objectsPath) {
    const objects = JSON.parse(fs.readFileSync(objectsPath, 'utf8'));
    for (const [name, b64] of Object.entries(objects)) {
      files[name] = new Uint8Array(Buffer.from(b64, 'base64'));
    }
  }
  // Files go to a folder; tools/mpq_pack.py packs it with StormLib (archives
  // from mdx-m3-viewer's MPQ writer are rejected by the game).
  fs.rmSync(outPath, { recursive: true, force: true });
  for (const [name, data] of Object.entries(files)) {
    const dest = path.join(outPath, ...name.split('\\'));
    fs.mkdirSync(path.dirname(dest), { recursive: true });
    fs.writeFileSync(dest, typeof data === 'string' ? data : Buffer.from(data));
  }
  console.log(`map files: ${outPath} (${Object.keys(files).length} files, ${terrain.trees.length} trees)`);
}

if (require.main === module) main();
module.exports = { writeW3e };
