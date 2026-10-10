// Extract every named file of a map archive into a folder.
// Usage: node extract_map.js <map.w3x> <out folder>
const fs = require('fs');
const path = require('path');
const MpqArchive = require('mdx-m3-viewer/dist/cjs/parsers/mpq/archive').default;
const [src, out] = process.argv.slice(2);
const m = new MpqArchive();
m.load(new Uint8Array(fs.readFileSync(src)), true);
fs.rmSync(out, { recursive: true, force: true });
for (const name of m.getFileNames()) {
  if (name.startsWith('File0') || name === '(listfile)' || name === '(attributes)') continue;
  const dest = path.join(out, ...name.split(String.fromCharCode(92)));
  fs.mkdirSync(path.dirname(dest), { recursive: true });
  fs.writeFileSync(dest, Buffer.from(m.get(name).bytes()));
}
console.log('extracted', src);
