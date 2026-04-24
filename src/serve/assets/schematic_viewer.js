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
      '<div class="sb-comp-meta">' + escapeHtml(c.component) + (c.value ? ' · ' + escapeHtml(c.value) : '') + '</div>';
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
