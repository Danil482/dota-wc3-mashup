// Round-trip each map file through mdx-m3-viewer: load then save, compare bytes.
const fs = require('fs');
const P = 'mdx-m3-viewer/dist/cjs/parsers';
const MpqArchive = require(`${P}/mpq/archive`).default;
const kinds = {
  'war3map.w3i': [require(`${P}/w3x/w3i/file`).default, (o, b) => o.load(b), (o) => o.save()],
  'war3map.w3e': [require(`${P}/w3x/w3e/file`).default, (o, b) => o.load(b), (o) => o.save()],
  'war3map.wpm': [require(`${P}/w3x/wpm/file`).default, (o, b) => o.load(b), (o) => o.save()],
  'war3map.doo': [require(`${P}/w3x/doo/file`).default, (o, b) => o.load(b, 6105), (o) => o.save(6105)],
};
const mpq = new MpqArchive();
mpq.load(new Uint8Array(fs.readFileSync(process.argv[2])), true);
for (const [name, [Cls, load, save]] of Object.entries(kinds)) {
  const orig = mpq.get(name).bytes();
  const o = new Cls(); load(o, orig);
  const out = save(o);
  let diff = -1;
  for (let i = 0; i < Math.max(orig.length, out.length); i++) if (orig[i] !== out[i]) { diff = i; break; }
  console.log(name, 'orig', orig.length, 'saved', out.length, diff < 0 ? 'IDENTICAL' : `first diff at ${diff}`);
}
