"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const vm = require("node:vm");
const zlib = require("node:zlib");
const { withPngPhysicalResolution, makeZip } = require("./pcb_fusion_bundle.js");

const PNG_SIGNATURE = Uint8Array.from([137, 80, 78, 71, 13, 10, 26, 10]);

const browserGlobal = {};
browserGlobal.window = browserGlobal;
browserGlobal.self = browserGlobal;
vm.runInNewContext(fs.readFileSync(require.resolve("./pcb_fusion_bundle.js"), "utf8"), browserGlobal);
assert.equal(typeof browserGlobal.window.PCBFusionBundle.withPngPhysicalResolution, "function");
assert.equal(typeof browserGlobal.window.PCBFusionBundle.makeZip, "function");

function crc32(bytes, start = 0, end = bytes.length) {
  let crc = 0xffffffff;
  for (let i = start; i < end; i++) {
    crc ^= bytes[i];
    for (let bit = 0; bit < 8; bit++) {
      crc = crc & 1 ? 0xedb88320 ^ (crc >>> 1) : crc >>> 1;
    }
  }
  return (crc ^ 0xffffffff) >>> 0;
}

function readU16LE(bytes, offset) {
  return bytes[offset] | (bytes[offset + 1] << 8);
}

function readU32LE(bytes, offset) {
  return (bytes[offset] + bytes[offset + 1] * 0x100 +
    bytes[offset + 2] * 0x10000 + bytes[offset + 3] * 0x1000000) >>> 0;
}

function readU32BE(bytes, offset) {
  return (bytes[offset] * 0x1000000 + (bytes[offset + 1] << 16) +
    (bytes[offset + 2] << 8) + bytes[offset + 3]) >>> 0;
}

function writeU32BE(bytes, offset, value) {
  bytes[offset] = value >>> 24;
  bytes[offset + 1] = value >>> 16;
  bytes[offset + 2] = value >>> 8;
  bytes[offset + 3] = value;
}

function concat(parts) {
  const length = parts.reduce((sum, part) => sum + part.length, 0);
  const out = new Uint8Array(length);
  let offset = 0;
  for (const part of parts) { out.set(part, offset); offset += part.length; }
  return out;
}

function pngChunk(type, data) {
  const typeBytes = new TextEncoder().encode(type);
  const out = new Uint8Array(data.length + 12);
  writeU32BE(out, 0, data.length);
  out.set(typeBytes, 4);
  out.set(data, 8);
  writeU32BE(out, 8 + data.length, crc32(out, 4, 8 + data.length));
  return out;
}

function makePng(includePhysical) {
  const ihdr = new Uint8Array(13);
  writeU32BE(ihdr, 0, 1);
  writeU32BE(ihdr, 4, 1);
  ihdr[8] = 8;
  ihdr[9] = 6;
  const scanline = Uint8Array.from([0, 12, 34, 56, 255]);
  const pieces = [
    PNG_SIGNATURE,
    pngChunk("IHDR", ihdr),
    pngChunk("tEXt", new TextEncoder().encode("Source\0Canopy")),
  ];
  if (includePhysical) {
    const old = new Uint8Array(9);
    writeU32BE(old, 0, 72);
    writeU32BE(old, 4, 73);
    old[8] = 0;
    pieces.push(pngChunk("pHYs", old));
  }
  pieces.push(
    pngChunk("IDAT", new Uint8Array(zlib.deflateSync(scanline))),
    pngChunk("IEND", new Uint8Array()),
  );
  return concat(pieces);
}

function parsePng(bytes) {
  assert.deepEqual(bytes.subarray(0, 8), PNG_SIGNATURE);
  const chunks = [];
  let offset = 8;
  while (offset < bytes.length) {
    const length = readU32BE(bytes, offset);
    const type = new TextDecoder().decode(bytes.subarray(offset + 4, offset + 8));
    const end = offset + 12 + length;
    assert.equal(readU32BE(bytes, offset + 8 + length), crc32(bytes, offset + 4, offset + 8 + length),
      `${type} has a valid CRC`);
    chunks.push({ type, start: offset, end, data: bytes.subarray(offset + 8, offset + 8 + length) });
    offset = end;
  }
  return chunks;
}

function nonPhysicalRaw(bytes) {
  return parsePng(bytes).filter((chunk) => chunk.type !== "pHYs")
    .map((chunk) => Array.from(bytes.subarray(chunk.start, chunk.end)));
}

async function testPngResolution() {
  const source = makePng(true);
  const converted = await withPngPhysicalResolution(new Blob([source]), { x: 32001, y: 31999 });
  assert.equal(converted.type, "image/png");
  const bytes = new Uint8Array(await converted.arrayBuffer());
  const chunks = parsePng(bytes);
  assert.deepEqual(chunks.map((chunk) => chunk.type), ["IHDR", "pHYs", "tEXt", "IDAT", "IEND"]);
  const physical = chunks.filter((chunk) => chunk.type === "pHYs");
  assert.equal(physical.length, 1, "existing pHYs is replaced, not duplicated");
  assert.equal(readU32BE(physical[0].data, 0), 32001);
  assert.equal(readU32BE(physical[0].data, 4), 31999);
  assert.equal(physical[0].data[8], 1, "physical unit is metres");
  assert.deepEqual(nonPhysicalRaw(bytes), nonPhysicalRaw(source),
    "every non-pHYs chunk, including its original CRC, remains byte-identical");

  const withoutPhysical = makePng(false);
  const padded = new Uint8Array(withoutPhysical.length + 7);
  padded.set(withoutPhysical, 3);
  const scalar = await withPngPhysicalResolution(padded.subarray(3, 3 + withoutPhysical.length), 40000);
  const scalarChunks = parsePng(new Uint8Array(await scalar.arrayBuffer()));
  assert.equal(readU32BE(scalarChunks[1].data, 0), 40000);
  assert.equal(readU32BE(scalarChunks[1].data, 4), 40000);
  await assert.rejects(withPngPhysicalResolution(withoutPhysical, { x: 0, y: 1 }), RangeError);
}

function parseStoredZip(bytes) {
  assert.ok(bytes.length >= 22);
  const end = bytes.length - 22;
  assert.equal(readU32LE(bytes, end), 0x06054b50, "ZIP ends with EOCD");
  assert.equal(readU16LE(bytes, end + 4), 0);
  assert.equal(readU16LE(bytes, end + 6), 0);
  const count = readU16LE(bytes, end + 10);
  const centralSize = readU32LE(bytes, end + 12);
  const centralOffset = readU32LE(bytes, end + 16);
  assert.equal(centralOffset + centralSize, end);

  const local = [], byOffset = new Map();
  let offset = 0;
  while (offset < centralOffset) {
    const localOffset = offset;
    assert.equal(readU32LE(bytes, offset), 0x04034b50);
    assert.equal(readU16LE(bytes, offset + 6), 0x0800, "UTF-8 filename flag is set");
    assert.equal(readU16LE(bytes, offset + 8), 0, "entry is stored without compression");
    const expectedCrc = readU32LE(bytes, offset + 14);
    const compressedSize = readU32LE(bytes, offset + 18);
    const size = readU32LE(bytes, offset + 22);
    assert.equal(compressedSize, size);
    const nameLength = readU16LE(bytes, offset + 26);
    const extraLength = readU16LE(bytes, offset + 28);
    const nameStart = offset + 30;
    const dataStart = nameStart + nameLength + extraLength;
    const name = new TextDecoder().decode(bytes.subarray(nameStart, nameStart + nameLength));
    const data = bytes.slice(dataStart, dataStart + size);
    assert.equal(crc32(data), expectedCrc, `${name} has a valid CRC`);
    const entry = { name, data, crc: expectedCrc, size, localOffset };
    local.push(entry);
    byOffset.set(localOffset, entry);
    offset = dataStart + size;
  }

  let central = centralOffset;
  for (let index = 0; index < count; index++) {
    assert.equal(readU32LE(bytes, central), 0x02014b50);
    assert.equal(readU16LE(bytes, central + 8), 0x0800);
    assert.equal(readU16LE(bytes, central + 10), 0);
    const nameLength = readU16LE(bytes, central + 28);
    const extraLength = readU16LE(bytes, central + 30);
    const commentLength = readU16LE(bytes, central + 32);
    const name = new TextDecoder().decode(bytes.subarray(central + 46, central + 46 + nameLength));
    const entry = byOffset.get(readU32LE(bytes, central + 42));
    assert.ok(entry, `${name} central record points at a local record`);
    assert.equal(name, entry.name);
    assert.equal(readU32LE(bytes, central + 16), entry.crc);
    assert.equal(readU32LE(bytes, central + 24), entry.size);
    central += 46 + nameLength + extraLength + commentLength;
  }
  assert.equal(central, end);
  assert.equal(local.length, count);
  return local;
}

async function testZip() {
  const top = Uint8Array.from([0, 1, 2, 255]);
  const bottomBacking = Uint8Array.from([99, 10, 20, 30, 88]);
  const zip = await makeZip([
    { name: "Barracuda top μ.png", data: new Blob([top]) },
    { name: "bottom.png", data: bottomBacking.subarray(1, 4) },
    { name: "README.txt", data: "Fusion decal artwork" },
  ]);
  assert.equal(zip.type, "application/zip");
  const entries = parseStoredZip(new Uint8Array(await zip.arrayBuffer()));
  assert.deepEqual(entries.map((entry) => entry.name), ["Barracuda top μ.png", "bottom.png", "README.txt"]);
  assert.deepEqual(entries[0].data, top);
  assert.deepEqual(entries[1].data, Uint8Array.from([10, 20, 30]));
  assert.equal(new TextDecoder().decode(entries[2].data), "Fusion decal artwork");

  const empty = new Uint8Array(await (await makeZip([])).arrayBuffer());
  assert.deepEqual(parseStoredZip(empty), [], "an empty archive is valid");
  await assert.rejects(makeZip([{ name: "same", data: "a" }, { name: "same", data: "b" }]),
    /duplicate ZIP entry/);
}

Promise.all([testPngResolution(), testZip()]).then(() => {
  console.log("Fusion artwork bundle: PNG pHYs and stored UTF-8 ZIP records are valid");
}).catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
