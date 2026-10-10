// Parse MDX files back with mdx-m3-viewer's parser (MIT) and check them.
// Usage: node tools/check_mdx.js <file.mdx> [...]   (textures are looked up
// next to the model, by the file name part of each texture path)
// Prints one JSON object: {file: {ok, problems[], summary}}.
// Checks: the parser reads the whole file, saveMdx() writes it back byte for
// byte (so our chunk layout is exactly the one the parser expects), version
// 800, indices and matrix groups in range, one pivot per object, every
// sequence interval valid and non-overlapping, every texture file present and
// decodable as BLP1, keyframes inside some sequence, and no errors or severe
// findings from mdx-m3-viewer's MDX sanity test (warnings are listed).
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname);
const mdlx = require(path.join(ROOT, 'node_modules/mdx-m3-viewer/dist/cjs/parsers/mdlx')).default;
const { BlpImage } = require(path.join(ROOT, 'node_modules/mdx-m3-viewer/dist/cjs/parsers/blp/image'));
const sanityTest = require(path.join(ROOT, 'node_modules/mdx-m3-viewer/dist/cjs/utils/mdlx/sanitytest/sanitytest')).default;

// Flatten mdx-m3-viewer's sanity test tree into "kind: path: message" lines.
function sanity(model) {
  const out = { error: [], severe: [], warning: [], unused: [] };
  (function walk(node, trail) {
    for (const n of node.nodes) {
      if (n.type === 'node') walk(n, trail.concat(n.name));
      else out[n.type].push(`${trail.join(' > ')}: ${n.message}`);
    }
  }(sanityTest(model), []));
  return out;
}

// The BLP decoder needs ImageData; Node has none.
global.ImageData = class {
  constructor(w, h) { this.width = w; this.height = h; this.data = new Uint8ClampedArray(w * h * 4); }
};

function checkTexture(file) {
  const blp = new BlpImage();
  blp.load(new Uint8Array(fs.readFileSync(file)));
  const levels = blp.mipmaps();
  const top = blp.getMipmap(0);
  if (top.width !== blp.width || top.height !== blp.height) {
    throw new Error(`mip 0 is ${top.width}x${top.height}, header says ${blp.width}x${blp.height}`);
  }
  let expected = 1;
  for (let s = Math.max(blp.width, blp.height); s > 1; s >>= 1) expected++;
  if (levels !== expected) throw new Error(`${levels} mip levels, expected ${expected}`);
  for (let i = 1; i < levels; i++) {
    const m = blp.getMipmap(i);
    const w = Math.max(1, blp.width >> i), h = Math.max(1, blp.height >> i);
    if (m.width !== w || m.height !== h) throw new Error(`mip ${i} is ${m.width}x${m.height}, expected ${w}x${h}`);
  }
  let alphaMin = 255;
  for (let i = 3; i < top.data.length; i += 4) alphaMin = Math.min(alphaMin, top.data[i]);
  return { size: `${blp.width}x${blp.height}`, content: blp.content === 0 ? 'jpeg' : 'palette', mips: levels, alphaMin };
}

function check(file) {
  const problems = [];
  const bytes = new Uint8Array(fs.readFileSync(file));
  const model = new mdlx.Model();
  model.load(bytes);
  const saved = model.saveMdx();
  if (saved.length !== bytes.length || Buffer.compare(Buffer.from(saved), Buffer.from(bytes)) !== 0) {
    problems.push(`saveMdx() does not reproduce the file (${saved.length} vs ${bytes.length} bytes)`);
  }
  if (model.version !== 800) problems.push(`version ${model.version}`);
  const bones = model.bones.length;
  const objects = bones + model.lights.length + model.helpers.length + model.attachments.length +
    model.particleEmitters.length + model.particleEmitters2.length + model.ribbonEmitters.length +
    model.eventObjects.length + model.collisionShapes.length;
  if (model.pivotPoints.length !== objects) problems.push(`${model.pivotPoints.length} pivots for ${objects} objects`);
  const all = [...model.bones, ...model.helpers, ...model.attachments, ...model.collisionShapes];
  all.forEach((o, i) => {
    if (o.objectId !== i) problems.push(`${o.name}: objectId ${o.objectId}, expected ${i}`);
    if (o.parentId >= objects || o.parentId === o.objectId) problems.push(`${o.name}: bad parent ${o.parentId}`);
  });
  let vertices = 0, triangles = 0, maxGroup = 0;
  model.geosets.forEach((g, gi) => {
    const nv = g.vertices.length / 3;
    vertices += nv;
    triangles += g.faces.length / 3;
    if (g.normals.length !== g.vertices.length) problems.push(`geoset ${gi}: normals count`);
    if (g.uvSets.length !== 1 || g.uvSets[0].length !== nv * 2) problems.push(`geoset ${gi}: uv count`);
    if (g.vertexGroups.length !== nv) problems.push(`geoset ${gi}: vertex group count`);
    for (const f of g.faces) if (f >= nv) { problems.push(`geoset ${gi}: face index ${f} >= ${nv}`); break; }
    for (const vg of g.vertexGroups) if (vg >= g.matrixGroups.length) { problems.push(`geoset ${gi}: vertex group ${vg}`); break; }
    let total = 0;
    for (const s of g.matrixGroups) { total += s; maxGroup = Math.max(maxGroup, s); }
    if (total !== g.matrixIndices.length) problems.push(`geoset ${gi}: matrix group sizes`);
    for (const m of g.matrixIndices) if (m >= bones) { problems.push(`geoset ${gi}: matrix index ${m}`); break; }
    if (g.materialId >= model.materials.length) problems.push(`geoset ${gi}: material ${g.materialId}`);
    if (g.sequenceExtents.length !== model.sequences.length) problems.push(`geoset ${gi}: sequence extents`);
    for (let i = 0; i < g.vertices.length; i++) if (!Number.isFinite(g.vertices[i])) { problems.push(`geoset ${gi}: NaN vertex`); break; }
  });
  model.materials.forEach((m, mi) => m.layers.forEach((l) => {
    if (l.textureId < 0 || l.textureId >= model.textures.length) problems.push(`material ${mi}: texture ${l.textureId}`);
  }));
  let prevEnd = -1;
  const seqs = model.sequences.map((s) => {
    if (s.interval[1] <= s.interval[0]) problems.push(`${s.name}: empty interval`);
    if (s.interval[0] <= prevEnd) problems.push(`${s.name}: overlaps the previous sequence`);
    prevEnd = s.interval[1];
    return { name: s.name, interval: Array.from(s.interval), loop: !s.nonLooping, rarity: s.rarity };
  });
  let keys = 0;
  for (const o of all) {
    for (const a of o.animations) {
      keys += a.frames.length;
      for (const f of a.frames) {
        if (!model.sequences.some((s) => f >= s.interval[0] && f <= s.interval[1])) {
          problems.push(`${o.name} ${a.name}: key at ${f} outside every sequence`);
          break;
        }
      }
      for (const v of a.values) if (!Array.from(v).every(Number.isFinite)) { problems.push(`${o.name} ${a.name}: NaN`); break; }
    }
  }
  const sane = sanity(model);
  for (const m of sane.error.concat(sane.severe)) problems.push(`sanity test: ${m}`);
  const textures = {};
  for (const t of model.textures) {
    const local = path.join(path.dirname(file), path.basename(t.path.replace(/\\/g, '/')));
    try {
      textures[t.path] = checkTexture(local);
    } catch (e) {
      problems.push(`texture ${t.path}: ${e.message}`);
    }
  }
  return {
    ok: problems.length === 0,
    problems,
    summary: {
      bytes: bytes.length, version: model.version, name: model.name, bones, vertices, triangles,
      geosets: model.geosets.length, materials: model.materials.length, maxGroupSize: maxGroup,
      attachments: model.attachments.map((a) => a.name), cameras: model.cameras.length,
      collisionShapes: model.collisionShapes.length, keys, sequences: seqs, textures,
      sanityWarnings: sane.warning, sanityUnused: sane.unused.length,
      extent: { radius: model.extent.boundsRadius, min: Array.from(model.extent.min), max: Array.from(model.extent.max) },
    },
  };
}

const out = {};
for (const file of process.argv.slice(2)) {
  try {
    out[file] = check(file);
  } catch (e) {
    out[file] = { ok: false, problems: [`parse failed: ${e.stack}`] };
  }
}
process.stdout.write(JSON.stringify(out, null, 1));
process.exitCode = Object.values(out).every((r) => r.ok) ? 0 : 1;
