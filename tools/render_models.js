// Render converted MDX models with mdx-m3-viewer (WebGL) in headless Chromium
// through puppeteer, and save contact sheets for a visual check.
//
// Usage: node tools/render_models.js <root> <out dir> <key> [<key> ...]
//   <root>    folder that contains war3mapImported\Dota\<key>.mdx and textures
//   <out dir> where <key>.png sheets go (e.g. build/model_renders)
//
// Each sheet has a views row (Stand, first frame: front 3/4 with attachment
// points, side, back, the in-game Warcraft III camera, and the model's own
// portrait camera) and one row per sequence in SEQUENCES at five points of
// its interval. Overlays: green arrow = +X (WC3 facing 0),
// ruler ticks every 50 units up to the model's height, grey ground cross
// through the origin. The text line under each cell gives sequence and frame.
const fs = require('fs');
const path = require('path');
const http = require('http');
const puppeteer = require('puppeteer');

const ROOT = __dirname;
const VIEWER = path.join(ROOT, 'node_modules/mdx-m3-viewer/dist/umd/viewer.min.js');
const SEQUENCES = ['Stand', 'Walk', 'Attack', 'Spell', 'Death', 'Birth'];
const CELL = Number(process.env.CELL || 300);

const PAGE = `<!doctype html><html><head><meta charset="utf-8"></head>
<body style="margin:0;background:#202020">
<canvas id="c" width="${CELL}" height="${CELL}"></canvas>
<script src="/viewer.min.js"></script>
<script>
const MV = ModelViewer.default || ModelViewer;
const canvas = document.getElementById('c');
const viewer = new MV.viewer.ModelViewer(canvas, { preserveDrawingBuffer: true, antialias: true, alpha: false });
viewer.addHandler(MV.viewer.handlers.mdx);
viewer.addHandler(MV.viewer.handlers.blp);
const scene = viewer.addScene();
scene.color.fill(0.16);
const errors = [];
viewer.on('error', (e) => errors.push(String(e.error || e.reason || e.fetchUrl || e)));
const solver = (src) => (typeof src === 'string' ? '/files/' + src.replace(/\\\\/g, '/') : src);
let instance = null;
window.loadModel = async (p) => {
  const model = await viewer.load(p, solver);
  if (!model) return { ok: false, errors };
  await viewer.whenAllLoaded();
  instance = model.addInstance();
  instance.setScene(scene);
  instance.setSequenceLoopMode(2);
  return { ok: true, errors, sequences: model.sequences.map((s) => ({ name: s.name, interval: Array.from(s.interval) })),
           textures: model.textures.length };
};
function project(m, p) {
  const x = m[0] * p[0] + m[4] * p[1] + m[8] * p[2] + m[12];
  const y = m[1] * p[0] + m[5] * p[1] + m[9] * p[2] + m[13];
  const w = m[3] * p[0] + m[7] * p[1] + m[11] * p[2] + m[15];
  return [(x / w * 0.5 + 0.5) * ${CELL}, (1 - (y / w * 0.5 + 0.5)) * ${CELL}];
}
window.portrait = () => {
  const c = instance.model.cameras[0];
  return c ? { eye: Array.from(c.position), target: Array.from(c.targetPosition), fov: c.fieldOfView } : null;
};
window.shot = (seq, frame, eye, target, height, opts) => {
  opts = opts || {};
  instance.setSequence(seq);
  instance.frame = frame;
  const cam = scene.camera;
  cam.perspective(opts.fov || 0.8, 1, opts.near || 10, 20000);
  cam.moveToAndFace(eye, target, [0, 0, 1]);
  viewer.update(0);
  viewer.startFrame();
  viewer.render();
  const out = document.createElement('canvas');
  out.width = out.height = ${CELL};
  const ctx = out.getContext('2d');
  ctx.drawImage(canvas, 0, 0);
  const vp = cam.viewProjectionMatrix;
  // ground cross and facing arrow
  ctx.lineWidth = 1;
  ctx.strokeStyle = 'rgba(160,160,160,0.6)';
  for (const [a, b] of [[[-150, 0, 0], [150, 0, 0]], [[0, -150, 0], [0, 150, 0]]]) {
    const pa = project(vp, a), pb = project(vp, b);
    ctx.beginPath(); ctx.moveTo(pa[0], pa[1]); ctx.lineTo(pb[0], pb[1]); ctx.stroke();
  }
  ctx.lineWidth = 3;
  ctx.strokeStyle = '#3c3';
  const o = project(vp, [0, 0, 0]), x = project(vp, [120, 0, 0]);
  ctx.beginPath(); ctx.moveTo(o[0], o[1]); ctx.lineTo(x[0], x[1]); ctx.stroke();
  ctx.fillStyle = '#3c3'; ctx.beginPath(); ctx.arc(x[0], x[1], 4, 0, 6.3); ctx.fill();
  if (opts.attachments) {
    ctx.font = '10px sans-serif';
    for (const a of instance.model.attachments) {
      const node = instance.nodes[a.index];
      const p = project(vp, node.worldLocation);
      ctx.fillStyle = '#f4f'; ctx.beginPath(); ctx.arc(p[0], p[1], 3.5, 0, 6.3); ctx.fill();
      ctx.fillStyle = '#fbf'; ctx.fillText(a.name.replace(' Ref', ''), p[0] + 5, p[1] - 3);
    }
  }
  if (opts.noRuler) return out.toDataURL('image/png');
  // height ruler at the origin's side
  ctx.strokeStyle = '#fc3'; ctx.fillStyle = '#fc3'; ctx.lineWidth = 2; ctx.font = '10px sans-serif';
  const top = project(vp, [0, -90, Math.ceil(height / 50) * 50]), bottom = project(vp, [0, -90, 0]);
  ctx.beginPath(); ctx.moveTo(bottom[0], bottom[1]); ctx.lineTo(top[0], top[1]); ctx.stroke();
  for (let z = 0; z <= height + 50; z += 50) {
    const t = project(vp, [0, -90, z]);
    ctx.fillRect(t[0] - 4, t[1] - 1, 8, 2);
    if (z % 100 === 0) ctx.fillText(String(z), t[0] + 6, t[1] + 3);
  }
  return out.toDataURL('image/png');
};
</script></body></html>`;

function serve(root) {
  const server = http.createServer((req, res) => {
    const url = decodeURIComponent(req.url.split('?')[0]);
    let file = null;
    if (url === '/favicon.ico') {
      res.writeHead(204);
      res.end();
      return;
    }
    if (url === '/' || url === '/index.html') {
      res.writeHead(200, { 'Content-Type': 'text/html' });
      res.end(PAGE);
      return;
    }
    if (url === '/viewer.min.js') file = VIEWER;
    else if (url.startsWith('/files/')) file = path.join(root, url.slice(7));
    if (file && fs.existsSync(file) && fs.statSync(file).isFile()) {
      res.writeHead(200, { 'Content-Type': 'application/octet-stream' });
      res.end(fs.readFileSync(file));
    } else {
      res.writeHead(404);
      res.end();
    }
  });
  return new Promise((resolve) => server.listen(0, '127.0.0.1', () => resolve(server)));
}

async function renderModel(page, port, root, key, outDir) {
  await page.goto(`http://127.0.0.1:${port}/index.html`);
  const info = await page.evaluate((p) => window.loadModel(p), `war3mapImported\\Dota\\${key}.mdx`);
  if (!info.ok) throw new Error(`${key}: model did not load: ${info.errors.join('; ')}`);
  const mdx = fs.readFileSync(path.join(root, 'war3mapImported', 'Dota', `${key}.mdx`));
  // Frame on the Stand sequence's extent (SEQS: 132 bytes per sequence,
  // name[80], interval, moveSpeed, nonLooping, rarity, syncPoint, extent).
  const seqs = mdx.indexOf(Buffer.from('SEQS'));
  let min = [-50, -50, 0], max = [50, 50, 150];
  for (let at = seqs + 8; at < seqs + 8 + mdx.readUInt32LE(seqs + 4); at += 132) {
    if (mdx.toString('latin1', at, at + 80).split(String.fromCharCode(0))[0] === 'Stand') {
      const f = (i) => mdx.readFloatLE(at + 104 + 4 * i);
      min = [f(1), f(2), f(3)];
      max = [f(4), f(5), f(6)];
      break;
    }
  }
  const height = Math.max(50, max[2]);
  const size = Math.max(height, max[0] - min[0], max[1] - min[1]);
  const center = [(min[0] + max[0]) / 2, (min[1] + max[1]) / 2, height * 0.45];
  const d = size * 1.7;
  const eyes = {
    'front 3/4': [center[0] + d * 0.87, center[1] - d * 0.5, center[2] + d * 0.25],
    'side (left)': [center[0], center[1] + d, center[2] + d * 0.15],
    back: [center[0] - d, center[1], center[2] + d * 0.25],
    'WC3 camera': [center[0], center[1] - d * 0.62, center[2] + d * 0.92],
  };
  const seqIndex = Object.fromEntries(info.sequences.map((s, i) => [s.name, i]));
  const rows = [];
  const stand0 = info.sequences[seqIndex.Stand].interval[0];
  const views = Object.entries(eyes).map(([name, eye], i) => ({
    label: `Stand 0 - ${name}` + (i === 0 ? ' + attachments' : ''), seq: seqIndex.Stand, frame: stand0, eye,
    opts: i === 0 ? { attachments: true } : {} }));
  const pc = await page.evaluate(() => window.portrait());
  if (pc) {
    views.push({ label: 'Stand 0 - portrait camera', seq: seqIndex.Stand, frame: stand0, eye: pc.eye, target: pc.target,
                 opts: { fov: pc.fov, near: 1, noRuler: true } });
  }
  rows.push(['views', views]);
  for (const name of SEQUENCES) {
    if (!(name in seqIndex)) continue;
    const [a, b] = info.sequences[seqIndex[name]].interval;
    rows.push([name, [0, 0.25, 0.5, 0.75, 1].map((u) => {
      const frame = Math.min(b - 1, Math.round(a + (b - a) * u));
      return { label: `${name} ${frame - a} ms`, seq: seqIndex[name], frame, eye: eyes['front 3/4'] };
    })]);
  }
  const cells = [];
  for (let r = 0; r < rows.length; r++) {
    const row = rows[r][1];
    for (let col = 0; col < row.length; col++) {
      const c = { ...row[col], row: r, col };
      const url = await page.evaluate((s, fr, e, t, h, o) => window.shot(s, fr, e, t, h, o), c.seq, c.frame, c.eye,
                                      c.target || center, height, c.opts || {});
      cells.push({ ...c, url });
    }
  }
  // Compose the sheet in the page (2D canvas), return PNG bytes.
  const sheet = await page.evaluate(async (cells, rowsCount, cell, title) => {
    const cols = 5;
    const c = document.createElement('canvas');
    c.width = cols * cell;
    c.height = rowsCount * (cell + 16) + 24;
    const ctx = c.getContext('2d');
    ctx.fillStyle = '#111'; ctx.fillRect(0, 0, c.width, c.height);
    ctx.fillStyle = '#eee'; ctx.font = 'bold 14px sans-serif'; ctx.fillText(title, 6, 17);
    for (let i = 0; i < cells.length; i++) {
      const img = new Image();
      img.src = cells[i].url;
      await img.decode();
      const x = cells[i].col * cell, y = 24 + cells[i].row * (cell + 16);
      ctx.drawImage(img, x, y);
      ctx.fillStyle = '#ddd'; ctx.font = '11px sans-serif'; ctx.fillText(cells[i].label, x + 4, y + cell + 12);
    }
    return c.toDataURL('image/png');
  }, cells, rows.length, CELL, `${key}  (green = +X / facing 0, ruler = 50 units)`);
  fs.writeFileSync(path.join(outDir, `${key}.png`), Buffer.from(sheet.split(',')[1], 'base64'));
  return { key, sequences: info.sequences.length, textures: info.textures, errors: info.errors };
}

async function main() {
  const [root, outDir, ...keys] = process.argv.slice(2);
  fs.mkdirSync(outDir, { recursive: true });
  const server = await serve(path.resolve(root));
  const port = server.address().port;
  const browser = await puppeteer.launch({
    headless: true,
    args: ['--use-angle=swiftshader', '--enable-unsafe-swiftshader', '--ignore-gpu-blocklist', '--no-first-run'],
  });
  const results = [];
  try {
    const page = await browser.newPage();
    await page.setViewport({ width: CELL, height: CELL });
    const consoleErrors = [];
    page.on('console', (m) => { if (m.type() === 'error' || m.type() === 'warning') consoleErrors.push(m.text()); });
    page.on('pageerror', (e) => consoleErrors.push(String(e)));
    for (const key of keys) {
      consoleErrors.length = 0;
      try {
        const r = await renderModel(page, port, path.resolve(root), key, outDir);
        r.console = consoleErrors.slice(0, 10);
        results.push(r);
      } catch (e) {
        results.push({ key, failed: String(e), console: consoleErrors.slice(0, 10) });
      }
    }
  } finally {
    await browser.close();
    server.close();
  }
  process.stdout.write(JSON.stringify(results, null, 1));
  process.exitCode = results.every((r) => !r.failed && !r.errors.length) ? 0 : 1;
}

main();
