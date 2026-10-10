// Read a map with mdx-m3-viewer's MPQ reader (the library that writes the
// base map) and print {name: {size, sha256}} for every file in (listfile).
// Usage: node launcher/tests/verify_mpq.js <map.w3x>
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const ROOT = path.resolve(__dirname, '..', '..');
const MpqArchive = require(path.join(ROOT, 'tools/node_modules/mdx-m3-viewer/dist/cjs/parsers/mpq/archive')).default;

const archive = new MpqArchive();
archive.load(new Uint8Array(fs.readFileSync(process.argv[2])), true);
const listfile = archive.get('(listfile)');
if (!listfile) {
  throw new Error('no (listfile)');
}
const names = listfile.text().split('\r\n').filter((n) => n.length > 0);
const out = { hashTable: archive.hashTable.entries.length, blockTable: archive.blockTable.entries.length, files: {} };
for (const name of names) {
  const file = archive.get(name);
  if (!file) {
    throw new Error(`listed but not found: ${name}`);
  }
  const bytes = file.bytes();
  out.files[name] = { size: bytes.byteLength, sha256: crypto.createHash('sha256').update(bytes).digest('hex') };
}
process.stdout.write(JSON.stringify(out));
