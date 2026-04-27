const std = @import("std");
const httpz = @import("httpz");
const serve_root = @import("../serve.zig");
const Handler = serve_root.Handler;

/// Error set for HTTP handlers in this module.
pub const HandlerError = std.mem.Allocator.Error || std.Io.Writer.Error;

/// GET /pdf-view/:filename — interactive datasheet viewer backed by PDF.js
/// loaded from jsDelivr. Query params: `page=N` (1-based; jump on load) and
/// `highlight=S` (substring to mark; first hit is scrolled into view). The
/// underlying PDF is fetched from the existing `/datasheets/:filename` route.
///
/// Used by hub `(requirement …)` rows and section `(note …)` rows so a
/// click lands on the cited page with the rule highlighted, instead of
/// Chrome's native viewer which ignores `#search=` fragments.
pub fn pdfViewerPage(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const filename = req.param("filename") orelse {
        res.status = 404;
        return;
    };
    if (filename.len == 0 or std.mem.indexOfAny(u8, filename, "/\\") != null or std.mem.indexOf(u8, filename, "..") != null) {
        res.status = 400;
        res.body = "invalid filename";
        return;
    }

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const w = buf.writer(ctx.allocator);

    try w.writeAll(HTML_PART_1);
    try writeHtmlEscaped(w, filename);
    try w.writeAll(HTML_PART_2);
    try writeHtmlEscaped(w, filename);
    try w.writeAll(HTML_PART_3);

    res.content_type = .HTML;
    res.body = buf.items;
}

fn writeHtmlEscaped(w: anytype, s: []const u8) !void {
    for (s) |c| switch (c) {
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        '&' => try w.writeAll("&amp;"),
        '"' => try w.writeAll("&quot;"),
        '\'' => try w.writeAll("&#39;"),
        else => try w.writeByte(c),
    };
}

// Filename injects in two places: the <title> and a body data-attribute the
// JS reads to wire up the toolbar without needing more split points.
const HTML_PART_1 =
    \\<!doctype html>
    \\<html lang="en"><head>
    \\<meta charset="utf-8">
    \\<meta name="viewport" content="width=device-width,initial-scale=1">
    \\<title>
;

const HTML_PART_2 = @embedFile("assets/pdf_viewer_part2.html");

const HTML_PART_3 =
    \\">
    \\<div id="toolbar">
    \\  <a id="back" href="javascript:history.back()">← back</a>
    \\  <span class="filename" id="filenameLabel"></span>
    \\  <span id="quoteLabel" class="quote-label" hidden></span>
    \\  <span id="matchCtrls" hidden>
    \\    <button id="prev" title="Previous match">▲</button>
    \\    <button id="next" title="Next match">▼</button>
    \\    <span id="count" class="match-count"></span>
    \\  </span>
    \\  <span class="spacer"></span>
    \\  <a id="rawLink" target="_blank" rel="noopener">Open raw PDF ↗</a>
    \\</div>
    \\<div id="viewer"></div>
    \\<div id="status">Loading…</div>
    \\<script type="module">
    \\import * as pdfjsLib from 'https://cdn.jsdelivr.net/npm/pdfjs-dist@4.10.38/build/pdf.min.mjs';
    \\pdfjsLib.GlobalWorkerOptions.workerSrc = 'https://cdn.jsdelivr.net/npm/pdfjs-dist@4.10.38/build/pdf.worker.min.mjs';
    \\
    \\const filename = document.body.dataset.pdf;
    \\const params = new URLSearchParams(location.search);
    \\const initialPage = Math.max(1, parseInt(params.get('page') || '1', 10));
    \\const initialHighlight = params.get('highlight') || '';
    \\
    \\const viewer = document.getElementById('viewer');
    \\const prevBtn = document.getElementById('prev');
    \\const nextBtn = document.getElementById('next');
    \\const countEl = document.getElementById('count');
    \\const matchCtrls = document.getElementById('matchCtrls');
    \\const quoteLabel = document.getElementById('quoteLabel');
    \\const status = document.getElementById('status');
    \\const filenameLabel = document.getElementById('filenameLabel');
    \\const rawLink = document.getElementById('rawLink');
    \\
    \\filenameLabel.textContent = filename;
    \\rawLink.href = '/datasheets/' + encodeURIComponent(filename);
    \\document.title = filename;
    \\if (initialHighlight) {
    \\  quoteLabel.textContent = '“' + initialHighlight + '”';
    \\  quoteLabel.title = initialHighlight;
    \\  quoteLabel.hidden = false;
    \\}
    \\
    \\const SCALE = 1.5;
    \\let pdfDoc = null;
    \\let pageRecords = [];
    \\const currentQuery = initialHighlight;
    \\let matches = [];
    \\let currentMatchIdx = -1;
    \\
    \\function setStatus(text, hide) {
    \\  status.textContent = text;
    \\  status.classList.toggle('hidden', !!hide);
    \\}
    \\
    \\async function loadPdf() {
    \\  setStatus('Loading PDF…');
    \\  const url = '/datasheets/' + encodeURIComponent(filename);
    \\  pdfDoc = await pdfjsLib.getDocument(url).promise;
    \\
    \\  // Use page 1's viewport as a placeholder size for every page so the
    \\  // page-container layout is correct before lazy-render fills it in.
    \\  const firstPage = await pdfDoc.getPage(1);
    \\  const firstVp = firstPage.getViewport({ scale: SCALE });
    \\
    \\  for (let p = 1; p <= pdfDoc.numPages; p++) {
    \\    const container = document.createElement('div');
    \\    container.className = 'page-container page-placeholder';
    \\    container.id = 'page-' + p;
    \\    container.style.width = firstVp.width + 'px';
    \\    container.style.height = firstVp.height + 'px';
    \\    container.textContent = 'p.' + p;
    \\    const label = document.createElement('div');
    \\    label.className = 'page-label';
    \\    label.textContent = 'p.' + p;
    \\    container.appendChild(label);
    \\    viewer.appendChild(container);
    \\    pageRecords.push({ pageNum: p, container, page: null, viewport: null, rendered: false, rendering: false });
    \\  }
    \\
    \\  // Lazy-render via IntersectionObserver. rootMargin pre-renders pages a
    \\  // viewport-and-a-half ahead so scrolling stays smooth.
    \\  const io = new IntersectionObserver((entries) => {
    \\    entries.forEach(e => {
    \\      if (e.isIntersecting) {
    \\        const rec = pageRecords.find(r => r.container === e.target);
    \\        if (rec && !rec.rendered && !rec.rendering) renderPage(rec);
    \\      }
    \\    });
    \\  }, { rootMargin: '1500px 0px' });
    \\  pageRecords.forEach(r => io.observe(r.container));
    \\
    \\  // Eagerly render the requested page so the initial scroll lands on
    \\  // real content (and so highlights can immediately scroll into view).
    \\  const target = pageRecords[Math.min(initialPage, pageRecords.length) - 1];
    \\  if (target) {
    \\    await renderPage(target);
    \\    target.container.scrollIntoView({ behavior: 'auto', block: 'start' });
    \\    if (currentQuery) {
    \\      const firstMatch = target.container.querySelector('.textLayer mark.match');
    \\      if (firstMatch) {
    \\        const idx = matches.indexOf(firstMatch);
    \\        if (idx >= 0) setCurrent(idx, false);
    \\        firstMatch.scrollIntoView({ behavior: 'smooth', block: 'center' });
    \\      }
    \\    }
    \\  }
    \\  setStatus('', true);
    \\}
    \\
    \\async function renderPage(rec) {
    \\  if (rec.rendered || rec.rendering) return;
    \\  rec.rendering = true;
    \\  try {
    \\    const page = rec.page || await pdfDoc.getPage(rec.pageNum);
    \\    rec.page = page;
    \\    const viewport = page.getViewport({ scale: SCALE });
    \\    rec.viewport = viewport;
    \\    rec.container.style.width = viewport.width + 'px';
    \\    rec.container.style.height = viewport.height + 'px';
    \\    rec.container.classList.remove('page-placeholder');
    \\    // Clear placeholder text, keep label.
    \\    Array.from(rec.container.childNodes).forEach(n => {
    \\      if (n.nodeType === Node.TEXT_NODE) rec.container.removeChild(n);
    \\    });
    \\
    \\    const canvas = document.createElement('canvas');
    \\    canvas.width = viewport.width;
    \\    canvas.height = viewport.height;
    \\    rec.container.appendChild(canvas);
    \\
    \\    const textLayerDiv = document.createElement('div');
    \\    textLayerDiv.className = 'textLayer';
    \\    textLayerDiv.style.width = viewport.width + 'px';
    \\    textLayerDiv.style.height = viewport.height + 'px';
    \\    rec.container.appendChild(textLayerDiv);
    \\
    \\    await page.render({ canvasContext: canvas.getContext('2d'), viewport }).promise;
    \\
    \\    const textContent = await page.getTextContent();
    \\    const textLayer = new pdfjsLib.TextLayer({
    \\      textContentSource: textContent,
    \\      container: textLayerDiv,
    \\      viewport,
    \\    });
    \\    await textLayer.render();
    \\
    \\    rec.rendered = true;
    \\    if (currentQuery) applyHighlightTo(rec);
    \\  } finally {
    \\    rec.rendering = false;
    \\  }
    \\}
    \\
    \\function applyHighlightTo(rec) {
    \\  // Strip existing marks on this page back to plain text before re-marking.
    \\  rec.container.querySelectorAll('.textLayer mark.match').forEach(m => {
    \\    const parent = m.parentNode;
    \\    parent.insertBefore(document.createTextNode(m.textContent), m);
    \\    parent.removeChild(m);
    \\  });
    \\  rec.container.querySelectorAll('.textLayer span').forEach(s => s.normalize());
    \\
    \\  if (!currentQuery || currentQuery.length < 2) {
    \\    rebuildMatchIndex();
    \\    return;
    \\  }
    \\  const lower = currentQuery.toLowerCase();
    \\  const spans = rec.container.querySelectorAll('.textLayer span');
    \\  spans.forEach(span => {
    \\    const text = span.textContent;
    \\    if (!text) return;
    \\    const lowerText = text.toLowerCase();
    \\    // Find every occurrence of the query within this span; cross-span
    \\    // matches are not handled — keep queries to a short distinctive
    \\    // phrase that fits inside one PDF text run.
    \\    const segs = [];
    \\    let i = 0;
    \\    let any = false;
    \\    while (i < text.length) {
    \\      const hit = lowerText.indexOf(lower, i);
    \\      if (hit < 0) {
    \\        segs.push({ m: false, t: text.slice(i) });
    \\        break;
    \\      }
    \\      if (hit > i) segs.push({ m: false, t: text.slice(i, hit) });
    \\      segs.push({ m: true, t: text.slice(hit, hit + currentQuery.length) });
    \\      any = true;
    \\      i = hit + currentQuery.length;
    \\    }
    \\    if (!any) return;
    \\    span.textContent = '';
    \\    segs.forEach(s => {
    \\      if (s.m) {
    \\        const mark = document.createElement('mark');
    \\        mark.className = 'match';
    \\        mark.textContent = s.t;
    \\        span.appendChild(mark);
    \\      } else if (s.t) {
    \\        span.appendChild(document.createTextNode(s.t));
    \\      }
    \\    });
    \\  });
    \\  rebuildMatchIndex();
    \\}
    \\
    \\function rebuildMatchIndex() {
    \\  matches = Array.from(document.querySelectorAll('.textLayer mark.match'));
    \\  if (currentMatchIdx >= matches.length) currentMatchIdx = -1;
    \\  updateMatchUi();
    \\}
    \\
    \\function setCurrent(idx, scroll) {
    \\  if (matches.length === 0) { currentMatchIdx = -1; updateMatchUi(); return; }
    \\  if (currentMatchIdx >= 0 && matches[currentMatchIdx]) {
    \\    matches[currentMatchIdx].classList.remove('current');
    \\  }
    \\  currentMatchIdx = ((idx % matches.length) + matches.length) % matches.length;
    \\  const m = matches[currentMatchIdx];
    \\  m.classList.add('current');
    \\  if (scroll !== false) m.scrollIntoView({ behavior: 'smooth', block: 'center' });
    \\  updateMatchUi();
    \\}
    \\
    \\function updateMatchUi() {
    \\  if (!currentQuery) {
    \\    matchCtrls.hidden = true;
    \\    return;
    \\  }
    \\  matchCtrls.hidden = false;
    \\  if (matches.length === 0) {
    \\    countEl.textContent = 'no match';
    \\    countEl.style.color = '#f85149';
    \\    prevBtn.disabled = true;
    \\    nextBtn.disabled = true;
    \\  } else {
    \\    countEl.textContent = (currentMatchIdx + 1) + ' / ' + matches.length;
    \\    countEl.style.color = '';
    \\    prevBtn.disabled = matches.length < 2;
    \\    nextBtn.disabled = matches.length < 2;
    \\  }
    \\}
    \\
    \\prevBtn.addEventListener('click', () => setCurrent(currentMatchIdx - 1, true));
    \\nextBtn.addEventListener('click', () => setCurrent(currentMatchIdx + 1, true));
    \\
    \\loadPdf().catch(err => {
    \\  setStatus('Error loading PDF: ' + (err && err.message ? err.message : err));
    \\  console.error(err);
    \\});
    \\</script>
    \\</body></html>
;
