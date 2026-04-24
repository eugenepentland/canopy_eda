// HTML schematic viewer: sidebar search + click handling + version polling.
// Mirrors the legacy Pixi.js canvas viewer's search experience without the
// canvas — selection actions become scroll + flash + highlight on the static
// SVG/HTML page. Reads `DESIGN_NAME` and `SCH_INDEX` injected by render_html.zig.
(function () {
  'use strict';

  // ---- DOM refs ----
  var searchInput = document.getElementById('sch-search');
  var resultsBox = document.getElementById('sb-results');
  var detailBox = document.getElementById('sb-detail');

  // ---- State ----
  var currentResults = [];
  var selectedIdx = -1;
  var compByRef = {};
  (SCH_INDEX.components || []).forEach(function (c) { compByRef[c.ref] = c; });
  var sectionBySlug = {};
  (SCH_INDEX.sections || []).forEach(function (s) { sectionBySlug[s.slug] = s; });
  var netByName = {};
  (SCH_INDEX.nets || []).forEach(function (n) { netByName[n.name] = n; });

  // ---- Highlight / selection ----
  function clearHighlight() {
    document.querySelectorAll('.net-active').forEach(function (n) { n.classList.remove('net-active'); });
    document.querySelectorAll('.pin-active').forEach(function (n) { n.classList.remove('pin-active'); });
    document.querySelectorAll('.flash').forEach(function (n) { n.classList.remove('flash'); });
  }
  function highlightNet(net) {
    clearHighlight();
    if (!net) return;
    var found = null;
    document.querySelectorAll('svg .net').forEach(function (n) {
      if (n.dataset.net === net) {
        n.classList.add('net-active');
        if (!found) found = n;
      }
    });
    return found;
  }
  function flash(el) {
    if (!el) return;
    el.classList.add('flash');
    setTimeout(function () { el.classList.remove('flash'); }, 900);
  }
  function scrollTo(el) {
    if (!el) return;
    el.scrollIntoView({ behavior: 'smooth', block: 'center' });
  }

  // ---- Body click handlers (delegate from document) ----
  document.addEventListener('click', function (e) {
    // Clicking a component box (hub or passive) opens its sidebar entry.
    // Check this BEFORE .net so a passive symbol drawn above a wire wins.
    var compEl = e.target.closest && e.target.closest('svg .component');
    if (compEl && compEl.dataset.ref && compByRef[compEl.dataset.ref]) {
      showComponent(compEl.dataset.ref, false);
      return;
    }
    // Clicking a pin stub picks its net.
    var pinEl = e.target.closest && e.target.closest('svg .pin-stub');
    if (pinEl && pinEl.dataset.ref) {
      var hub = compByRef[pinEl.dataset.ref];
      if (hub) {
        var firstPin = (pinEl.dataset.pin || '').split(',')[0];
        var pinRec = hub.pins && hub.pins.find(function (p) { return p.id === firstPin; });
        if (pinRec && pinRec.net) {
          showNet(pinRec.net, false);
        }
      }
      return;
    }
    // Clicking a net wire opens the net detail view in the sidebar (and
    // highlights every wire on the page); skip scrolling since the user
    // clicked at the spot they're already looking at.
    var netEl = e.target.closest && e.target.closest('svg .net');
    if (netEl && netEl.dataset.net) {
      showNet(netEl.dataset.net, false);
    }
  });

  // ---- Search ----
  function search(query) {
    var q = (query || '').trim().toLowerCase();
    if (!q) return [];
    var out = [];
    function push(rec) { if (out.length < 25) out.push(rec); }
    // Sections
    (SCH_INDEX.sections || []).forEach(function (s) {
      if (s.name.toLowerCase().indexOf(q) !== -1 || (s.description || '').toLowerCase().indexOf(q) !== -1) {
        push({ kind: 'section', label: s.name, sub: s.description, slug: s.slug, category: s.category || '' });
      }
    });
    // Components (hubs + passives)
    (SCH_INDEX.components || []).forEach(function (c) {
      if (c.ref.toLowerCase().indexOf(q) !== -1 ||
          (c.component || '').toLowerCase().indexOf(q) !== -1 ||
          (c.value || '').toLowerCase().indexOf(q) !== -1) {
        var sub = (c.component || '') + (c.value ? ' · ' + c.value : '');
        push({ kind: 'comp', label: c.ref, sub: sub, ref: c.ref });
      }
    });
    // Nets
    (SCH_INDEX.nets || []).forEach(function (n) {
      if (n.name.toLowerCase().indexOf(q) !== -1) {
        var count = (n.members || []).length;
        push({ kind: 'net', label: n.name, sub: count + ' pin' + (count === 1 ? '' : 's'), net: n.name });
      }
    });
    // Pins (matches on pin id, function, or alt-fn) — search within hubs
    // since passives' pins (1, 2) aren't useful search targets.
    (SCH_INDEX.components || []).forEach(function (c) {
      if (c.kind !== 'hub') return;
      (c.pins || []).forEach(function (p) {
        var hay = (p.id + ' ' + (p.fn || '') + ' ' + (p.alt || '')).toLowerCase();
        if (hay.indexOf(q) !== -1) {
          var label = c.ref + '.' + p.id;
          var sub = (p.fn || p.net || '') + (p.alt && p.alt !== p.fn ? ' · ' + p.alt : '');
          push({ kind: 'pin', label: label, sub: sub, ref: c.ref, pin: p.id, net: p.net });
        }
      });
    });
    return out;
  }

  function renderResults() {
    if (!currentResults.length) {
      resultsBox.classList.remove('open');
      resultsBox.innerHTML = '';
      return;
    }
    var html = '';
    currentResults.forEach(function (r, i) {
      var metaLabel, metaClass;
      if (r.kind === 'section' && r.category) {
        metaLabel = r.category;
        metaClass = 'sb-cat cat-' + r.category;
      } else {
        metaLabel = r.kind;
        metaClass = 'sb-result-meta t-' + (r.kind === 'section' ? 'sec' : r.kind);
      }
      html += '<div class="sb-result' + (i === selectedIdx ? ' selected' : '') + '" data-idx="' + i + '">' +
        '<div class="sb-result-label" title="' + escapeHtml(r.label + (r.sub ? ' — ' + r.sub : '')) + '">' +
        escapeHtml(r.label) + (r.sub ? ' <span class="muted">' + escapeHtml(r.sub) + '</span>' : '') + '</div>' +
        '<span class="' + metaClass + '">' + escapeHtml(metaLabel) + '</span>' +
        '</div>';
    });
    resultsBox.innerHTML = html;
    resultsBox.classList.add('open');
  }

  function pickResult(r) {
    if (!r) return;
    if (r.kind === 'section') {
      showSection(r.slug, true);
    } else if (r.kind === 'comp') {
      showComponent(r.ref, true);
    } else if (r.kind === 'net') {
      showNet(r.net, true);
    } else if (r.kind === 'pin') {
      showComponent(r.ref, true);
      if (r.net) highlightNet(r.net);
      var pinEl = document.querySelector('svg .pin-stub[data-ref="' + cssEscape(r.ref) + '"][data-pin^="' + cssEscape(r.pin) + '"]');
      if (pinEl) {
        pinEl.classList.add('pin-active');
        scrollTo(pinEl);
      }
    }
    closeResults();
  }

  function closeResults() {
    currentResults = [];
    selectedIdx = -1;
    renderResults();
  }

  searchInput.addEventListener('input', function () {
    currentResults = search(searchInput.value);
    selectedIdx = currentResults.length ? 0 : -1;
    renderResults();
  });

  searchInput.addEventListener('keydown', function (e) {
    if (e.key === 'ArrowDown' && currentResults.length) {
      e.preventDefault();
      selectedIdx = (selectedIdx + 1) % currentResults.length;
      renderResults();
    } else if (e.key === 'ArrowUp' && currentResults.length) {
      e.preventDefault();
      selectedIdx = (selectedIdx - 1 + currentResults.length) % currentResults.length;
      renderResults();
    } else if (e.key === 'Enter' && selectedIdx >= 0) {
      e.preventDefault();
      pickResult(currentResults[selectedIdx]);
    } else if (e.key === 'Escape') {
      e.preventDefault();
      searchInput.value = '';
      closeResults();
      searchInput.blur();
    }
  });

  resultsBox.addEventListener('click', function (e) {
    var item = e.target.closest('.sb-result');
    if (!item) return;
    pickResult(currentResults[parseInt(item.dataset.idx, 10)]);
  });

  // Global keyboard shortcuts: '/' or Ctrl+F focuses search.
  document.addEventListener('keydown', function (e) {
    if (e.target === searchInput) return;
    if (e.key === '/' || ((e.ctrlKey || e.metaKey) && e.key === 'f')) {
      e.preventDefault();
      searchInput.focus();
      searchInput.select();
    }
  });

  // ---- Sidebar views ----
  function showSectionList() {
    if (!SCH_INDEX.sections || !SCH_INDEX.sections.length) {
      detailBox.innerHTML = '<div class="sb-empty">No sections.</div>';
      return;
    }
    var html = '<h4>Sections</h4>';
    SCH_INDEX.sections.forEach(function (s) {
      var catPill = s.category
        ? '<span class="sb-cat cat-' + s.category + '">' + escapeHtml(s.category) + '</span>'
        : '';
      html += '<div class="sb-list-item" data-slug="' + escapeHtml(s.slug) + '">' +
        '<div class="sb-li-head">' + catPill + '<span>' + escapeHtml(s.name) + '</span></div>';
      if (s.description) html += '<div class="sb-li-sub">' + escapeHtml(s.description) + '</div>';
      html += '</div>';
    });
    detailBox.innerHTML = html;
    detailBox.querySelectorAll('.sb-list-item').forEach(function (el) {
      el.addEventListener('click', function () { showSection(el.dataset.slug, true); });
    });
  }

  function showSection(slug, doScroll) {
    var sec = sectionBySlug[slug];
    if (!sec) return;
    if (doScroll) {
      var anchor = document.getElementById('sec-' + slug);
      if (anchor) { scrollTo(anchor); flash(anchor); }
    }
    var html = '<span class="sb-back">← All sections</span>' +
      '<h4>' + escapeHtml(sec.name) + '</h4>';
    if (sec.description) html += '<div class="sb-comp-meta">' + escapeHtml(sec.description) + '</div>';
    if (!sec.hubs || !sec.hubs.length) {
      html += '<div class="sb-empty">No hubs in this section.</div>';
    } else {
      sec.hubs.forEach(function (ref) {
        var h = compByRef[ref];
        if (!h) return;
        html += '<div class="sb-list-item" data-ref="' + escapeHtml(ref) + '">' +
          '<div class="sb-li-head">' + escapeHtml(ref) + '</div>' +
          '<div class="sb-li-sub">' + escapeHtml(h.component) + (h.value ? ' · ' + escapeHtml(h.value) : '') + '</div>' +
          '</div>';
      });
    }
    detailBox.innerHTML = html;
    detailBox.querySelector('.sb-back').addEventListener('click', showSectionList);
    detailBox.querySelectorAll('.sb-list-item').forEach(function (el) {
      el.addEventListener('click', function () { showComponent(el.dataset.ref, true); });
    });
  }

  // Unified detail view for any component — hubs render their pin table,
  // passives render a compact info card with a "show net" jump for each pin.
  function showComponent(ref, doScroll) {
    var c = compByRef[ref];
    if (!c) return;
    if (doScroll) {
      var anchor = document.querySelector('.sch-hub[data-ref="' + cssEscape(ref) + '"]')
                || document.querySelector('svg [data-ref="' + cssEscape(ref) + '"].component');
      if (anchor) { scrollTo(anchor); flash(anchor.closest('.sch-hub') || anchor); }
    }
    var backTarget = c.section && sectionBySlug[c.section] ? c.section : null;
    var html = '<span class="sb-back" data-back="' + (backTarget ? escapeHtml(backTarget) : '') + '">← ' +
      (backTarget ? 'Section' : 'All sections') + '</span>' +
      '<h4>' + escapeHtml(ref) + '</h4>' +
      '<div class="sb-comp-meta">' +
        (c.component ?
          '<span class="sb-comp-link" data-component="' + escapeHtml(c.component) + '" title="Show pinout">' +
          escapeHtml(c.component) + '</span>' : '') +
        (c.value ? ' · ' + escapeHtml(c.value) : '') +
      '</div>';
    if (c.kind !== 'hub') {
      // Passives: show the nets they sit on, derived from SCH_INDEX.nets.
      var rows = [];
      (SCH_INDEX.nets || []).forEach(function (n) {
        (n.members || []).forEach(function (m) {
          if (m.ref === ref) rows.push({ pin: m.pin, net: n.name });
        });
      });
      if (!rows.length) {
        html += '<div class="sb-empty">No net connections.</div>';
      } else {
        rows.sort(function (a, b) { return cmpPin(a.pin, b.pin); });
        rows.forEach(function (r) {
          html += '<div class="sb-pin-row" data-ref="' + escapeHtml(ref) + '" data-pin="' + escapeHtml(r.pin) + '" data-net="' + escapeHtml(r.net) + '">' +
            '<div class="sb-pin-id">' + escapeHtml(r.pin) + '</div>' +
            '<div><div class="sb-pin-net">' + escapeHtml(r.net) + '</div></div></div>';
        });
      }
    } else if (!c.pins || !c.pins.length) {
      html += '<div class="sb-empty">No pin connections.</div>';
    } else {
      var sorted = c.pins.slice().sort(function (a, b) { return cmpPin(a.id, b.id); });
      sorted.forEach(function (p) {
        html += '<div class="sb-pin-row" data-ref="' + escapeHtml(ref) + '" data-pin="' + escapeHtml(p.id) + '" data-net="' + escapeHtml(p.net) + '">' +
          '<div class="sb-pin-id">' + escapeHtml(p.id) + '</div>' +
          '<div>' +
          '<div class="sb-pin-net">' + (p.net ? escapeHtml(p.net) : '<span class="muted">—</span>') + '</div>';
        if (p.fn || p.alt) {
          html += '<div class="sb-pin-fn">' + escapeHtml(p.fn || '');
          if (p.alt && p.alt !== p.fn) html += ' <span class="sb-pin-alt">' + escapeHtml(p.alt) + '</span>';
          html += '</div>';
        }
        html += '</div></div>';
      });
    }
    detailBox.innerHTML = html;
    var back = detailBox.querySelector('.sb-back');
    back.addEventListener('click', function () {
      var target = back.dataset.back;
      if (target) showSection(target, false); else showSectionList();
    });
    var compLink = detailBox.querySelector('.sb-comp-link');
    if (compLink) {
      compLink.addEventListener('click', function (e) {
        e.stopPropagation();
        showPinout(compLink.dataset.component, ref);
      });
    }
    detailBox.querySelectorAll('.sb-pin-row').forEach(function (row) {
      row.addEventListener('click', function (e) {
        var net = row.dataset.net;
        // Click on the net text → open the net detail view in the sidebar.
        if (e.target.closest('.sb-pin-net') && net) {
          showNet(net, true);
          return;
        }
        // Anywhere else on the row (pin id, function, blank space) → highlight
        // the net on the page and scroll to this pin's stub.
        detailBox.querySelectorAll('.sb-pin-row.active').forEach(function (r) { r.classList.remove('active'); });
        row.classList.add('active');
        if (net) {
          var firstSvgPin = highlightNet(net);
          var pinEl = document.querySelector('svg .pin-stub[data-ref="' + cssEscape(row.dataset.ref) + '"][data-pin^="' + cssEscape(row.dataset.pin) + '"]');
          scrollTo(pinEl || firstSvgPin);
        }
      });
    });
  }

  // Pinout viewer: fetches lib/pinouts/<component>.sexp via API and shows the
  // full pin map (every alternate function) so the user can verify that the
  // pin they wired to a peripheral like XSPIM actually carries that function.
  // Pins that are wired in the current schematic are highlighted and show the
  // attached net; clicking a wired pin jumps to its net view.
  var pinoutCache = {};
  function showPinout(componentName, fromRef) {
    if (!componentName) return;
    var hub = fromRef ? compByRef[fromRef] : null;
    var wired = {};
    if (hub && hub.pins) {
      hub.pins.forEach(function (p) { wired[p.id] = p; });
    }

    function render(data, error) {
      var html = '<span class="sb-back" data-back-ref="' + (fromRef ? escapeHtml(fromRef) : '') + '">← ' +
        (fromRef ? escapeHtml(fromRef) : 'Back') + '</span>' +
        '<h4>' + escapeHtml(componentName) + ' pinout</h4>';
      // Datasheet strip sits under the title, always visible. When a PDF
      // is already uploaded we show a "View" link; otherwise an upload
      // prompt that posts the raw file to /api/datasheet/<component>.
      var safe = escapeHtml(componentName);
      var hasDs = data && data.has_datasheet;
      html += '<div class="sb-datasheet" data-component="' + safe + '">';
      if (hasDs) {
        html += '<a class="sb-ds-view" href="/api/datasheet/' + encodeURIComponent(componentName) + '" target="_blank" rel="noopener">📄 View datasheet (PDF)</a>' +
          '<label class="sb-ds-replace">Replace<input type="file" accept="application/pdf" class="sb-ds-file" hidden></label>';
      } else {
        html += '<label class="sb-ds-upload">📄 Upload datasheet (PDF)<input type="file" accept="application/pdf" class="sb-ds-file" hidden></label>';
      }
      html += '<div class="sb-ds-status" aria-live="polite"></div></div>';
      if (error) {
        html += '<div class="sb-empty">' + escapeHtml(error) + '</div>';
      } else if (!data || !data.pins || !data.pins.length) {
        html += '<div class="sb-empty">No pins in pinout file.</div>';
      } else {
        var wiredCount = 0;
        (data.pins || []).forEach(function (p) { if (wired[p.id]) wiredCount++; });
        html += '<div class="sb-comp-meta">' + data.pins.length + ' pins' +
          (fromRef ? ' · ' + wiredCount + ' wired on ' + escapeHtml(fromRef) : '') + '</div>' +
          '<input type="text" class="sb-pinout-filter" placeholder="Filter by pin / function (e.g. XSPI)" />' +
          '<div class="sb-pinout-rows">';
        var sorted = data.pins.slice().sort(function (a, b) { return cmpPin(a.id, b.id); });
        sorted.forEach(function (p) {
          var w = wired[p.id];
          var cls = 'sb-pinout-row' + (w ? ' is-wired' : '');
          var altHay = (p.alts || []).map(function (a) { return a.name; }).join(' ');
          var hay = (p.id + ' ' + (p.fn || '') + ' ' + altHay).toLowerCase();
          html += '<div class="' + cls + '" data-hay="' + escapeHtml(hay) +
            '" data-pin="' + escapeHtml(p.id) +
            '" data-net="' + escapeHtml(w ? (w.net || '') : '') + '">' +
            '<div class="sb-pinout-head">' +
            '<span class="sb-pin-id">' + escapeHtml(p.id) + '</span>' +
            '<span class="sb-pinout-fn">' + escapeHtml(p.fn || '') + '</span>' +
            (w && w.net ? '<span class="sb-pinout-net" title="Wired to this net">' + escapeHtml(w.net) + '</span>' : '') +
            '</div>';
          if (p.alts && p.alts.length) {
            html += '<div class="sb-pinout-alts">' + p.alts.map(function (a) {
              return '<span class="sb-pinout-alt" data-type="' + escapeHtml(a.type || '') + '">' +
                escapeHtml(a.name) + '</span>';
            }).join('') + '</div>';
          }
          html += '</div>';
        });
        html += '</div>';
      }
      detailBox.innerHTML = html;
      var back = detailBox.querySelector('.sb-back');
      if (back) back.addEventListener('click', function () {
        var r = back.dataset.backRef;
        if (r) showComponent(r, false); else showSectionList();
      });
      // Clicking a wired pin row jumps to its net view.
      detailBox.querySelectorAll('.sb-pinout-row.is-wired').forEach(function (row) {
        row.addEventListener('click', function () {
          var net = row.dataset.net;
          if (net) showNet(net, true);
        });
      });
      // Filter: substring match against "pin id / fn / alt names".
      var filter = detailBox.querySelector('.sb-pinout-filter');
      if (filter) {
        filter.addEventListener('input', function () {
          var q = filter.value.trim().toLowerCase();
          detailBox.querySelectorAll('.sb-pinout-row').forEach(function (row) {
            row.style.display = (!q || row.dataset.hay.indexOf(q) !== -1) ? '' : 'none';
          });
        });
      }
      // Datasheet upload: the PDF is POSTed as the raw request body so the
      // server can dump it straight to lib/datasheets/<component>.pdf with
      // no multipart parsing. On success we invalidate the cache so the
      // panel refreshes with the new "View" link.
      var dsFile = detailBox.querySelector('.sb-ds-file');
      var dsStatus = detailBox.querySelector('.sb-ds-status');
      if (dsFile) {
        dsFile.addEventListener('change', function () {
          var file = dsFile.files && dsFile.files[0];
          if (!file) return;
          if (file.size > 64 * 1024 * 1024) {
            dsStatus.textContent = 'File too large (limit 64MB).';
            dsStatus.className = 'sb-ds-status err';
            return;
          }
          dsStatus.textContent = 'Uploading ' + file.name + '…';
          dsStatus.className = 'sb-ds-status';
          fetch('/api/datasheet/' + encodeURIComponent(componentName), {
            method: 'POST',
            headers: { 'Content-Type': 'application/pdf' },
            body: file,
          }).then(function (r) { return r.json(); }).then(function (j) {
            if (j.ok) {
              dsStatus.textContent = 'Uploaded (' + j.bytes + ' bytes).';
              dsStatus.className = 'sb-ds-status ok';
              delete pinoutCache[componentName];
              // Re-render after a short pause so the user sees the status.
              setTimeout(function () { showPinout(componentName, fromRef); }, 700);
            } else {
              dsStatus.textContent = 'Error: ' + (j.error || 'upload failed');
              dsStatus.className = 'sb-ds-status err';
            }
          }).catch(function (e) {
            dsStatus.textContent = 'Error: ' + e;
            dsStatus.className = 'sb-ds-status err';
          });
        });
      }
    }

    if (pinoutCache[componentName]) {
      render(pinoutCache[componentName]);
      return;
    }
    detailBox.innerHTML = '<span class="sb-back" data-back-ref="' + (fromRef ? escapeHtml(fromRef) : '') + '">← ' +
      (fromRef ? escapeHtml(fromRef) : 'Back') + '</span>' +
      '<h4>' + escapeHtml(componentName) + ' pinout</h4>' +
      '<div class="sb-empty">Loading…</div>';
    var back0 = detailBox.querySelector('.sb-back');
    if (back0) back0.addEventListener('click', function () {
      var r = back0.dataset.backRef;
      if (r) showComponent(r, false); else showSectionList();
    });
    fetch('/api/pinout/' + encodeURIComponent(componentName)).then(function (r) {
      if (!r.ok) throw new Error('not found');
      return r.json();
    }).then(function (data) {
      pinoutCache[componentName] = data;
      render(data);
    }).catch(function () {
      render(null, 'No pinout file for ' + componentName + ' (expected lib/pinouts/' + componentName + '.sexp).');
    });
  }

  function showNet(net, doScroll) {
    var rec = netByName[net];
    if (doScroll) {
      var firstSvgPin = highlightNet(net);
      scrollTo(firstSvgPin);
    } else {
      highlightNet(net);
    }
    if (!rec) {
      detailBox.innerHTML = '<span class="sb-back">← All sections</span>' +
        '<h4>' + escapeHtml(net) + '</h4>' +
        '<div class="sb-empty">No connection records found.</div>';
      detailBox.querySelector('.sb-back').addEventListener('click', showSectionList);
      return;
    }

    // Bucket members by section, then by ref. Each ref collapses to one row
    // with all its pins joined ("U3 · A19, F12, H14, …"). Section order
    // follows SCH_INDEX.sections so the sidebar reads top-to-bottom matching
    // the page layout.
    var bySection = {};
    var sectionOrder = (SCH_INDEX.sections || []).map(function (s) { return s.slug; });
    var unsectioned = '__none__';
    (rec.members || []).forEach(function (m) {
      var c = compByRef[m.ref];
      var slug = (c && c.section) ? c.section : unsectioned;
      if (!bySection[slug]) bySection[slug] = {};
      if (!bySection[slug][m.ref]) bySection[slug][m.ref] = { ref: m.ref, comp: c, pins: [] };
      bySection[slug][m.ref].pins.push(m.pin);
    });

    var orderedSlugs = sectionOrder.filter(function (s) { return bySection[s]; });
    Object.keys(bySection).forEach(function (s) {
      if (orderedSlugs.indexOf(s) === -1) orderedSlugs.push(s);
    });

    var totalConn = (rec.members || []).length;
    var html = '<span class="sb-back">← All sections</span>' +
      '<h4>' + escapeHtml(net) + '</h4>' +
      '<div class="sb-comp-meta">' + totalConn + ' connection' + (totalConn === 1 ? '' : 's') +
      ' · ' + orderedSlugs.length + ' section' + (orderedSlugs.length === 1 ? '' : 's') + '</div>';

    orderedSlugs.forEach(function (slug) {
      var sec = sectionBySlug[slug];
      var label = sec ? sec.name : 'Unsectioned';
      html += '<div class="sb-net-section">' + escapeHtml(label) + '</div>';
      var refs = Object.keys(bySection[slug]).sort(function (a, b) {
        return a < b ? -1 : a > b ? 1 : 0;
      });
      refs.forEach(function (ref) {
        var entry = bySection[slug][ref];
        entry.pins.sort(cmpPin);
        var pinList = entry.pins.map(function (p) {
          return '<span class="sb-net-pin" data-ref="' + escapeHtml(ref) + '" data-pin="' + escapeHtml(p) + '" data-net="' + escapeHtml(net) + '">' + escapeHtml(p) + '</span>';
        }).join(', ');
        var sub = entry.comp ? (entry.comp.component + (entry.comp.value ? ' · ' + entry.comp.value : '')) : '';
        html += '<div class="sb-net-row" data-ref="' + escapeHtml(ref) + '">' +
          '<div class="sb-net-row-head">' +
          '<span class="sb-net-ref">' + escapeHtml(ref) + '</span>' +
          (sub ? ' <span class="sb-net-comp">' + escapeHtml(sub) + '</span>' : '') +
          '</div>' +
          '<div class="sb-net-pins">' + pinList + '</div>' +
          '</div>';
      });
    });

    detailBox.innerHTML = html;
    detailBox.querySelector('.sb-back').addEventListener('click', showSectionList);
    detailBox.querySelectorAll('.sb-net-pin').forEach(function (pin) {
      pin.addEventListener('click', function (e) {
        e.stopPropagation();
        highlightNet(net);
        var pinEl = document.querySelector('svg .pin-stub[data-ref="' + cssEscape(pin.dataset.ref) + '"][data-pin^="' + cssEscape(pin.dataset.pin) + '"]');
        scrollTo(pinEl);
      });
    });
    detailBox.querySelectorAll('.sb-net-row').forEach(function (row) {
      row.addEventListener('click', function () {
        showComponent(row.dataset.ref, true);
      });
    });
  }

  // ---- Helpers ----
  function escapeHtml(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
    });
  }
  function cssEscape(s) {
    if (window.CSS && CSS.escape) return CSS.escape(s);
    return String(s).replace(/[^a-zA-Z0-9_-]/g, '\\$&');
  }
  // Sort pin ids: alpha prefix then numeric (B12 < B100, but 1 < 12).
  function cmpPin(a, b) {
    var ra = /^([A-Za-z]*)(\d*)$/.exec(a) || [];
    var rb = /^([A-Za-z]*)(\d*)$/.exec(b) || [];
    if (ra[1] !== rb[1]) return ra[1] < rb[1] ? -1 : 1;
    var na = parseInt(ra[2] || '0', 10);
    var nb = parseInt(rb[2] || '0', 10);
    if (na !== nb) return na - nb;
    return a < b ? -1 : a > b ? 1 : 0;
  }

  // ---- ERC panel ----
  // Fetches /api/erc/:name and renders violations in the sidebar. Clicking a
  // violation with a ref_des jumps to that component; clicking one with only a
  // net jumps to the net view. Mirrors the legacy canvas ERC behavior but uses
  // the new sidebar instead of a separate modal.
  var ercBtn = document.getElementById('erc-btn');
  if (ercBtn) {
    ercBtn.addEventListener('click', function () {
      showErc();
    });
    // Warm the badge on page load so the user sees the counts without clicking.
    fetchErc().then(updateErcBadge).catch(function () {});
  }

  function fetchErc() {
    return fetch('/api/erc/' + DESIGN_NAME).then(function (r) { return r.json(); });
  }

  function updateErcBadge(violations) {
    if (!ercBtn) return;
    var nErr = 0, nWarn = 0;
    (violations || []).forEach(function (v) {
      if (v.severity === 'error') nErr++;
      else if (v.severity === 'warning') nWarn++;
    });
    ercBtn.classList.remove('erc-pass', 'erc-warn', 'erc-err');
    if (nErr > 0) { ercBtn.classList.add('erc-err'); ercBtn.textContent = 'ERC (' + nErr + ')'; }
    else if (nWarn > 0) { ercBtn.classList.add('erc-warn'); ercBtn.textContent = 'ERC (' + nWarn + ')'; }
    else { ercBtn.classList.add('erc-pass'); ercBtn.textContent = 'ERC \u2713'; }
  }

  function showErc() {
    detailBox.innerHTML = '<span class="sb-back">← All sections</span>' +
      '<h4>ERC</h4><div class="sb-empty">Running…</div>';
    detailBox.querySelector('.sb-back').addEventListener('click', showSectionList);
    fetchErc().then(function (violations) {
      updateErcBadge(violations);
      renderErcPanel(violations);
    }).catch(function (e) {
      detailBox.innerHTML = '<span class="sb-back">← All sections</span>' +
        '<h4>ERC</h4><div class="sb-empty">Error: ' + escapeHtml(String(e)) + '</div>';
      detailBox.querySelector('.sb-back').addEventListener('click', showSectionList);
    });
  }

  function renderErcPanel(violations) {
    var errs = [], warns = [], infos = [];
    (violations || []).forEach(function (v) {
      if (v.severity === 'error') errs.push(v);
      else if (v.severity === 'warning') warns.push(v);
      else infos.push(v);
    });
    var html = '<span class="sb-back">← All sections</span>' +
      '<h4>ERC</h4>' +
      '<div class="sb-comp-meta">' + errs.length + ' error' + (errs.length === 1 ? '' : 's') +
      ' · ' + warns.length + ' warning' + (warns.length === 1 ? '' : 's') + '</div>';
    if (!errs.length && !warns.length && !infos.length) {
      html += '<div class="erc-ok">\u2713 No issues found</div>';
    }
    function group(label, cls, list) {
      if (!list.length) return '';
      var out = '<div class="erc-group-head ' + cls + '">' + label + ' (' + list.length + ')</div>';
      list.forEach(function (v) {
        var nav = v.ref ? 'data-nav-ref="' + escapeHtml(v.ref) + '"' : (v.net ? 'data-nav-net="' + escapeHtml(v.net) + '"' : '');
        var tag = v.ref ? ' <span class="erc-tag">' + escapeHtml(v.ref) + '</span>'
                : v.net ? ' <span class="erc-tag">' + escapeHtml(v.net) + '</span>'
                : '';
        out += '<div class="erc-item erc-' + cls + '" ' + nav + '>' +
          escapeHtml(v.message) + tag + '</div>';
      });
      return out;
    }
    html += group('Errors', 'err', errs);
    html += group('Warnings', 'warn', warns);
    html += group('Info', 'info', infos);
    html += '<button class="kicad-row-btn" id="erc-rerun" style="margin-top:10px">Re-run ERC</button>';
    detailBox.innerHTML = html;
    detailBox.querySelector('.sb-back').addEventListener('click', showSectionList);
    detailBox.querySelectorAll('.erc-item').forEach(function (el) {
      el.addEventListener('click', function () {
        var ref = el.dataset.navRef, net = el.dataset.navNet;
        if (ref) showComponent(ref, true);
        else if (net) showNet(net, true);
      });
    });
    var rerun = document.getElementById('erc-rerun');
    if (rerun) rerun.addEventListener('click', showErc);
  }

  // ---- KiCad sync menu ----
  // Ports the legacy canvas dropdown: path config + "Update KiCad PCB (pcb_update.py)".
  (function () {
    var menu = document.querySelector('.kicad-menu');
    var btn = document.getElementById('kicad-btn');
    var panel = document.getElementById('kicad-panel');
    if (!menu || !btn || !panel) return;
    var pathInput = document.getElementById('kicad-path');
    var pcbFileInput = document.getElementById('kicad-pcb-file');
    var shortNets = document.getElementById('kicad-short-nets');
    var statusEl = document.getElementById('kicad-status');
    var saveBtn = document.getElementById('kicad-save-path');
    var writeNet = document.getElementById('kicad-write-netlist');
    var writeKicad = document.getElementById('kicad-write-kicad');
    var updatePcb = document.getElementById('kicad-update-pcb');

    function setStatus(msg, cls) {
      statusEl.textContent = msg || '';
      statusEl.className = 'kicad-status' + (cls ? ' ' + cls : '');
    }
    btn.addEventListener('click', function (e) { e.stopPropagation(); menu.classList.toggle('open'); });
    panel.addEventListener('click', function (e) { e.stopPropagation(); });
    document.addEventListener('click', function () { menu.classList.remove('open'); });

    fetch('/api/kicad-sync-config/' + DESIGN_NAME).then(function (r) { return r.json(); }).then(function (j) {
      if (j && j.output_dir) pathInput.value = j.output_dir;
      if (j && j.pcb_file) pcbFileInput.value = j.pcb_file;
    }).catch(function () {});

    saveBtn.addEventListener('click', function () {
      setStatus('Saving…');
      fetch('/api/kicad-sync-config/' + DESIGN_NAME, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ output_dir: pathInput.value.trim(), pcb_file: pcbFileInput.value.trim() }),
      }).then(function (r) { return r.json(); }).then(function (j) {
        setStatus(j.ok ? 'Settings saved' : ('Error: ' + (j.error || 'unknown')), j.ok ? 'ok' : 'err');
      }).catch(function (e) { setStatus('Error: ' + e, 'err'); });
    });

    function doWrite(url, label) {
      if (!pathInput.value.trim()) { setStatus('Enter an output path first', 'err'); return; }
      setStatus(label + '…');
      fetch(url, { method: 'POST' }).then(function (r) { return r.json(); }).then(function (j) {
        if (!j.ok) { setStatus('Error: ' + (j.error || 'unknown'), 'err'); return; }
        if (j.netlist && j.pretty) setStatus('Wrote ' + j.netlist + ' and ' + j.pretty, 'ok');
        else if (j.pcb) setStatus('Updated ' + j.pcb, 'ok');
        else if (j.path) setStatus('Wrote ' + j.path, 'ok');
        else setStatus('Done', 'ok');
      }).catch(function (e) { setStatus('Error: ' + e, 'err'); });
    }
    writeNet.addEventListener('click', function () { doWrite('/api/export-netlist-to-dir/' + DESIGN_NAME, 'Writing netlist'); });
    writeKicad.addEventListener('click', function () { doWrite('/api/export-kicad-to-dir/' + DESIGN_NAME, 'Writing netlist + footprints'); });

    updatePcb.addEventListener('click', function () {
      var url = '/api/update-kicad-pcb/' + DESIGN_NAME;
      if (shortNets && shortNets.checked) url += '?short-nets=1';
      setStatus('Updating KiCad PCB…');
      fetch(url, { method: 'POST' }).then(function (r) { return r.json(); }).then(function (j) {
        if (!j.ok) {
          var msg = 'Error: ' + (j.error || 'unknown');
          if (j.preflight) msg += '\n' + j.preflight;
          setStatus(msg, 'err');
          return;
        }
        var lines = [];
        if (j.skipped) lines.push('No changes since last sync — ' + j.pcb);
        else {
          lines.push('Updated ' + j.pcb);
          if (j.backup) lines.push('Backup: ' + j.backup);
          else if (j.backup === null) lines.push('Backup: (new PCB, none needed)');
          var parts = [];
          if (j.wrote_footprints !== undefined) parts.push(j.wrote_footprints + ' footprint(s)');
          if (j.wrote_models !== undefined) parts.push(j.wrote_models + ' model(s)');
          if (parts.length) lines.push('Wrote: ' + parts.join(', '));
        }
        var m = j.mismatches || 0, miss = j.missing || 0, seeded = j.seeded || 0;
        if (seeded > 0) lines.push('Replicated module layouts: ' + seeded + ' component(s) seeded.');
        if (m === 0 && miss === 0) { if (!j.skipped) lines.push('Validation: all checks passed'); }
        else lines.push('Validation: ' + m + ' mismatch(es), ' + miss + ' missing component(s) — see ' + j.pcb.replace(/\.kicad_pcb$/, '.pcb_diff.json'));
        setStatus(lines.join('\n'), (m === 0 && miss === 0) ? 'ok' : 'err');
      }).catch(function (e) { setStatus('Error: ' + e, 'err'); });
    });
  })();

  // ---- Live reload ----
  var lastVersion = null;
  function poll() {
    fetch('/api/version/' + DESIGN_NAME).then(function (r) { return r.json(); }).then(function (j) {
      if (lastVersion === null) { lastVersion = j.version; return; }
      if (j.version !== lastVersion) window.location.reload();
    }).catch(function () {});
  }
  setInterval(poll, 2000);
  poll();

  // ---- Boot ----
  showSectionList();
})();
