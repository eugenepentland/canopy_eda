#!/usr/bin/env node
"use strict";

// Deterministic, copyright-clean datasheet workload for the headless PDF-viewer
// gate. All prose, vector geometry, and RGB pixels are generated below; there
// are no third-party fixture bytes or timestamps in the output.
const fs = require("fs");
const path = require("path");

const PAGE_COUNT = 4;
const TABLE_ROWS = 18;
const TABLE_COLUMNS = 6;
const DENSE_LINES = 14;
const VECTOR_SEGMENTS = 64;
const IMAGE_WIDTH = 160;
const IMAGE_HEIGHT = 120;
const WORKLOAD_MARKER = `%NETLISP_BROWSER_PERF_WORKLOAD_V2 pages=${PAGE_COUNT} table_rows=${TABLE_ROWS} table_columns=${TABLE_COLUMNS} dense_lines=${DENSE_LINES} vector_segments=${VECTOR_SEGMENTS} images=${PAGE_COUNT} image_pixels=${IMAGE_WIDTH}x${IMAGE_HEIGHT}`;

function pdfText(value) {
  return String(value).replaceAll("\\", "\\\\").replaceAll("(", "\\(").replaceAll(")", "\\)");
}

function textRun(font, size, x, y, value) {
  return `BT /${font} ${size} Tf ${x} ${y} Td (${pdfText(value)}) Tj ET`;
}

function imagePixels(pageNumber) {
  const pixels = Buffer.alloc(IMAGE_WIDTH * IMAGE_HEIGHT * 3);
  let offset = 0;
  for (let y = 0; y < IMAGE_HEIGHT; y++) {
    for (let x = 0; x < IMAGE_WIDTH; x++) {
      const checker = ((x >> 3) ^ (y >> 3) ^ pageNumber) & 1;
      pixels[offset++] = (x * 5 + y + pageNumber * 37) & 255;
      pixels[offset++] = (y * 7 + x * 2 + pageNumber * 53) & 255;
      pixels[offset++] = checker ? (180 + pageNumber * 13) & 255 : (x + y * 3) & 255;
    }
  }
  return pixels;
}

function tableValue(pageNumber, row, column) {
  const values = [
    `P${String(row + 1).padStart(2, "0")}`,
    `SIG_${pageNumber}_${String(row + 1).padStart(2, "0")}`,
    `${(0.45 + row * 0.07).toFixed(2)}`,
    `${(1.20 + pageNumber * 0.15 + row * 0.03).toFixed(2)}`,
    `${(2.75 + row * 0.11).toFixed(2)}`,
    row % 3 === 0 ? "critical" : row % 3 === 1 ? "measured" : "nominal",
  ];
  return values[column];
}

function pageContent(pageNumber, imageName) {
  const lines = [
    "q 0.965 0.975 0.985 rg 0 0 612 792 re f Q",
    "0.10 0.16 0.24 rg 36 738 540 34 re f",
    "1 1 1 rg",
    textRun("F1", 18, 48, 749, `Netlisp component datasheet benchmark - page ${pageNumber}`),
    "0.10 0.16 0.24 rg",
    textRun("F1", 9, 48, 720, "Synthetic engineering content for deterministic browser rendering and text-layer timing"),
  ];

  for (let row = 0; row < DENSE_LINES; row++) {
    const column = row < DENSE_LINES / 2 ? 48 : 316;
    const localRow = row % (DENSE_LINES / 2);
    const y = 702 - localRow * 12;
    lines.push(textRun("F2", 7, column, y,
      `Requirement ${pageNumber}.${String(row + 1).padStart(2, "0")}  limit=${(pageNumber * 0.25 + row * 0.031).toFixed(3)}  tolerance=${(1 + row % 5).toFixed(1)}%`));
  }

  const tableLeft = 48, tableTop = 606, tableWidth = 516, rowHeight = 14;
  const columnWidth = tableWidth / TABLE_COLUMNS;
  lines.push("0.82 0.86 0.90 RG 0.35 w");
  for (let row = 0; row <= TABLE_ROWS; row++) {
    const y = tableTop - row * rowHeight;
    lines.push(`${tableLeft} ${y} m ${tableLeft + tableWidth} ${y} l S`);
  }
  for (let column = 0; column <= TABLE_COLUMNS; column++) {
    const x = tableLeft + column * columnWidth;
    lines.push(`${x} ${tableTop} m ${x} ${tableTop - TABLE_ROWS * rowHeight} l S`);
  }
  lines.push("0.10 0.16 0.24 rg");
  for (let row = 0; row < TABLE_ROWS; row++) {
    for (let column = 0; column < TABLE_COLUMNS; column++) {
      lines.push(textRun("F2", 6.3, tableLeft + column * columnWidth + 3,
        tableTop - row * rowHeight - 10, tableValue(pageNumber, row, column)));
    }
  }

  const graphLeft = 48, graphBottom = 66, graphWidth = 330, graphHeight = 238;
  lines.push("0.88 0.90 0.93 RG 0.4 w");
  for (let i = 0; i <= 10; i++) {
    const x = graphLeft + i * graphWidth / 10;
    lines.push(`${x.toFixed(2)} ${graphBottom} m ${x.toFixed(2)} ${graphBottom + graphHeight} l S`);
  }
  for (let i = 0; i <= 8; i++) {
    const y = graphBottom + i * graphHeight / 8;
    lines.push(`${graphLeft} ${y.toFixed(2)} m ${graphLeft + graphWidth} ${y.toFixed(2)} l S`);
  }
  lines.push("0.08 0.42 0.70 RG 1.3 w");
  for (let segment = 0; segment <= VECTOR_SEGMENTS; segment++) {
    const x = graphLeft + segment * graphWidth / VECTOR_SEGMENTS;
    const wave = Math.sin((segment + pageNumber * 3) / 5) * 0.34 + Math.cos(segment / 9) * 0.18;
    const y = graphBottom + graphHeight * (0.5 + wave);
    lines.push(`${x.toFixed(2)} ${y.toFixed(2)} ${segment === 0 ? "m" : "l"}`);
  }
  lines.push("S");
  lines.push("0.96 0.45 0.12 rg 0.96 0.45 0.12 RG");
  for (let point = 0; point < 12; point++) {
    const x = graphLeft + 14 + point * 27;
    const y = graphBottom + 30 + ((point * 31 + pageNumber * 17) % 170);
    lines.push(`${x} ${y + 3} m ${x + 3} ${y} l ${x} ${y - 3} l ${x - 3} ${y} l h f`);
  }

  lines.push(`q ${IMAGE_WIDTH} 0 0 ${IMAGE_HEIGHT} 404 154 cm /${imageName} Do Q`);
  lines.push("0.10 0.16 0.24 RG 0.8 w 404 154 160 120 re S");
  lines.push(textRun("F1", 8, 404, 140, `Deterministic RGB response map ${pageNumber}`));
  lines.push(textRun("F2", 6.5, 404, 126, `${IMAGE_WIDTH}x${IMAGE_HEIGHT} pixels / distinct page payload`));
  lines.push(textRun("F2", 6.5, 404, 106, `vector segments ${VECTOR_SEGMENTS} / table cells ${TABLE_ROWS * TABLE_COLUMNS}`));
  return Buffer.from(`${lines.join("\n")}\n`, "ascii");
}

function stream(dictionary, bytes) {
  return Buffer.concat([
    Buffer.from(`<< ${dictionary} /Length ${bytes.length} >>\nstream\n`, "ascii"),
    bytes,
    Buffer.from("\nendstream", "ascii"),
  ]);
}

function buildPdf() {
  const objects = [null];
  const add = (body = null) => {
    objects.push(body);
    return objects.length - 1;
  };
  const catalogId = add();
  const pagesId = add();
  const helveticaId = add(Buffer.from("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>", "ascii"));
  const courierId = add(Buffer.from("<< /Type /Font /Subtype /Type1 /BaseFont /Courier >>", "ascii"));
  const pageIds = [];

  for (let pageNumber = 1; pageNumber <= PAGE_COUNT; pageNumber++) {
    const imageName = `Im${pageNumber}`;
    const pixels = imagePixels(pageNumber);
    const imageId = add(stream(`/Type /XObject /Subtype /Image /Width ${IMAGE_WIDTH} /Height ${IMAGE_HEIGHT} /ColorSpace /DeviceRGB /BitsPerComponent 8`, pixels));
    const contentId = add(stream("", pageContent(pageNumber, imageName)));
    const pageId = add(Buffer.from(
      `<< /Type /Page /Parent ${pagesId} 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 ${helveticaId} 0 R /F2 ${courierId} 0 R >> /XObject << /${imageName} ${imageId} 0 R >> >> /Contents ${contentId} 0 R >>`,
      "ascii"));
    pageIds.push(pageId);
  }

  const infoId = add(Buffer.from("<< /Title (Synthetic browser performance datasheet) /Producer (In-repo deterministic Node generator) >>", "ascii"));
  objects[catalogId] = Buffer.from(`<< /Type /Catalog /Pages ${pagesId} 0 R >>`, "ascii");
  objects[pagesId] = Buffer.from(`<< /Type /Pages /Kids [${pageIds.map((id) => `${id} 0 R`).join(" ")}] /Count ${PAGE_COUNT} >>`, "ascii");

  const chunks = [Buffer.from(`%PDF-1.4\n%\xE2\xE3\xCF\xD3\n${WORKLOAD_MARKER}\n`, "binary")];
  const offsets = [0];
  let length = chunks[0].length;
  for (let id = 1; id < objects.length; id++) {
    offsets[id] = length;
    const object = Buffer.concat([Buffer.from(`${id} 0 obj\n`, "ascii"), objects[id], Buffer.from("\nendobj\n", "ascii")]);
    chunks.push(object);
    length += object.length;
  }
  const xrefOffset = length;
  const xrefRows = offsets.slice(1).map((offset) => `${String(offset).padStart(10, "0")} 00000 n \n`).join("");
  chunks.push(Buffer.from(
    `xref\n0 ${objects.length}\n0000000000 65535 f \n${xrefRows}trailer\n<< /Size ${objects.length} /Root ${catalogId} 0 R /Info ${infoId} 0 R >>\nstartxref\n${xrefOffset}\n%%EOF\n`,
    "ascii"));
  return Buffer.concat(chunks);
}

if (require.main === module) {
  const destination = path.join(__dirname, "datasheet.pdf");
  const pdf = buildPdf();
  fs.writeFileSync(destination, pdf);
  process.stdout.write(`generated ${destination} (${pdf.length} bytes)\n`);
}

module.exports = { WORKLOAD_MARKER, buildPdf };
