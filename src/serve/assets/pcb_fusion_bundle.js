/* Browser-only binary helpers for Fusion 360 artwork companion files.
 *
 * PNG has no physical size unless a pHYs chunk supplies pixels per metre.
 * Fusion can then place the exported top/bottom artwork at the board's scale.
 * The ZIP writer is deliberately dependency-free and uses stored (uncompressed)
 * entries so the two artwork files can be downloaded as one browser Blob.
 */
(function (root, factory) {
  var api = factory();
  if (typeof module === "object" && module.exports) module.exports = api;
  else root.PCBFusionBundle = api;
})(typeof self !== "undefined" ? self : this, function () {
  "use strict";

  var PNG_SIGNATURE = [137, 80, 78, 71, 13, 10, 26, 10];
  var UTF8_FLAG = 0x0800;
  var MAX_U16 = 0xffff;
  var MAX_U32 = 0xffffffff;
  var crcTable = null;

  function makeCrcTable() {
    var table = new Uint32Array(256);
    for (var n = 0; n < table.length; n++) {
      var value = n;
      for (var bit = 0; bit < 8; bit++) {
        value = value & 1 ? 0xedb88320 ^ (value >>> 1) : value >>> 1;
      }
      table[n] = value >>> 0;
    }
    return table;
  }

  function crc32(bytes, start, end) {
    if (!crcTable) crcTable = makeCrcTable();
    var crc = MAX_U32;
    start = start == null ? 0 : start;
    end = end == null ? bytes.length : end;
    for (var i = start; i < end; i++) {
      crc = crcTable[(crc ^ bytes[i]) & 0xff] ^ (crc >>> 8);
    }
    return (crc ^ MAX_U32) >>> 0;
  }

  function readU32BE(bytes, offset) {
    return ((bytes[offset] * 0x1000000) +
      (bytes[offset + 1] << 16) +
      (bytes[offset + 2] << 8) +
      bytes[offset + 3]) >>> 0;
  }

  function writeU16LE(bytes, offset, value) {
    bytes[offset] = value & 0xff;
    bytes[offset + 1] = (value >>> 8) & 0xff;
  }

  function writeU32LE(bytes, offset, value) {
    bytes[offset] = value & 0xff;
    bytes[offset + 1] = (value >>> 8) & 0xff;
    bytes[offset + 2] = (value >>> 16) & 0xff;
    bytes[offset + 3] = (value >>> 24) & 0xff;
  }

  function writeU32BE(bytes, offset, value) {
    bytes[offset] = (value >>> 24) & 0xff;
    bytes[offset + 1] = (value >>> 16) & 0xff;
    bytes[offset + 2] = (value >>> 8) & 0xff;
    bytes[offset + 3] = value & 0xff;
  }

  function ascii(bytes, offset, length) {
    var out = "";
    for (var i = 0; i < length; i++) out += String.fromCharCode(bytes[offset + i]);
    return out;
  }

  function textBytes(text) {
    if (typeof TextEncoder === "undefined") throw new Error("TextEncoder is unavailable");
    return new TextEncoder().encode(String(text));
  }

  async function inputBytes(value, allowString) {
    if (allowString && typeof value === "string") return textBytes(value);
    if (value instanceof ArrayBuffer) return new Uint8Array(value);
    if (ArrayBuffer.isView(value)) {
      return new Uint8Array(value.buffer, value.byteOffset, value.byteLength);
    }
    if (value && typeof value.arrayBuffer === "function") {
      return new Uint8Array(await value.arrayBuffer());
    }
    throw new TypeError("expected a Blob, string, ArrayBuffer, or byte view");
  }

  function densityValue(value, axis) {
    var rounded = Math.round(Number(value));
    if (!Number.isFinite(rounded) || rounded < 1 || rounded > MAX_U32) {
      throw new RangeError(axis + " pixels-per-metre must be between 1 and 4294967295");
    }
    return rounded;
  }

  function densities(value) {
    if (value != null && typeof value === "object") {
      return {
        x: densityValue(value.x, "x"),
        y: densityValue(value.y, "y"),
      };
    }
    var same = densityValue(value, "x/y");
    return { x: same, y: same };
  }

  function pngChunk(type, data) {
    var typeBytes = textBytes(type);
    if (typeBytes.length !== 4) throw new Error("PNG chunk type must contain four bytes");
    var out = new Uint8Array(12 + data.length);
    writeU32BE(out, 0, data.length);
    out.set(typeBytes, 4);
    out.set(data, 8);
    writeU32BE(out, 8 + data.length, crc32(out, 4, 8 + data.length));
    return out;
  }

  function parsePng(bytes) {
    if (bytes.length < PNG_SIGNATURE.length) throw new Error("not a PNG file");
    for (var i = 0; i < PNG_SIGNATURE.length; i++) {
      if (bytes[i] !== PNG_SIGNATURE[i]) throw new Error("not a PNG file");
    }

    var chunks = [], offset = PNG_SIGNATURE.length, sawEnd = false;
    while (offset < bytes.length) {
      if (offset + 12 > bytes.length) throw new Error("truncated PNG chunk header");
      var length = readU32BE(bytes, offset);
      var end = offset + 12 + length;
      if (end > bytes.length) throw new Error("truncated PNG chunk data");
      var type = ascii(bytes, offset + 4, 4);
      chunks.push({ type: type, start: offset, end: end, length: length });
      offset = end;
      if (type === "IEND") {
        if (length !== 0) throw new Error("invalid PNG IEND chunk");
        sawEnd = true;
        break;
      }
    }
    if (!sawEnd) throw new Error("PNG is missing IEND");
    if (offset !== bytes.length) throw new Error("PNG has data after IEND");
    if (!chunks.length || chunks[0].type !== "IHDR" || chunks[0].length !== 13) {
      throw new Error("PNG must begin with a 13-byte IHDR chunk");
    }
    return chunks;
  }

  /**
   * Return a PNG Blob with one metre-based pHYs chunk. A scalar applies to
   * both axes; {x, y} permits exact independent canvas-to-board scaling.
   * Non-pHYs chunks are copied byte-for-byte, including their original CRCs.
   */
  async function withPngPhysicalResolution(blobOrBytes, pixelsPerMetre) {
    var bytes = await inputBytes(blobOrBytes, false);
    var chunks = parsePng(bytes);
    var ppm = densities(pixelsPerMetre);
    var physical = new Uint8Array(9);
    writeU32BE(physical, 0, ppm.x);
    writeU32BE(physical, 4, ppm.y);
    physical[8] = 1; // PNG unit specifier 1 means metres.
    var replacement = pngChunk("pHYs", physical);

    var parts = [bytes.subarray(0, PNG_SIGNATURE.length)];
    chunks.forEach(function (chunk, index) {
      if (chunk.type !== "pHYs") parts.push(bytes.subarray(chunk.start, chunk.end));
      // pHYs is valid before PLTE/IDAT; placing it directly after IHDR also
      // normalizes malformed inputs that carried it too late in the stream.
      if (index === 0) parts.push(replacement);
    });
    return new Blob(parts, { type: "image/png" });
  }

  function zipLocalHeader(nameLength, size, crc) {
    var out = new Uint8Array(30);
    writeU32LE(out, 0, 0x04034b50);
    writeU16LE(out, 4, 20); // version needed: ZIP 2.0
    writeU16LE(out, 6, UTF8_FLAG);
    writeU16LE(out, 8, 0); // stored, not compressed
    writeU16LE(out, 10, 0); // 00:00:00
    writeU16LE(out, 12, 0x21); // 1980-01-01
    writeU32LE(out, 14, crc);
    writeU32LE(out, 18, size);
    writeU32LE(out, 22, size);
    writeU16LE(out, 26, nameLength);
    writeU16LE(out, 28, 0);
    return out;
  }

  function zipCentralHeader(nameLength, size, crc, localOffset) {
    var out = new Uint8Array(46);
    writeU32LE(out, 0, 0x02014b50);
    writeU16LE(out, 4, 20); // made by ZIP 2.0 on FAT-compatible host
    writeU16LE(out, 6, 20);
    writeU16LE(out, 8, UTF8_FLAG);
    writeU16LE(out, 10, 0);
    writeU16LE(out, 12, 0);
    writeU16LE(out, 14, 0x21);
    writeU32LE(out, 16, crc);
    writeU32LE(out, 20, size);
    writeU32LE(out, 24, size);
    writeU16LE(out, 28, nameLength);
    writeU16LE(out, 30, 0);
    writeU16LE(out, 32, 0);
    writeU16LE(out, 34, 0);
    writeU16LE(out, 36, 0);
    writeU32LE(out, 38, 0);
    writeU32LE(out, 42, localOffset);
    return out;
  }

  function zipEnd(entryCount, centralSize, centralOffset) {
    var out = new Uint8Array(22);
    writeU32LE(out, 0, 0x06054b50);
    writeU16LE(out, 4, 0);
    writeU16LE(out, 6, 0);
    writeU16LE(out, 8, entryCount);
    writeU16LE(out, 10, entryCount);
    writeU32LE(out, 12, centralSize);
    writeU32LE(out, 16, centralOffset);
    writeU16LE(out, 20, 0);
    return out;
  }

  /** Build a standards-compliant, uncompressed ZIP Blob from {name, data}. */
  async function makeZip(entries) {
    if (!Array.isArray(entries)) throw new TypeError("ZIP entries must be an array");
    if (entries.length > MAX_U16) throw new RangeError("ZIP has too many entries");

    var prepared = [], names = new Set();
    for (var i = 0; i < entries.length; i++) {
      var entry = entries[i];
      if (!entry || typeof entry.name !== "string" || !entry.name.length) {
        throw new TypeError("each ZIP entry needs a non-empty name");
      }
      if (names.has(entry.name)) throw new Error("duplicate ZIP entry name: " + entry.name);
      names.add(entry.name);
      var name = textBytes(entry.name);
      if (name.length > MAX_U16) throw new RangeError("ZIP entry name is too long");
      var data = await inputBytes(entry.data, true);
      if (data.length > MAX_U32) throw new RangeError("ZIP entry is too large");
      prepared.push({ name: name, data: data, crc: crc32(data) });
    }

    var localParts = [], centralParts = [], localOffset = 0;
    prepared.forEach(function (entry) {
      var local = zipLocalHeader(entry.name.length, entry.data.length, entry.crc);
      var central = zipCentralHeader(entry.name.length, entry.data.length, entry.crc, localOffset);
      localParts.push(local, entry.name, entry.data);
      centralParts.push(central, entry.name);
      localOffset += local.length + entry.name.length + entry.data.length;
      if (localOffset > MAX_U32) throw new RangeError("ZIP local data is too large");
    });

    var centralSize = 0;
    centralParts.forEach(function (part) { centralSize += part.length; });
    if (centralSize > MAX_U32 || localOffset + centralSize + 22 > MAX_U32) {
      throw new RangeError("ZIP central directory is too large");
    }
    return new Blob(localParts.concat(centralParts, [
      zipEnd(prepared.length, centralSize, localOffset),
    ]), { type: "application/zip" });
  }

  return {
    withPngPhysicalResolution: withPngPhysicalResolution,
    makeZip: makeZip,
  };
});
