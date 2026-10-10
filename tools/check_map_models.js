// End-to-end check of a personalized map (base map built with
// `tools/build.py --dota-models`, then written by the launcher): every unit
// whose object data points at war3mapImported\Dota\*.mdx must find that model
// and all of its textures inside the map, parse, and render visibly.
//
// Usage: node tools/check_map_models.js <map.w3x> <sheet.png>
//
// Reads the map with mdx-m3-viewer's MPQ reader, war3map.w3u with its object
// data parser, loads each model straight from the archive into the WebGL
// viewer in headless Chromium (puppeteer) at the unit's scaling value (usca),
// renders the Stand pose with the in-game camera angle, and counts the pixels
// that differ from the background. The portrait model (upor: the model
// itself, or its static <key>_portrait.mdx) must be in the map too, carry a
// Portrait camera, and show the model through it (inset at the top right of
// each cell). Units whose specs/models.json "portrait" is false or a WC3
// model path keep a WC3 portrait: no upor, or upor = that path. Items
// (war3map.w3t, ifil: the runes) get the same model checks at their isca,
// without a portrait. Writes a contact sheet and prints JSON; exit code 1 if
// any unit or item fails.
const fs = require('fs');
const path = require('path');
const http = require('http');
const puppeteer = require('puppeteer');

const ROOT = __dirname;
const MV = path.join(ROOT, 'node_modules/mdx-m3-viewer/dist/cjs');
const MpqArchive = require(path.join(MV, 'parsers/mpq/archive')).default;
const W3u = require(path.join(MV, 'parsers/w3x/w3u/file')).default;
const mdlx = require(path.join(MV, 'parsers/mdlx')).default;
const VIEWER = path.join(ROOT, 'node_modules/mdx-m3-viewer/dist/umd/viewer.min.js');
const CELL = 260;
const BG = 40;

const PAGE = `<!doctype html><html><head><meta charset="utf-8"></head><body style="margin:0">
<canvas id="c" width="${CELL}" height="${CELL}"></canvas>
<script src="/viewer.min.js"></script>
<script>
const MV = ModelViewer.default || ModelViewer;
const canvas = document.getElementById('c');
const viewer = new MV.viewer.ModelViewer(canvas, { preserveDrawingBuffer: true, antialias: false, alpha: false });
viewer.addHandler(MV.viewer.handlers.mdx);
viewer.addHandler(MV.viewer.handlers.blp);
const errors = [];
viewer.on('error', (e) => errors.push(String(e.error) + ' ' + String(e.fetchUrl || '')));
const solver = (src) => (typeof src === 'string' ? '/mpq/' + encodeURIComponent(src) : src);
window.render = async (p, scale, height) => {
  errors.length = 0;
  const scene = viewer.addScene();
  scene.color.fill(${BG} / 255);
  const model = await viewer.load(p, solver);
  if (!model) return { ok: false, errors: errors.slice() };
  await viewer.whenAllLoaded();
  const inst = model.addInstance();
  inst.setScene(scene);
  inst.uniformScale(scale);
  const stand = model.sequences.findIndex((s) => s.name === 'Stand');
  inst.setSequence(stand);
  const h = Math.max(60, height * scale);
  const d = h * 1.6;
  scene.camera.perspective(0.8, 1, 10, 20000);
  // Warcraft III's game camera: from the south, about 56 degrees down.
  scene.camera.moveToAndFace([0, -d * 0.56, h * 0.45 + d * 0.83], [0, 0, h * 0.45], [0, 0, 1]);
  viewer.update(0);
  viewer.startFrame();
  viewer.render();
  const gl = viewer.gl;
  const px = new Uint8Array(${CELL} * ${CELL} * 4);
  gl.readPixels(0, 0, ${CELL}, ${CELL}, gl.RGBA, gl.UNSIGNED_BYTE, px);
  let covered = 0;
  for (let i = 0; i < px.length; i += 4) {
    if (Math.abs(px[i] - ${BG}) + Math.abs(px[i + 1] - ${BG}) + Math.abs(px[i + 2] - ${BG}) > 24) covered++;
  }
  const url = canvas.toDataURL('image/png');
  viewer.removeScene(scene);
  return { ok: true, errors: errors.slice(), coverage: covered / (${CELL} * ${CELL}), url,
           sequences: model.sequences.length, textures: model.textures.length };
};
// The unit's portrait: the model's own camera, Stand, unscaled.
window.portrait = async (p) => {
  errors.length = 0;
  const scene = viewer.addScene();
  scene.color.fill(${BG} / 255);
  const model = await viewer.load(p, solver);
  if (!model) return { ok: false, errors: errors.slice() };
  await viewer.whenAllLoaded();
  const cam = model.cameras[0];
  if (!cam) { viewer.removeScene(scene); return { ok: false, errors: ['no camera'] }; }
  const inst = model.addInstance();
  inst.setScene(scene);
  inst.setSequence(model.sequences.findIndex((s) => s.name === 'Stand'));
  scene.camera.perspective(cam.fieldOfView, 1, Math.max(1, cam.nearClippingPlane), cam.farClippingPlane);
  scene.camera.moveToAndFace(Array.from(cam.position), Array.from(cam.targetPosition), [0, 0, 1]);
  viewer.update(0);
  viewer.startFrame();
  viewer.render();
  const gl = viewer.gl;
  const px = new Uint8Array(${CELL} * ${CELL} * 4);
  gl.readPixels(0, 0, ${CELL}, ${CELL}, gl.RGBA, gl.UNSIGNED_BYTE, px);
  let covered = 0;
  for (let i = 0; i < px.length; i += 4) {
    if (Math.abs(px[i] - ${BG}) + Math.abs(px[i + 1] - ${BG}) + Math.abs(px[i + 2] - ${BG}) > 24) covered++;
  }
  const url = canvas.toDataURL('image/png');
  viewer.removeScene(scene);
  return { ok: true, errors: errors.slice(), coverage: covered / (${CELL} * ${CELL}), url };
};
</script></body></html>`;

// Keys of specs/models.json that keep a WC3 portrait -> the upor the map must
// carry: '' for "portrait": false, else the WC3 model path given there. (A
// war3mapImported\Dota\<key>_portrait.mdx portrait is checked like any other.)
function wc3Portraits() {
  const spec = JSON.parse(fs.readFileSync(path.join(ROOT, '..', 'specs', 'models.json'), 'utf8'));
  const out = new Map();
  for (const [k, v] of Object.entries(spec)) {
    if (v.portrait === false) out.set(k.toLowerCase(), '');
    else if (typeof v.portrait === 'string' && !/^war3mapImported\\Dota\\/i.test(v.portrait)) {
      out.set(k.toLowerCase(), v.portrait);
    }
  }
  return out;
}

function unitsWithDotaModels(archive) {
  const file = archive.get('war3map.w3u');
  if (!file) throw new Error('no war3map.w3u in the map');
  const w3u = new W3u();
  w3u.load(file.bytes());
  const keep = wc3Portraits();
  const out = [];
  for (const obj of w3u.customTable.objects) {
    const mods = Object.fromEntries(obj.modifications.map((m) => [m.id, m.value]));
    const model = mods.umdl;
    if (typeof model === 'string' && /^war3mapImported\\Dota\\/i.test(model)) {
      const key = model.split('\\').pop().replace(/\.mdx$/i, '').toLowerCase();
      out.push({ kind: 'unit', id: obj.newId, base: obj.oldId, name: mods.unam || '', model, portrait: mods.upor || '',
                 wc3Portrait: keep.has(key), expectedPortrait: keep.get(key),
                 scale: mods.usca === undefined ? 1 : mods.usca });
    }
  }
  return out;
}

// Items whose model (ifil) is a converted Dota model: the runes.
function itemsWithDotaModels(archive) {
  const file = archive.get('war3map.w3t');
  if (!file) return [];
  const w3t = new W3u();
  w3t.load(file.bytes());
  const out = [];
  for (const obj of w3t.customTable.objects) {
    const mods = Object.fromEntries(obj.modifications.map((m) => [m.id, m.value]));
    const model = mods.ifil;
    if (typeof model === 'string' && /^war3mapImported\\Dota\\/i.test(model)) {
      out.push({ kind: 'item', id: obj.newId, base: obj.oldId, name: mods.unam || '', model, portrait: '',
                 scale: mods.isca === undefined ? 1 : mods.isca });
    }
  }
  return out;
}

function staticCheck(archive, unit) {
  const problems = [];
  const file = archive.get(unit.model);
  if (!file) return { problems: [`model missing from the map: ${unit.model}`] };
  const model = new mdlx.Model();
  model.load(file.bytes());
  for (const t of model.textures) {
    if (!archive.get(t.path)) problems.push(`texture missing from the map: ${t.path}`);
  }
  const stand = model.sequences.find((s) => s.name === 'Stand');
  if (!stand) problems.push('no Stand sequence');
  // Without upor the base unit's portrait (Units\UnitSkin.txt) would show.
  if (unit.kind === 'item') {
    // items have no portrait
  } else if (unit.wc3Portrait) {
    if (unit.portrait.toLowerCase() !== unit.expectedPortrait.toLowerCase()) {
      problems.push(`upor '${unit.portrait}', but models.json keeps the WC3 portrait '${unit.expectedPortrait}'`);
    }
  } else if (!unit.portrait) {
    problems.push('no portrait model (upor)');
  } else if (!archive.get(unit.portrait)) {
    problems.push(`portrait model missing from the map: ${unit.portrait}`);
  } else {
    let portrait = model;
    if (unit.portrait.toLowerCase() !== unit.model.toLowerCase()) {
      portrait = new mdlx.Model();
      portrait.load(archive.get(unit.portrait).bytes());
      for (const t of portrait.textures) {
        if (!archive.get(t.path)) problems.push(`portrait texture missing from the map: ${t.path}`);
      }
    }
    if (!portrait.cameras.some((c) => c.name === 'Portrait')) problems.push('portrait model has no Portrait camera');
  }
  // Frame on the Stand pose (the model extent also covers jumps and falls).
  const ext = stand ? stand.extent : model.extent;
  const height = Math.max(ext.max[2], 0.6 * Math.max(ext.max[0] - ext.min[0], ext.max[1] - ext.min[1]));
  return { problems, height, vertices: model.geosets.reduce((n, g) => n + g.vertices.length / 3, 0), version: model.version };
}

async function main() {
  const [mapPath, sheetPath] = process.argv.slice(2);
  const archive = new MpqArchive();
  archive.load(new Uint8Array(fs.readFileSync(mapPath)), true);
  const units = unitsWithDotaModels(archive).concat(itemsWithDotaModels(archive));
  const server = http.createServer((req, res) => {
    const url = req.url.split('?')[0];
    if (url === '/' || url === '/index.html') { res.writeHead(200, { 'Content-Type': 'text/html' }); res.end(PAGE); return; }
    if (url === '/viewer.min.js') { res.writeHead(200); res.end(fs.readFileSync(VIEWER)); return; }
    if (url.startsWith('/mpq/')) {
      const f = archive.get(decodeURIComponent(url.slice(5)));
      if (f) { res.writeHead(200, { 'Content-Type': 'application/octet-stream' }); res.end(Buffer.from(f.bytes())); return; }
    }
    res.writeHead(404); res.end();
  });
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  const browser = await puppeteer.launch({ headless: true, args: ['--use-angle=swiftshader', '--enable-unsafe-swiftshader', '--ignore-gpu-blocklist'] });
  const results = [];
  try {
    const page = await browser.newPage();
    await page.goto(`http://127.0.0.1:${server.address().port}/index.html`);
    for (const unit of units) {
      const r = { ...unit, ...staticCheck(archive, unit) };
      if (!r.problems.length) {
        const shot = await page.evaluate((p, s, h) => window.render(p, s, h), unit.model, unit.scale, r.height);
        r.coverage = shot.coverage;
        r.url = shot.url;
        if (!shot.ok) r.problems.push(`viewer could not load the model: ${shot.errors.join('; ')}`);
        for (const e of shot.errors || []) r.problems.push(`viewer: ${e}`);
        if (shot.ok && shot.coverage < 0.01) r.problems.push(`model not visible (${(shot.coverage * 100).toFixed(2)} % of pixels)`);
        if (!r.problems.length && unit.portrait && !unit.wc3Portrait) {
          const face = await page.evaluate((p) => window.portrait(p), unit.portrait);
          r.portraitCoverage = face.coverage;
          r.portraitUrl = face.url;
          if (!face.ok) r.problems.push(`portrait could not be rendered: ${face.errors.join('; ')}`);
          else if (face.coverage < 0.05) r.problems.push(`portrait camera shows little of the model (${(face.coverage * 100).toFixed(1)} %)`);
        }
      }
      r.ok = !r.problems.length;
      results.push(r);
    }
    const cols = 6;
    const sheet = await page.evaluate(async (cells, cols, cell, title) => {
      const rows = Math.ceil(cells.length / cols);
      const c = document.createElement('canvas');
      c.width = cols * cell;
      c.height = rows * (cell + 30) + 24;
      const ctx = c.getContext('2d');
      ctx.fillStyle = '#111'; ctx.fillRect(0, 0, c.width, c.height);
      ctx.fillStyle = '#eee'; ctx.font = 'bold 14px sans-serif'; ctx.fillText(title, 6, 17);
      for (let i = 0; i < cells.length; i++) {
        const x = (i % cols) * cell, y = 24 + Math.floor(i / cols) * (cell + 30);
        if (cells[i].url) { const img = new Image(); img.src = cells[i].url; await img.decode(); ctx.drawImage(img, x, y); }
        if (cells[i].portraitUrl) {
          const img = new Image(); img.src = cells[i].portraitUrl; await img.decode();
          ctx.drawImage(img, x + cell - 90, y + 2, 88, 88);
          ctx.strokeStyle = '#888'; ctx.strokeRect(x + cell - 90, y + 2, 88, 88);
        }
        ctx.fillStyle = cells[i].ok ? '#9e9' : '#f77'; ctx.font = '11px sans-serif';
        ctx.fillText(`${cells[i].id} ${cells[i].name}`.slice(0, 40), x + 4, y + cell + 12);
        ctx.fillStyle = '#ccc';
        ctx.fillText(`${cells[i].model.split(String.fromCharCode(92)).pop()}  usca ${cells[i].scale.toFixed(2)}  ${cells[i].ok ? 'OK' : 'FAIL'}`, x + 4, y + cell + 25);
      }
      return c.toDataURL('image/png');
    }, results.map((r) => ({ id: r.id, name: r.name, model: r.model, scale: r.scale, ok: r.ok, url: r.url,
                             portraitUrl: r.portraitUrl })), cols, CELL,
    `${path.basename(mapPath)}: units with converted Dota models, Stand, in-game camera angle and scale`);
    fs.mkdirSync(path.dirname(sheetPath), { recursive: true });
    fs.writeFileSync(sheetPath, Buffer.from(sheet.split(',')[1], 'base64'));
  } finally {
    await browser.close();
    server.close();
  }
  for (const r of results) { delete r.url; delete r.portraitUrl; }
  process.stdout.write(JSON.stringify({ map: mapPath, units: results.length, failed: results.filter((r) => !r.ok).length, results }, null, 1));
  process.exitCode = results.length && results.every((r) => r.ok) ? 0 : 1;
}

main();
