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

  // ---- Global PDF upload ----
  // One-click upload to lib/datasheets/. The filename is preserved (sanitized
  // server-side). Users wire the uploaded PDF to a part by editing
  // lib/components/<name>.sexp and adding `(datasheet "filename.pdf")`.
  var globalDsInput = document.getElementById('global-ds-upload');
  var globalDsStatus = document.getElementById('global-ds-status');
  if (globalDsInput) {
    globalDsInput.addEventListener('change', function () {
      var file = globalDsInput.files && globalDsInput.files[0];
      if (!file) return;
      if (file.size > 64 * 1024 * 1024) {
        globalDsStatus.textContent = 'too large (64MB limit)';
        return;
      }
      globalDsStatus.textContent = 'uploading ' + file.name + '…';
      fetch('/api/upload-datasheet', {
        method: 'POST',
        headers: { 'Content-Type': 'application/pdf', 'x-filename': file.name },
        body: file,
      }).then(function (r) { return r.json(); }).then(function (j) {
        if (j.ok) {
          globalDsStatus.textContent = 'uploaded as ' + j.name;
          setTimeout(function () { globalDsStatus.textContent = ''; }, 4000);
        } else {
          globalDsStatus.textContent = 'error: ' + (j.error || 'failed');
        }
      }).catch(function (e) { globalDsStatus.textContent = 'error: ' + e; });
      globalDsInput.value = '';
    });
  }

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
    el.scrollIntoView({ behavior: 'auto', block: 'center' });
  }

  // ---- Body click handlers (delegate from document) ----
  document.addEventListener('click', function (e) {
    // "Copy source" on a sub-block card: fetch the module/file text and put
    // it on the clipboard. data-src is a module name or a project-relative
    // path; the API resolves either via the ?src= query param.
    var copyBtn = e.target.closest && e.target.closest('.copy-src-btn');
    if (copyBtn && copyBtn.dataset.src) {
      e.preventDefault();
      var origLabel = copyBtn.textContent;
      fetch('/api/module-source?src=' + encodeURIComponent(copyBtn.dataset.src))
        .then(function (r) { if (!r.ok) throw new Error('not found'); return r.text(); })
        .then(function (text) { return navigator.clipboard.writeText(text); })
        .then(function () {
          copyBtn.textContent = 'Copied ✓';
          copyBtn.classList.add('copied');
          setTimeout(function () {
            copyBtn.textContent = origLabel;
            copyBtn.classList.remove('copied');
          }, 1500);
        })
        .catch(function () {
          copyBtn.textContent = 'Copy failed';
          setTimeout(function () { copyBtn.textContent = origLabel; }, 1500);
        });
      return;
    }
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
    // Components (hubs + passives) — match on ref, family, value, MPN,
    // or manufacturer so designers can find a part by typing the
    // manufacturer part number from the BOM.
    (SCH_INDEX.components || []).forEach(function (c) {
      var mpn = (c.mpn || '').toLowerCase();
      var mfr = (c.manufacturer || '').toLowerCase();
      var matched = c.ref.toLowerCase().indexOf(q) !== -1 ||
          (c.component || '').toLowerCase().indexOf(q) !== -1 ||
          (c.value || '').toLowerCase().indexOf(q) !== -1 ||
          mpn.indexOf(q) !== -1 ||
          mfr.indexOf(q) !== -1;
      if (!matched) return;
      var sub = (c.component || '') + (c.value ? ' · ' + c.value : '');
      if (mpn && (mpn.indexOf(q) !== -1 || mfr.indexOf(q) !== -1)) {
        sub += ' · ' + (c.manufacturer ? c.manufacturer + ' ' : '') + c.mpn;
      }
      push({ kind: 'comp', label: c.ref, sub: sub, ref: c.ref });
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

  // Global keyboard shortcuts: '/' or Ctrl+F focuses search; '?' toggles the
  // shortcut-help overlay (list mirrors exactly what this file binds).
  var kbdOverlay = null;
  function closeKbdOverlay() {
    if (kbdOverlay && kbdOverlay.parentNode) kbdOverlay.parentNode.removeChild(kbdOverlay);
    kbdOverlay = null;
  }
  function toggleKbdOverlay() {
    if (kbdOverlay) { closeKbdOverlay(); return; }
    kbdOverlay = document.createElement('div');
    kbdOverlay.className = 'kbd-overlay';
    kbdOverlay.innerHTML =
      '<div class="kbd-box"><h3>Keyboard shortcuts</h3>' +
      '<div class="kbd-row"><span>Focus search</span><kbd>/</kbd></div>' +
      '<div class="kbd-row"><span>Focus search (alt)</span><kbd>Ctrl+F</kbd></div>' +
      '<div class="kbd-row"><span>Move through results</span><kbd>↑ ↓</kbd></div>' +
      '<div class="kbd-row"><span>Open selected result</span><kbd>Enter</kbd></div>' +
      '<div class="kbd-row"><span>Clear search / close</span><kbd>Esc</kbd></div>' +
      '<div class="kbd-row"><span>Toggle this help</span><kbd>?</kbd></div>' +
      '<div class="kbd-hint">Esc or click anywhere to close</div></div>';
    document.body.appendChild(kbdOverlay);
    kbdOverlay.addEventListener('click', closeKbdOverlay);
  }
  document.addEventListener('keydown', function (e) {
    if (e.key === 'Escape' && kbdOverlay) { closeKbdOverlay(); return; }
    if (e.target === searchInput) return;
    var t = e.target;
    var typing = t && (t.tagName === 'INPUT' || t.tagName === 'TEXTAREA' || t.isContentEditable);
    if (e.key === '?' && !typing) {
      e.preventDefault();
      toggleKbdOverlay();
      return;
    }
    if (e.key === '/' || ((e.ctrlKey || e.metaKey) && e.key === 'f')) {
      if (typing) return;
      e.preventDefault();
      searchInput.focus();
      searchInput.select();
    }
  });

  // ---- Sidebar views ----
  // Map per-section requirement status → glyph + tooltip + CSS modifier.
  // `req_status` is computed server-side and travels in SCH_INDEX.sections[].
  function reqStatusBadge(s) {
    var st = s.req_status || 'empty';
    var icon = st === 'ok' ? '✓'
             : st === 'warn' ? '⚠'
             : st === 'fail' ? '✗'
             : '·';
    var tip;
    if (st === 'ok') {
      tip = (s.req_pass || 0) + ' pass · ' + (s.req_verified || 0) + ' verified — all requirements satisfied';
    } else if (st === 'warn') {
      tip = (s.req_pass || 0) + ' pass · ' + (s.req_verified || 0) + ' verified · '
          + (s.req_na || 0) + ' unanswered · ' + (s.req_overridden || 0) + ' override';
    } else if (st === 'fail') {
      tip = (s.req_fail || 0) + ' failing · ' + (s.req_na || 0) + ' unanswered · '
          + (s.req_pass || 0) + ' pass · ' + (s.req_verified || 0) + ' verified';
    } else {
      tip = 'No requirement-bearing instances in this section';
    }
    return '<span class="sb-req-icon req-' + st + '" title="' + escapeHtml(tip) + '">'
         + icon + '</span>';
  }

  // Build the small "Audit" block that sits above the Sections list when
  // a review-doc is attached to the page. Each item is a click-target that
  // scrolls to the matching `#page-…` anchor (the audit chunks rendered at
  // the bottom of the schematic body).
  function auditListHtml() {
    var a = (typeof SCH_AUDIT !== 'undefined') ? SCH_AUDIT : null;
    if (!a || !a.present) return '';
    var unresolvedCount = a.unresolved || 0;
    var unresolvedClass = unresolvedCount > 0 ? 'req-warn' : 'req-ok';
    var unresolvedLabel = unresolvedCount > 0
      ? unresolvedCount + ' issue' + (unresolvedCount === 1 ? '' : 's')
      : 'clean';
    var html = '<h4>Audit</h4>';
    html += '<div class="sb-list-item sb-audit-item" data-anchor="page-unresolved">' +
      '<div class="sb-li-head"><span class="sb-req-icon ' + unresolvedClass + '">' +
      (unresolvedCount > 0 ? '⚠' : '✓') + '</span>' +
      '<span>Unresolved issues</span></div>' +
      '<div class="sb-li-sub">' + escapeHtml(unresolvedLabel) + '</div>' +
      '</div>';
    if (a.assertion_total && a.assertion_total > 0) {
      var failCount = a.assertion_fail || 0;
      var assertClass = failCount > 0 ? 'req-fail' : 'req-ok';
      var assertLabel = failCount > 0
        ? failCount + ' failing of ' + a.assertion_total
        : a.assertion_total + ' passing';
      html += '<div class="sb-list-item sb-audit-item" data-anchor="page-assertions">' +
        '<div class="sb-li-head"><span class="sb-req-icon ' + assertClass + '">' +
        (failCount > 0 ? '✗' : '✓') + '</span>' +
        '<span>Assertions</span></div>' +
        '<div class="sb-li-sub">' + escapeHtml(assertLabel) + '</div>' +
        '</div>';
    }
    return html;
  }

  function showSectionList() {
    var auditHtml = auditListHtml();
    if (!SCH_INDEX.sections || !SCH_INDEX.sections.length) {
      detailBox.innerHTML = auditHtml + '<div class="sb-empty">No sections.</div>';
      wireAuditClicks();
      return;
    }
    var html = auditHtml + '<h4>Sections</h4>';
    SCH_INDEX.sections.forEach(function (s) {
      var catPill = s.category
        ? '<span class="sb-cat cat-' + s.category + '">' + escapeHtml(s.category) + '</span>'
        : '';
      html += '<div class="sb-list-item" data-slug="' + escapeHtml(s.slug) + '">' +
        '<div class="sb-li-head">' + reqStatusBadge(s) + catPill + '<span>' + escapeHtml(s.name) + '</span></div>';
      if (s.description) html += '<div class="sb-li-sub">' + escapeHtml(s.description) + '</div>';
      html += '</div>';
    });
    detailBox.innerHTML = html;
    wireAuditClicks();
    detailBox.querySelectorAll('.sb-list-item[data-slug]').forEach(function (el) {
      el.addEventListener('click', function () { showSection(el.dataset.slug, true); });
    });
  }

  function wireAuditClicks() {
    detailBox.querySelectorAll('.sb-audit-item[data-anchor]').forEach(function (el) {
      el.addEventListener('click', function () {
        // The bottom-of-page audit sections (Unresolved issues / Assertions)
        // were removed; both audit items now open the ERC panel, which lists
        // the ERC violations and the design's assertions together.
        showErc();
      });
    });
  }

  function showSection(slug, doScroll) {
    var sec = sectionBySlug[slug];
    if (!sec) return;
    if (doScroll) {
      // Sub-blocks attached inside a section render with id="sub-{slug}" to
      // avoid colliding with a section that happens to share the same slug
      // ("USB" / "usb"). Prefer the section anchor when both exist so the
      // user lands on the parent card; fall back to the sub-block anchor.
      var anchor = document.getElementById('sec-' + slug) || document.getElementById('sub-' + slug);
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

  // Where to find this component on a PCB-layout view, or null when none
  // applies. Modules have a whole-module /pcb-layout/:name view; design
  // pages only have per-sub-block scoped views (?sub=<slug>), so the link
  // appears only when the instance lives inside a sub-block. The focus ref
  // for a sub-scoped view is the bare leaf (the scoped layout's refs are
  // module-local).
  function pcbLocateHref(ref, c) {
    if (typeof SCH_VIEW !== 'undefined' && SCH_VIEW === 'module') {
      return '/pcb-layout/' + encodeURIComponent(DESIGN_NAME) + '?focus=' + encodeURIComponent(ref);
    }
    var sec = c.section ? sectionBySlug[c.section] : null;
    if (sec && sec.sub) {
      var leaf = ref.indexOf('/') >= 0 ? ref.slice(ref.lastIndexOf('/') + 1) : ref;
      return '/pcb-layout/' + encodeURIComponent(DESIGN_NAME) +
        '?sub=' + encodeURIComponent(c.section) + '&focus=' + encodeURIComponent(leaf);
    }
    return null;
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
    var pcbHref = pcbLocateHref(ref, c);
    if (pcbHref) {
      html += '<div class="sb-pcb-locate"><a href="' + escapeHtml(pcbHref) +
        '" title="Open the PCB layout view zoomed to this part">Locate on PCB →</a></div>';
    }
    if (c.footprint) html += footprintPreviewHtml(c.footprint);
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
    loadFootprintPreview(detailBox);
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
      // Datasheet + requirements strip sits under the title, always visible.
      // Datasheets are declared in the component's lib/components/<name>.sexp
      // as `(datasheet "file.pdf")` and uploaded generically to /api/upload-
      // datasheet; this panel just links to whatever is declared. Requirements
      // are read-only rules ("VDD must be decoupled within 3mm") that tie
      // library parts to validation steps during schematic review.
      var safe = escapeHtml(componentName);
      var dsList = (data && data.datasheets) || [];
      html += '<div class="sb-datasheet" data-component="' + safe + '">';
      html += '<div class="sb-ds-title">Datasheets <span class="sb-ds-count muted">(' + dsList.length + ')</span></div>';
      if (dsList.length) {
        html += '<ul class="sb-ds-list">' + dsList.map(function (d) {
          var name = escapeHtml(d.name);
          var kb = d.size ? ' <span class="sb-ds-size">(' + Math.round(d.size / 1024) + ' KB)</span>' : ' <span class="sb-ds-missing">(uploaded file missing)</span>';
          return '<li><a href="/datasheets/' + encodeURIComponent(d.name) + '" target="_blank" rel="noopener">📄 ' + name + '</a>' + kb +
            ' <button class="sb-ds-unlink" data-pdf="' + name + '" title="Unlink from ' + safe + '">✕</button></li>';
        }).join('') + '</ul>';
      } else {
        html += '<div class="sb-ds-hint muted">No datasheets linked yet. Pick one below or upload a new PDF.</div>';
      }
      // Link UI: searchable picker populated from /api/datasheets, with an
      // inline upload for new PDFs. Selecting + clicking Link splices
      // `(datasheet "...")` into lib/components/<component>.sexp.
      html += '<div class="sb-ds-link-row">' +
        '<input type="text" class="sb-ds-search" list="sb-ds-options" placeholder="search uploaded PDFs…" />' +
        '<datalist id="sb-ds-options"></datalist>' +
        '<button class="sb-ds-link-btn">Link</button>' +
        '</div>';
      html += '<div class="sb-ds-upload-row">' +
        '<label class="sb-ds-upload-btn">📎 Upload &amp; link new PDF<input type="file" accept="application/pdf" class="sb-ds-upload-input" hidden></label>' +
        '<span class="sb-ds-status muted"></span>' +
        '</div>';
      html += '</div>';
      if (error) {
        html += '<div class="sb-empty">' + escapeHtml(error) + '</div>';
      } else if (!data || !data.pins || !data.pins.length) {
        html += '<div class="sb-empty">No pins in pinout file.</div>';
      } else {
        var wiredCount = 0;
        (data.pins || []).forEach(function (p) { if (wired[p.id]) wiredCount++; });
        html += '<div class="sb-comp-meta">' + data.pins.length + ' pins' +
          (fromRef ? ' · ' + wiredCount + ' wired on ' + escapeHtml(fromRef) : '') + '</div>' +
          '<input type="text" class="sb-pinout-filter" placeholder="Filter by pin / function / net (e.g. XSPI, VDD)" />' +
          '<div class="sb-pinout-rows">';
        var sorted = data.pins.slice().sort(function (a, b) { return cmpPin(a.id, b.id); });
        sorted.forEach(function (p) {
          var w = wired[p.id];
          var cls = 'sb-pinout-row' + (w ? ' is-wired' : '');
          var altHay = (p.alts || []).map(function (a) { return a.name; }).join(' ');
          var netHay = (w && w.net) ? w.net : '';
          var hay = (p.id + ' ' + (p.fn || '') + ' ' + altHay + ' ' + netHay).toLowerCase();
          html += '<div class="' + cls + '" data-hay="' + escapeHtml(hay) +
            '" data-pin="' + escapeHtml(p.id) +
            '" data-net="' + escapeHtml(w ? (w.net || '') : '') + '">' +
            '<div class="sb-pinout-head">' +
            '<span class="sb-pin-id">' + escapeHtml(p.id) + '</span>' +
            '<span class="sb-pinout-fn">' + escapeHtml(p.fn || '') + '</span>' +
            (w && w.net ? '<span class="sb-pinout-net" title="Wired to this net">' + escapeHtml(w.net) + '</span>' : '') +
            '</div>';
          if (p.alts && p.alts.length) {
            var activeAlt = (w && w.alt) ? w.alt : '';
            html += '<div class="sb-pinout-alts">' + p.alts.map(function (a) {
              var ac = (a.name === activeAlt) ? ' is-active' : '';
              var tip = ac ? ' title="In use on this schematic"' : '';
              return '<span class="sb-pinout-alt' + ac + '" data-type="' + escapeHtml(a.type || '') + '"' + tip + '>' +
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
      wireDatasheetControls(componentName, fromRef);
    }

    // Wire up link / unlink / upload buttons in the datasheet strip. Kept
    // outside `render()` so it can be re-entrant after an action — each
    // action invalidates the pinout cache and re-fetches so the panel
    // shows the new linked set.
    function wireDatasheetControls(componentName, fromRef) {
      var linkedSet = {};
      ((pinoutCache[componentName] && pinoutCache[componentName].datasheets) || []).forEach(function (d) { linkedSet[d.name] = true; });

      // Populate the <datalist> with uploaded PDFs that aren't already linked
      // so the search picker only offers meaningful choices.
      var datalist = detailBox.querySelector('#sb-ds-options');
      fetch('/api/datasheets').then(function (r) { return r.ok ? r.json() : { files: [] }; }).then(function (j) {
        if (!datalist) return;
        var options = (j.files || []).filter(function (f) { return !linkedSet[f.name]; })
          .map(function (f) { return '<option value="' + escapeHtml(f.name) + '">'; }).join('');
        datalist.innerHTML = options;
      });

      detailBox.querySelectorAll('.sb-ds-unlink').forEach(function (btn) {
        btn.addEventListener('click', function (e) {
          e.stopPropagation();
          var pdf = btn.getAttribute('data-pdf');
          if (!pdf) return;
          if (!confirm('Unlink ' + pdf + ' from ' + componentName + '?')) return;
          fetch('/api/component-datasheet/' + encodeURIComponent(componentName) + '/remove', {
            method: 'POST', headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ pdf: pdf }),
          }).then(function (r) { return r.json(); }).then(function (j) {
            if (!j.ok) throw new Error(j.error || 'failed');
            delete pinoutCache[componentName];
            showPinout(componentName, fromRef);
          }).catch(function (err) { alert('Unlink failed: ' + err.message); });
        });
      });

      var linkInput = detailBox.querySelector('.sb-ds-search');
      var linkBtn = detailBox.querySelector('.sb-ds-link-btn');
      function doLink(pdf) {
        if (!pdf) return;
        fetch('/api/component-datasheet/' + encodeURIComponent(componentName) + '/add', {
          method: 'POST', headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ pdf: pdf }),
        }).then(function (r) { return r.json(); }).then(function (j) {
          if (!j.ok) throw new Error(j.error || 'failed');
          delete pinoutCache[componentName];
          showPinout(componentName, fromRef);
        }).catch(function (err) { alert('Link failed: ' + err.message); });
      }
      if (linkBtn && linkInput) {
        linkBtn.addEventListener('click', function () { doLink(linkInput.value.trim()); });
        linkInput.addEventListener('keydown', function (e) {
          if (e.key === 'Enter') { e.preventDefault(); doLink(linkInput.value.trim()); }
        });
      }

      var uploadInput = detailBox.querySelector('.sb-ds-upload-input');
      var status = detailBox.querySelector('.sb-ds-status');
      if (uploadInput) {
        uploadInput.addEventListener('change', function () {
          var file = uploadInput.files && uploadInput.files[0];
          if (!file) return;
          if (file.size > 64 * 1024 * 1024) {
            status.textContent = 'too large (64MB limit)';
            return;
          }
          status.textContent = 'uploading ' + file.name + '…';
          fetch('/api/upload-datasheet', {
            method: 'POST',
            headers: { 'Content-Type': 'application/pdf', 'x-filename': file.name },
            body: file,
          }).then(function (r) { return r.json(); }).then(function (j) {
            if (!j.ok) throw new Error(j.error || 'upload failed');
            status.textContent = 'linking ' + j.name + '…';
            // Chain link after upload so one click both uploads and attaches.
            return fetch('/api/component-datasheet/' + encodeURIComponent(componentName) + '/add', {
              method: 'POST', headers: { 'Content-Type': 'application/json' },
              body: JSON.stringify({ pdf: j.name }),
            }).then(function (r) { return r.json(); });
          }).then(function (j) {
            if (!j.ok && j.error !== 'DuplicateImport') throw new Error(j.error || 'link failed');
            delete pinoutCache[componentName];
            showPinout(componentName, fromRef);
          }).catch(function (err) {
            status.textContent = 'error: ' + err.message;
          });
          uploadInput.value = '';
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

  // ---- Footprint preview ----
  // Builds the preview shell up front (so layout doesn't jump) and lets
  // loadFootprintPreview fetch the SVG lazily once the panel is in the DOM.
  // /api/footprint/:name draws pads + silkscreen from lib/footprints/<fp>.sexp.
  function footprintPreviewHtml(fp) {
    return '<div class="sb-fp-preview" data-fp="' + escapeHtml(fp) + '">' +
      '<div class="sb-fp-title">Footprint <span class="muted">' + escapeHtml(fp) + '</span></div>' +
      '<div class="sb-fp-svg"><span class="sb-fp-empty muted">Loading preview…</span></div>' +
      '</div>';
  }

  var fpSvgCache = {};
  function loadFootprintPreview(scope) {
    var box = scope.querySelector('.sb-fp-preview');
    if (!box) return;
    var fp = box.dataset.fp;
    var target = box.querySelector('.sb-fp-svg');
    if (!fp || !target) return;
    function fill(data) {
      var s = FP.el('svg', {});
      FP.drawFootprint(s, data);
      s.style.width = '100%'; s.style.height = 'auto'; s.style.maxHeight = '220px'; s.style.display = 'block'; s.style.borderRadius = '4px';
      target.innerHTML = ''; target.appendChild(s);
    }
    function fail() {
      target.innerHTML = '<span class="sb-fp-empty muted">No footprint preview available.</span>';
    }
    if (fpSvgCache[fp] !== undefined) {
      if (fpSvgCache[fp]) fill(fpSvgCache[fp]); else fail();
      return;
    }
    fetch('/api/footprint/' + encodeURIComponent(fp)).then(function (r) {
      if (!r.ok) throw new Error('no preview');
      return r.json();
    }).then(function (data) {
      if (!data || !data.pads) throw new Error('empty');
      fpSvgCache[fp] = data;
      fill(data);
    }).catch(function () {
      fpSvgCache[fp] = '';
      fail();
    });
  }

  // ---- Reload from disk ----
  // POSTs /api/push/:name so the server re-reads the .sexp source and bumps
  // live_version; the version poll below picks that up and reloads the page.
  var reloadBtn = document.getElementById('reload-btn');
  if (reloadBtn) {
    reloadBtn.addEventListener('click', function () {
      if (reloadBtn.dataset.busy === '1') return;
      reloadBtn.dataset.busy = '1';
      var original = reloadBtn.textContent;
      reloadBtn.textContent = 'Reloading…';
      fetch('/api/push/' + DESIGN_NAME, { method: 'POST' }).then(function (r) {
        if (!r.ok) throw new Error('push failed: ' + r.status);
        // Force an immediate refresh — the version poll would catch up within
        // ~2 s, but the user clicked, so don't make them wait.
        window.location.reload();
      }).catch(function (e) {
        reloadBtn.textContent = original;
        reloadBtn.dataset.busy = '';
        alert('Reload failed: ' + e);
      });
    });
  }

  // ---- Toast (shared result notifications) ----
  // One floating toast at the bottom of the page; ok/err/warn accent bar.
  var toastEl = null, toastTimer = null;
  function schToast(msg, kind, ms) {
    if (!toastEl) {
      toastEl = document.createElement('div');
      document.body.appendChild(toastEl);
    }
    toastEl.className = 'sch-toast' + (kind ? ' ' + kind : '');
    toastEl.textContent = msg;
    toastEl.style.display = '';
    clearTimeout(toastTimer);
    toastTimer = setTimeout(function () { toastEl.style.display = 'none'; }, ms || 6000);
  }

  // ---- Push to KiCad PCB ----
  // New flow: clicking Push (or Push + Delete Stale) first POSTs the sync
  // with ?dry_run=1, shows the would-be op list + summary counts in a
  // preview modal, and only on Confirm POSTs the real (writing) sync. The
  // result — applied-op counts, lock-file warning, or the server's error
  // body (e.g. "design has no (kicad-pcb …) form") — lands in a toast.
  var pushPcbBtn = document.getElementById('push-kicad-pcb-btn');
  var pushPcbPruneBtn = document.getElementById('push-kicad-pcb-prune-btn');
  var pushPcbDotBtn = document.getElementById('push-kicad-pcb-dotnets-btn');
  var pushPcbRefreshBtn = document.getElementById('push-kicad-pcb-refresh-btn');
  var pushPcbStatus = document.getElementById('push-kicad-pcb-status');

  // One-line label for a sync op in the preview list: kind + the most
  // identifying fields the op carries (ref / field / net / value).
  function kicadOpLabel(op) {
    var bits = [];
    if (op.ref) bits.push(op.ref);
    if (op.name) bits.push(op.name);
    if (op.field) bits.push(op.field);
    if (op.net) bits.push('net ' + op.net);
    if (op.footprint_name) bits.push(op.footprint_name);
    if (op.value !== undefined && op.value !== '') bits.push('= ' + op.value);
    if (!bits.length && op.uuid) bits.push(op.uuid);
    return bits.join(' · ');
  }

  // Categorised op list for the preview modal. Board-shape changes (parts
  // added/removed, footprint re-bakes, refdes renames, value edits, stale
  // flags) render as headed sections up top; the high-volume metadata ops
  // (canopy_* / MPN field updates, pad-net rewires, vias, staging graphics)
  // collapse into <details> folds so they don't bury what matters.
  function buildKicadOpsHtml(ops) {
    var cats = { add: [], remove: [], swap: [], rename: [], value: [], stale: [], fields: [], padnets: [], vias: [], graphics: [], other: [] };
    ops.forEach(function (op) {
      if (op.op === 'add') cats.add.push(op);
      else if (op.op === 'remove') cats.remove.push(op);
      else if (op.op === 'swap_footprint') cats.swap.push(op);
      else if (op.op === 'flag_stale') cats.stale.push(op);
      else if (op.op === 'set_field' && op.field === 'reference') cats.rename.push(op);
      else if (op.op === 'set_field' && op.field === 'value') cats.value.push(op);
      else if (op.op === 'set_field') cats.fields.push(op);
      else if (op.op === 'set_pad_net') cats.padnets.push(op);
      else if (op.op === 'add_via') cats.vias.push(op);
      else if (op.op === 'create_board_item') cats.graphics.push(op);
      else cats.other.push(op);
    });
    var html = '';
    function rows(list, kind, fmt) {
      return list.map(function (op) {
        return '<div class="kpv-op"><span class="op-kind k-' + kind + '">' + kind + '</span>' + fmt(op) + '</div>';
      }).join('');
    }
    function section(list, kind, title, hint, fmt) {
      if (!list.length) return;
      html += '<div class="kpv-cat"><span class="kpv-cat-title">' + title + ' (' + list.length + ')</span>' +
        (hint ? '<span class="kpv-cat-hint">' + hint + '</span>' : '') + '</div>' + rows(list, kind, fmt);
    }
    function fold(list, kind, title, hint, fmt) {
      if (!list.length) return;
      html += '<details class="kpv-fold"><summary>' + title + ' (' + list.length + ')' +
        (hint ? ' <span class="kpv-cat-hint">' + hint + '</span>' : '') + '</summary>' +
        rows(list, kind, fmt) + '</details>';
    }
    var esc = escapeHtml;
    function refOf(op) { return esc(op.ref || op.uuid || '?'); }
    section(cats.add, 'add', 'Add parts', 'new on the board — staged off to the side, drag into place', function (op) {
      return refOf(op) + (op.footprint_name ? ' · ' + esc(op.footprint_name) : '') +
        (op.value ? ' · = ' + esc(op.value) : '');
    });
    section(cats.remove, 'remove', 'Remove parts', 'deleted from the board', refOf);
    section(cats.swap, 'fp', 'Footprint re-bakes', 'geometry refreshed in place — position, side & routing preserved', function (op) {
      return refOf(op) + (op.new_footprint_name ? ' · ' + esc(op.new_footprint_name) : '');
    });
    section(cats.rename, 'rename', 'Refdes renames', 'reference text only — same part, footprint & position unchanged', function (op) {
      return (op.old ? esc(op.old) : '?') + ' → ' + esc(op.value || '');
    });
    section(cats.value, 'value', 'Value changes', '', function (op) {
      return refOf(op) + ' · ' + (op.old ? esc(op.old) + ' → ' : '') + esc(op.value || '');
    });
    section(cats.stale, 'stale', 'Stale parts', 'on the board but not in the design — flagged only, nothing removed', refOf);
    fold(cats.fields, 'field', 'Field updates', 'metadata only (canopy_section, MPN, …) — nothing moves', function (op) {
      return (op.ref ? esc(op.ref) + ' · ' : '') + esc(op.field || '') + ' = ' + esc(op.value || '');
    });
    fold(cats.padnets, 'net', 'Pad-net updates', 'pad → net assignments', function (op) {
      return (op.ref ? esc(op.ref) + ' · ' : '') + 'pad ' + esc(op.pad || '') + ' → ' + (op.net ? esc(op.net) : '(cleared)');
    });
    fold(cats.vias, 'via', 'Stitching vias', 'fresh-board seeding only', function (op) {
      var x = op.x !== undefined ? (op.x / 1e6).toFixed(1) : '?';
      var y = op.y !== undefined ? (op.y / 1e6).toFixed(1) : '?';
      return esc(op.net || '') + ' @ ' + x + ', ' + y + ' mm';
    });
    fold(cats.graphics, 'gfx', 'Staging graphics', 'box + label around staged parts', function () {
      return 'section box / label';
    });
    fold(cats.other, 'op', 'Other', '', function (op) {
      return esc(op.op || '?') + ' · ' + esc(kicadOpLabel(op));
    });
    return html;
  }

  function kicadSummaryChips(s) {
    var keys = ['updated', 'added', 'removed', 'swapped', 'flagged_stale', 'suppressed', 'vias'];
    return keys.map(function (k) {
      var n = (s && s[k]) || 0;
      return '<span class="kpv-chip' + (n > 0 ? ' hot' : '') + '">' + n + ' ' + k.replace('_', ' ') + '</span>';
    }).join('');
  }

  // Build + show the dry-run preview modal. confirm() runs the real push.
  function showKicadPreview(title, dryJson, onConfirm) {
    var ops = (dryJson && dryJson.ops) || [];
    var overlay = document.createElement('div');
    overlay.className = 'kpv-overlay';
    var opsHtml = ops.length
      ? buildKicadOpsHtml(ops)
      : '<div class="kpv-empty">No changes — the board already matches the design.</div>';
    overlay.innerHTML =
      '<div class="kpv-box">' +
        '<div class="kpv-head"><h3>' + escapeHtml(title) + ' — preview</h3>' +
          '<button class="kpv-x" title="Close">✕</button></div>' +
        '<div class="kpv-summary">' + kicadSummaryChips(dryJson && dryJson.summary) + '</div>' +
        '<div class="kpv-ops">' + opsHtml + '</div>' +
        '<div class="kpv-foot">' +
          '<button class="kpv-btn kpv-cancel">Cancel</button>' +
          '<button class="kpv-btn primary kpv-confirm">Confirm — write board</button>' +
        '</div>' +
      '</div>';
    document.body.appendChild(overlay);
    function close() { if (overlay.parentNode) overlay.parentNode.removeChild(overlay); }
    overlay.addEventListener('mousedown', function (e) { if (e.target === overlay) close(); });
    overlay.querySelector('.kpv-x').addEventListener('click', close);
    overlay.querySelector('.kpv-cancel').addEventListener('click', close);
    var confirmBtn = overlay.querySelector('.kpv-confirm');
    confirmBtn.addEventListener('click', function () {
      confirmBtn.disabled = true;
      confirmBtn.textContent = 'Writing…';
      onConfirm(close, function () {
        confirmBtn.disabled = false;
        confirmBtn.textContent = 'Confirm — write board';
      });
    });
  }

  // Format the real-push success body ({applied:{…}, warning?}) for the toast.
  function kicadAppliedMessage(j) {
    var a = (j && j.applied) || {};
    var msg = '✓ Wrote ' +
      (a.added || 0) + ' added, ' +
      (a.removed || 0) + ' removed, ' +
      (a.swapped || 0) + ' swapped, ' +
      (a.pad_nets_set || 0) + ' pad-nets, ' +
      (a.fields_set || 0) + ' fields';
    if (a.fields_hidden) msg += ', ' + a.fields_hidden + ' fields hidden';
    if (a.fields_shown) msg += ', ' + a.fields_shown + ' fields shown';
    if (j && j.warning) msg += ' — ⚠ ' + j.warning;
    return msg;
  }

  // Wire a Push button to the dry-run → modal → confirm flow. `extraQuery`
  // (e.g. "prune=1") is retained on BOTH the dry-run and the real POST.
  function wireKicadPreviewButton(btn, title, extraQuery, runningLabel) {
    if (!btn) return;
    var base = '/api/sync-kicad-pcb/' + DESIGN_NAME;
    var realUrl = base + (extraQuery ? '?' + extraQuery : '');
    var dryUrl = base + '?dry_run=1' + (extraQuery ? '&' + extraQuery : '');
    btn.addEventListener('click', function () {
      if (btn.dataset.busy === '1') return;
      btn.dataset.busy = '1';
      var original = btn.textContent;
      btn.textContent = runningLabel;
      fetch(dryUrl, { method: 'POST' }).then(function (r) {
        return r.text().then(function (body) { return { ok: r.ok, body: body }; });
      }).then(function (resp) {
        btn.textContent = original;
        btn.dataset.busy = '';
        if (!resp.ok) {
          // Missing (kicad-pcb …) form / unreachable board file → server's
          // error text, never silence.
          schToast(resp.body || 'Preview failed.', 'err', 9000);
          return;
        }
        var dry = {};
        try { dry = JSON.parse(resp.body); } catch (_e) {}
        showKicadPreview(title, dry, function (closeModal, resetConfirm) {
          fetch(realUrl, { method: 'POST' }).then(function (r) {
            return r.text().then(function (body) { return { ok: r.ok, body: body }; });
          }).then(function (resp2) {
            if (!resp2.ok) {
              resetConfirm();
              schToast(resp2.body || 'Push failed.', 'err', 9000);
              return;
            }
            var j = {};
            try { j = JSON.parse(resp2.body); } catch (_e) {}
            closeModal();
            schToast(kicadAppliedMessage(j), (j && j.warning) ? 'warn' : 'ok', 8000);
          }).catch(function (e) {
            resetConfirm();
            schToast('Push failed: ' + e, 'err', 9000);
          });
        });
      }).catch(function (e) {
        btn.textContent = original;
        btn.dataset.busy = '';
        schToast('Preview failed: ' + e, 'err', 9000);
      });
    });
  }

  // Shared click handler so the plain Push and Push + Delete Stale
  // buttons stay in lock-step on busy-state, status text, error
  // formatting, and the success summary. The only thing that varies
  // is the URL query (`?prune=1`) and the running-label.
  function wireKicadPushButton(btn, url, runningLabel) {
    if (!btn) return;
    btn.addEventListener('click', function () {
      if (btn.dataset.busy === '1') return;
      btn.dataset.busy = '1';
      var original = btn.textContent;
      btn.textContent = runningLabel;
      if (pushPcbStatus) {
        pushPcbStatus.textContent = '';
        pushPcbStatus.style.color = '';
      }
      fetch(url, { method: 'POST' }).then(function (r) {
        return r.text().then(function (body) { return { ok: r.ok, body: body }; });
      }).then(function (resp) {
        btn.textContent = original;
        btn.dataset.busy = '';
        if (!resp.ok) {
          if (pushPcbStatus) {
            pushPcbStatus.textContent = resp.body || 'Push failed.';
            pushPcbStatus.style.color = '#f85149';
          }
          return;
        }
        var j = {};
        try { j = JSON.parse(resp.body); } catch (_e) {}
        var a = (j && j.applied) || {};
        var msg = '✓ Wrote ' +
          (a.added || 0) + ' added, ' +
          (a.removed || 0) + ' removed, ' +
          (a.swapped || 0) + ' swapped, ' +
          (a.pad_nets_set || 0) + ' pad-nets, ' +
          (a.fields_set || 0) + ' fields';
        if (a.fields_hidden) msg += ', ' + a.fields_hidden + ' fields hidden';
        if (a.fields_shown) msg += ', ' + a.fields_shown + ' fields shown';
        if (j && j.warning) {
          msg += ' — ⚠ ' + j.warning;
          if (pushPcbStatus) pushPcbStatus.style.color = '#d29922';
        } else if (pushPcbStatus) {
          pushPcbStatus.style.color = '#3fb950';
        }
        if (pushPcbStatus) pushPcbStatus.textContent = msg;
      }).catch(function (e) {
        btn.textContent = original;
        btn.dataset.busy = '';
        if (pushPcbStatus) {
          pushPcbStatus.textContent = 'Push failed: ' + e;
          pushPcbStatus.style.color = '#f85149';
        }
      });
    });
  }
  // Push + Prune go through the dry-run preview modal; the dot-nets and
  // footprint-refresh variants keep the direct one-shot path (their op
  // streams are huge and mechanical — a preview adds nothing).
  wireKicadPreviewButton(pushPcbBtn, 'Push to KiCad PCB', '', 'Previewing…');
  wireKicadPreviewButton(pushPcbPruneBtn, 'Push + Delete Stale', 'prune=1', 'Previewing…');
  wireKicadPushButton(pushPcbDotBtn, '/api/sync-kicad-pcb/' + DESIGN_NAME + '?dot_nets=1', 'Pushing (per-pin nets)…');
  wireKicadPushButton(pushPcbRefreshBtn, '/api/sync-kicad-pcb/' + DESIGN_NAME + '?refresh=1', 'Refreshing footprints…');

  // ---- Copy SRC ----
  // Fetches the raw .sexp source via /api/source/:name and writes it to the
  // clipboard. Falls back to a hidden textarea + execCommand when the async
  // Clipboard API is unavailable (older browsers, non-HTTPS contexts).
  var copySrcBtn = document.getElementById('copy-src-btn');
  if (copySrcBtn) {
    copySrcBtn.addEventListener('click', function () {
      if (copySrcBtn.dataset.busy === '1') return;
      copySrcBtn.dataset.busy = '1';
      var original = copySrcBtn.textContent;
      copySrcBtn.textContent = 'Copying…';
      fetch('/api/source/' + DESIGN_NAME).then(function (r) {
        if (!r.ok) throw new Error('fetch failed: ' + r.status);
        return r.json();
      }).then(function (j) {
        var src = (j && typeof j.source === 'string') ? j.source : '';
        if (!src) throw new Error('empty source');
        return copyToClipboard(src);
      }).then(function () {
        copySrcBtn.textContent = '✓ Copied';
        setTimeout(function () {
          copySrcBtn.textContent = original;
          copySrcBtn.dataset.busy = '';
        }, 1200);
      }).catch(function (e) {
        copySrcBtn.textContent = original;
        copySrcBtn.dataset.busy = '';
        alert('Copy failed: ' + e);
      });
    });
  }

  function copyToClipboard(text) {
    if (navigator.clipboard && navigator.clipboard.writeText) {
      return navigator.clipboard.writeText(text);
    }
    return new Promise(function (resolve, reject) {
      try {
        var ta = document.createElement('textarea');
        ta.value = text;
        ta.style.position = 'fixed';
        ta.style.left = '-9999px';
        document.body.appendChild(ta);
        ta.select();
        var ok = document.execCommand('copy');
        document.body.removeChild(ta);
        if (ok) resolve(); else reject(new Error('execCommand returned false'));
      } catch (e) { reject(e); }
    });
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

  // Assertions block for the ERC panel — the design's `(assert …)` results,
  // read from the SCH_ASSERTIONS global injected by render_html.zig. Failing
  // and warning assertions render as items; passing ones collapse to a count
  // so the panel stays scannable. Returns '' when the design has none.
  function assertionsHtml() {
    var list = (typeof SCH_ASSERTIONS !== 'undefined') ? SCH_ASSERTIONS : [];
    if (!list || !list.length) return '';
    var fails = [], warns = [], passes = [];
    list.forEach(function (a) {
      if (a.status === 'fail') fails.push(a);
      else if (a.status === 'warn') warns.push(a);
      else passes.push(a);
    });
    var cls = fails.length ? 'err' : (warns.length ? 'warn' : 'info');
    var out = '<div class="erc-group-head ' + cls + '">Assertions (' + list.length + ')</div>';
    function items(arr, c) {
      arr.forEach(function (a) {
        out += '<div class="erc-item erc-' + c + '">' + escapeHtml(a.message) + '</div>';
      });
    }
    items(fails, 'err');
    items(warns, 'warn');
    if (passes.length) {
      out += '<div class="erc-item erc-info">✓ ' + passes.length + ' passing</div>';
    }
    return out;
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
    html += assertionsHtml();
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

  // ---- History panel (version snapshots + diff vs current) ----
  // Lists the stored snapshots from GET /api/history/:name (written by the
  // server before every save/build); "Diff vs current" fetches
  // GET /api/diff/:name?from=<id>&to=current and renders the structured
  // result grouped as Added / Removed / Changed / Net changes.
  var historyBtn = document.getElementById('history-btn');
  if (historyBtn) historyBtn.addEventListener('click', showHistory);

  function sbPanelHeader(title, onBack) {
    detailBox.innerHTML = '<span class="sb-back">← All sections</span><h4>' + escapeHtml(title) + '</h4>' +
      '<div class="sb-empty">Loading…</div>';
    detailBox.querySelector('.sb-back').addEventListener('click', onBack || showSectionList);
  }

  function showHistory() {
    sbPanelHeader('History', showSectionList);
    fetch('/api/history/' + encodeURIComponent(DESIGN_NAME))
      .then(function (r) { return r.json(); })
      .then(function (j) {
        var snaps = j.snapshots || [];
        var html = '<span class="sb-back">← All sections</span><h4>History</h4>';
        if (!snaps.length) {
          html += '<div class="sb-empty">No stored versions yet — a snapshot is taken before every save / build.</div>';
        } else {
          html += '<div class="sb-comp-meta">' + snaps.length + ' stored version' + (snaps.length === 1 ? '' : 's') + '</div>';
          snaps.forEach(function (s) {
            html += '<div class="hist-row">' +
              '<div class="hist-id">' + escapeHtml(s.id) + '</div>' +
              (s.description ? '<div class="hist-desc">' + escapeHtml(s.description) + '</div>' : '') +
              '<div class="hist-actions"><button class="hist-diff-btn" data-id="' + escapeHtml(s.id) + '">Diff vs current</button></div>' +
              '</div>';
          });
        }
        detailBox.innerHTML = html;
        detailBox.querySelector('.sb-back').addEventListener('click', showSectionList);
        detailBox.querySelectorAll('.hist-diff-btn').forEach(function (btn) {
          btn.addEventListener('click', function () { showVersionDiff(btn.dataset.id); });
        });
      })
      .catch(function (e) {
        detailBox.innerHTML = '<span class="sb-back">← All sections</span><h4>History</h4>' +
          '<div class="sb-empty">Error: ' + escapeHtml(String(e)) + '</div>';
        detailBox.querySelector('.sb-back').addEventListener('click', showSectionList);
      });
  }

  function diffGroup(title, items, render) {
    if (!items || !items.length) return '';
    var out = '<div class="diff-group">' + escapeHtml(title) + ' (' + items.length + ')</div>';
    items.forEach(function (it) { out += render(it); });
    return out;
  }

  function showVersionDiff(id) {
    sbPanelHeader('Diff ' + id + ' → current', showHistory);
    detailBox.querySelector('.sb-back').textContent = '← History';
    fetch('/api/diff/' + encodeURIComponent(DESIGN_NAME) + '?from=' + encodeURIComponent(id) + '&to=current')
      .then(function (r) {
        return r.json().then(function (j) { return { ok: r.ok, j: j }; });
      })
      .then(function (resp) {
        var html = '<span class="sb-back">← History</span><h4>Diff vs current</h4>' +
          '<div class="sb-comp-meta">' + escapeHtml(id) + ' → current</div>';
        if (!resp.ok) {
          html += '<div class="sb-empty">' + escapeHtml((resp.j && resp.j.error) || 'diff failed') + '</div>';
        } else {
          var d = resp.j.diff || {};
          html += diffGroup('Added', d.instances_added, function (e) {
            return '<div class="diff-item add">+ ' + escapeHtml(e.ref) + ' ' + escapeHtml(e.component) +
              (e.value ? ' · ' + escapeHtml(e.value) : '') + '</div>';
          });
          html += diffGroup('Removed', d.instances_removed, function (e) {
            return '<div class="diff-item del">− ' + escapeHtml(e.ref) + ' ' + escapeHtml(e.component) +
              (e.value ? ' · ' + escapeHtml(e.value) : '') + '</div>';
          });
          html += diffGroup('Value changes', d.value_changes, function (c) {
            return '<div class="diff-item chg">' + escapeHtml(c.ref) + ': ' + escapeHtml(c.old || '—') +
              ' → ' + escapeHtml(c.new || '—') + '</div>';
          });
          html += diffGroup('Footprint changes', d.footprint_changes, function (c) {
            return '<div class="diff-item chg">' + escapeHtml(c.ref) + ': ' + escapeHtml(c.old || '—') +
              ' → ' + escapeHtml(c.new || '—') + '</div>';
          });
          html += diffGroup('Net changes', d.net_changes, function (n) {
            var bits = [];
            (n.pins_added || []).forEach(function (p) { bits.push('+' + p); });
            (n.pins_removed || []).forEach(function (p) { bits.push('−' + p); });
            return '<div class="diff-item chg">' + escapeHtml(n.net) + ': ' + escapeHtml(bits.join(' ')) + '</div>';
          });
          var any = ['instances_added', 'instances_removed', 'value_changes', 'footprint_changes', 'net_changes']
            .some(function (k) { return d[k] && d[k].length; });
          if (!any) html += '<div class="diff-empty">No differences — this version matches the current source.</div>';
        }
        detailBox.innerHTML = html;
        detailBox.querySelector('.sb-back').addEventListener('click', showHistory);
      })
      .catch(function (e) {
        detailBox.innerHTML = '<span class="sb-back">← History</span><h4>Diff vs current</h4>' +
          '<div class="sb-empty">Error: ' + escapeHtml(String(e)) + '</div>';
        detailBox.querySelector('.sb-back').addEventListener('click', showHistory);
      });
  }

  // ---- KiCad menu (dropdown toggle for the two download buttons) ----
  (function () {
    var menu = document.querySelector('.kicad-menu');
    var btn = document.getElementById('kicad-btn');
    var panel = document.getElementById('kicad-panel');
    if (!menu || !btn || !panel) return;
    btn.addEventListener('click', function (e) { e.stopPropagation(); menu.classList.toggle('open'); });
    panel.addEventListener('click', function (e) { e.stopPropagation(); });
    document.addEventListener('click', function () { menu.classList.remove('open'); });
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

  // ---- Schematic BOM card: inline MPN / Manufacturer edit ----
  // Buttons live in a server-rendered table generated by writeSchematicBomHtml
  // (src/serve/bom_html.zig). data-ref carries a comma-joined list of ref-des
  // because each row may group multiple instances. The save handler iterates
  // and POSTs once per ref so the .bom sidecar gets updated for every member.
  function bomEditSetup(buttonClass, inputClass, propName, endpoint) {
    document.querySelectorAll('.' + buttonClass).forEach(function (btn) {
      var refs = (btn.getAttribute('data-ref') || '').split(',').filter(function (s) { return s.length > 0; });
      if (refs.length === 0) return;
      var input = btn.parentElement.querySelector('.' + inputClass);
      if (!input) return;
      function save() {
        var newVal = (input.value || '').trim();
        btn.textContent = '...';
        btn.disabled = true;
        input.classList.remove('bom-saved', 'bom-error');
        var i = 0, ok = true;
        function next() {
          if (!ok || i >= refs.length) {
            btn.disabled = false;
            if (ok) {
              btn.textContent = 'Saved';
              input.classList.add('bom-saved');
              setTimeout(function () { btn.textContent = 'Save'; input.classList.remove('bom-saved'); }, 2000);
            } else {
              btn.textContent = 'Error';
              input.classList.add('bom-error');
            }
            return;
          }
          var body = { ref: refs[i] };
          body[propName] = newVal;
          fetch(endpoint + '/' + DESIGN_NAME, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) })
            .then(function (r) { return r.json(); })
            .then(function (d) {
              if (!d.ok) ok = false;
              // Sync the live-version watermark forward so the 2s poll
              // doesn't notice OUR own edit and force a full page reload —
              // we already have the value the user typed, no refresh needed.
              if (d && typeof d.version === 'number') lastVersion = d.version;
              i++; next();
            })
            .catch(function () { ok = false; i++; next(); });
        }
        next();
      }
      btn.addEventListener('click', save);
      input.addEventListener('keydown', function (ev) { if (ev.key === 'Enter') { ev.preventDefault(); save(); } });
    });
  }
  bomEditSetup('sch-bom-mpn-save', 'sch-bom-mpn-edit', 'mpn', '/api/edit-mpn');
  bomEditSetup('sch-bom-mfr-save', 'sch-bom-mfr-edit', 'manufacturer', '/api/edit-mpn');

  // Design-notes panel: structured TODOs + free-form scratchpad. Same
  // file (`<design>.notes.md`) backs the MCP `add_design_note` /
  // `complete_design_note` tools, so checking off a task here is
  // identical to an agent stamping the completion date from a tool
  // call. Tasks go through /api/notes/:name/tasks/*; the scratchpad
  // round-trips through the raw GET/PUT /api/notes/:name endpoint.
  (function () {
    var taskBox = document.getElementById('sch-notes-tasks');
    var addForm = document.getElementById('sch-notes-add');
    var addText = document.getElementById('sch-notes-add-text');
    var scratchTa = document.getElementById('sch-notes-text');
    var status = document.getElementById('sch-notes-status');
    var notesCount = document.getElementById('sch-notes-count');
    if (!taskBox || !addForm || !addText || !scratchTa || !status) return;

    // Headline count shown in the collapsed Design Notes <summary>: how many
    // TODOs are still open. Cleared when the design has no tasks at all.
    function setNotesCount(openN, total) {
      if (!notesCount) return;
      if (!total) { notesCount.textContent = ''; return; }
      notesCount.textContent = openN > 0
        ? openN + ' to complete'
        : 'all ' + total + ' done';
    }

    var base = '/api/notes/' + encodeURIComponent(DESIGN_NAME);
    var lastScratchSaved = '';
    var saveTimer = null;
    var scratchSaving = false;
    var scratchPending = false;

    function setStatus(msg, isError) {
      status.textContent = msg;
      status.classList.toggle('is-error', !!isError);
    }
    function fmtTime() {
      var d = new Date();
      return d.toTimeString().slice(0, 5);
    }
    function escapeHtmlLocal(s) {
      return (s == null ? '' : String(s))
        .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
    }

    function renderTasks(tasks) {
      if (!tasks || !tasks.length) {
        setNotesCount(0, 0);
        taskBox.innerHTML = '<div class="sch-notes-empty muted">No TODOs yet. Add one below or call <code>add_design_note</code> from an MCP client.</div>';
        return;
      }
      // Open tasks first, then completed; preserve server order within each group.
      var open = [], done = [];
      tasks.forEach(function (t) { (t.completed ? done : open).push(t); });
      setNotesCount(open.length, tasks.length);
      var rows = open.concat(done);
      taskBox.innerHTML = rows.map(function (t) {
        var doneClass = t.completed ? ' is-done' : '';
        var checked = t.completed ? ' checked' : '';
        var dateLabel = t.completed
          ? escapeHtmlLocal(t.created) + ' → ' + escapeHtmlLocal(t.completed)
          : escapeHtmlLocal(t.created);
        return '<div class="sch-notes-task' + doneClass + '" data-id="' + escapeHtmlLocal(t.id) + '">' +
          '<input type="checkbox" class="sch-notes-task-check"' + checked + ' aria-label="Toggle complete">' +
          '<div class="sch-notes-task-body">' +
          '<div class="sch-notes-task-text">' + escapeHtmlLocal(t.text) + '</div>' +
          '<div class="sch-notes-task-meta muted">' + dateLabel + ' · <code>' + escapeHtmlLocal(t.id) + '</code></div>' +
          '</div>' +
          '<button type="button" class="sch-notes-task-remove" aria-label="Remove" title="Remove">×</button>' +
          '</div>';
      }).join('');
    }

    function refreshTasks() {
      return fetch(base + '/tasks').then(function (r) {
        if (!r.ok) throw new Error('HTTP ' + r.status);
        return r.json();
      }).then(function (j) {
        renderTasks(j.tasks || []);
        // The scratchpad textarea always reflects what's parsed out of the file,
        // not the raw text — keeps the two views in sync after structured edits.
        scratchTa.value = j.scratchpad || '';
        lastScratchSaved = scratchTa.value;
        setStatus('');
      }).catch(function (err) {
        setStatus('could not load notes: ' + err.message, true);
      });
    }

    function postJson(path, body) {
      return fetch(path, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(body),
      }).then(function (r) {
        if (!r.ok) return r.text().then(function (t) { throw new Error('HTTP ' + r.status + ': ' + t); });
        return r.json();
      });
    }

    addForm.addEventListener('submit', function (e) {
      e.preventDefault();
      var text = addText.value.trim();
      if (!text) return;
      setStatus('adding…');
      postJson(base + '/tasks/add', { text: text }).then(function () {
        addText.value = '';
        return refreshTasks();
      }).then(function () { setStatus('added at ' + fmtTime()); })
        .catch(function (err) { setStatus('add failed: ' + err.message, true); });
    });

    taskBox.addEventListener('click', function (e) {
      var row = e.target.closest('.sch-notes-task');
      if (!row) return;
      var id = row.dataset.id;
      if (e.target.classList.contains('sch-notes-task-check')) {
        var endpoint = e.target.checked ? '/tasks/complete' : '/tasks/reopen';
        setStatus('updating…');
        postJson(base + endpoint, { id: id }).then(refreshTasks)
          .then(function () { setStatus('updated at ' + fmtTime()); })
          .catch(function (err) {
            setStatus('update failed: ' + err.message, true);
            e.target.checked = !e.target.checked;
          });
      } else if (e.target.classList.contains('sch-notes-task-remove')) {
        setStatus('removing…');
        postJson(base + '/tasks/remove', { id: id }).then(refreshTasks)
          .then(function () { setStatus('removed at ' + fmtTime()); })
          .catch(function (err) { setStatus('remove failed: ' + err.message, true); });
      }
    });

    function saveScratch() {
      if (scratchSaving) { scratchPending = true; return; }
      var text = scratchTa.value;
      if (text === lastScratchSaved) return;
      // Combine current tasks + new scratchpad by writing the full raw file.
      // The tasks list is the source of truth; we just need to preserve it
      // while replacing the trailing scratchpad portion.
      scratchSaving = true;
      setStatus('saving scratchpad…');
      fetch(base + '/tasks').then(function (r) { return r.json(); }).then(function (j) {
        var lines = (j.tasks || []).map(function (t) {
          if (t.completed) {
            return '- [x] ' + t.created + ' -> ' + t.completed + ' (' + t.id + ') ' + t.text;
          }
          return '- [ ] ' + t.created + ' (' + t.id + ') ' + t.text;
        });
        var raw = lines.join('\n');
        if (text.length > 0) raw = (raw.length ? raw + '\n\n' : '') + text;
        return fetch(base, {
          method: 'PUT',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ text: raw }),
        });
      }).then(function (r) {
        if (!r.ok) throw new Error('HTTP ' + r.status);
        lastScratchSaved = text;
        setStatus('saved at ' + fmtTime());
      }).catch(function (err) {
        setStatus('save failed: ' + err.message, true);
      }).then(function () {
        scratchSaving = false;
        if (scratchPending) { scratchPending = false; saveScratch(); }
      });
    }
    function scheduleScratchSave() {
      if (saveTimer) clearTimeout(saveTimer);
      saveTimer = setTimeout(saveScratch, 800);
    }
    scratchTa.addEventListener('input', scheduleScratchSave);
    scratchTa.addEventListener('blur', function () {
      if (saveTimer) { clearTimeout(saveTimer); saveTimer = null; }
      saveScratch();
    });

    refreshTasks();
  })();

  // ---- Full-file source editor ----
  // A single CodeMirror editor over the whole .sexp file. Each section's
  // "Edit src" button opens it (loading /api/source once) and scrolls to that
  // section's (section "…") line. Save POSTs the whole file to /api/source;
  // the server validates + snapshots + rebuilds, and the page reloads.
  var srcEditor = null; // { overlay, cm, errEl, secEl, saveBtn, loaded, loadPromise }

  function buildSourceEditor() {
    var overlay = document.createElement('div');
    overlay.className = 'src-edit-overlay';
    overlay.innerHTML =
      '<div class="src-edit-box">' +
        '<div class="src-edit-head"><h3>Edit source <span class="src-edit-sec"></span></h3>' +
          '<span class="src-edit-hint">Whole-file editor · ⌘/Ctrl-S to save</span></div>' +
        '<div class="src-edit-cm"></div>' +
        '<div class="src-edit-foot">' +
          '<span class="src-edit-err"></span>' +
          '<button type="button" class="src-edit-btn src-edit-cancel">Close</button>' +
          '<button type="button" class="src-edit-btn primary src-edit-save">Save</button>' +
        '</div>' +
      '</div>';
    document.body.appendChild(overlay);

    var cm = CodeMirror(overlay.querySelector('.src-edit-cm'), {
      value: 'Loading…',
      mode: 'scheme',
      theme: 'eda-dark',
      lineNumbers: true,
      matchBrackets: true,
      autoCloseBrackets: true,
      lineWrapping: false,
      indentUnit: 2,
      tabSize: 2
    });

    var state = {
      overlay: overlay,
      cm: cm,
      errEl: overlay.querySelector('.src-edit-err'),
      secEl: overlay.querySelector('.src-edit-sec'),
      saveBtn: overlay.querySelector('.src-edit-save'),
      loaded: false,
      loadPromise: null
    };

    function close() {
      if (overlay.parentNode) overlay.parentNode.removeChild(overlay);
      srcEditor = null;
    }
    overlay.querySelector('.src-edit-cancel').addEventListener('click', close);
    overlay.addEventListener('mousedown', function (e) { if (e.target === overlay) close(); });

    function save() {
      state.errEl.textContent = '';
      state.saveBtn.disabled = true;
      state.saveBtn.textContent = 'Saving…';
      fetch('/api/source/' + DESIGN_NAME, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ source: cm.getValue() })
      })
        .then(function (r) { return r.json().then(function (j) { return { ok: r.ok, j: j }; }); })
        .then(function (res) {
          if (!res.ok || !res.j.ok) throw new Error((res.j && res.j.error) || 'save failed');
          window.location.reload();
        })
        .catch(function (e) {
          state.errEl.textContent = e.message;
          state.saveBtn.disabled = false;
          state.saveBtn.textContent = 'Save';
        });
    }
    state.saveBtn.addEventListener('click', save);
    cm.setOption('extraKeys', { 'Cmd-S': save, 'Ctrl-S': save });

    state.loadPromise = fetch('/api/source/' + DESIGN_NAME)
      .then(function (r) { return r.json(); })
      .then(function (j) {
        cm.setValue(typeof j.source === 'string' ? j.source : '');
        state.loaded = true;
        setTimeout(function () { cm.refresh(); }, 0);
      })
      .catch(function (e) { state.errEl.textContent = 'Load failed: ' + e.message; });

    return state;
  }

  function scrollEditorToSection(state, sectionName) {
    function go() {
      state.secEl.textContent = sectionName ? '· ' + sectionName : '';
      if (!sectionName) { state.cm.focus(); return; }
      var doc = state.cm.getValue();
      var idx = doc.indexOf('(section "' + sectionName + '"');
      if (idx < 0) { state.cm.focus(); return; }
      var line = doc.slice(0, idx).split('\n').length - 1;
      state.cm.focus();
      state.cm.setCursor({ line: line, ch: 0 });
      var top = state.cm.charCoords({ line: line, ch: 0 }, 'local').top;
      state.cm.scrollTo(null, top - state.cm.getScrollInfo().clientHeight / 2);
      state.cm.addLineClass(line, 'background', 'cm-section-flash');
      setTimeout(function () { state.cm.removeLineClass(line, 'background', 'cm-section-flash'); }, 1500);
    }
    if (state.loaded) go(); else state.loadPromise.then(go);
  }

  function openSourceEditor(sectionName) {
    if (!window.CodeMirror) { alert('Source editor failed to load (CodeMirror missing)'); return; }
    if (!srcEditor) srcEditor = buildSourceEditor();
    scrollEditorToSection(srcEditor, sectionName);
  }

  document.addEventListener('click', function (e) {
    var btn = (e.target && e.target.closest) ? e.target.closest('.sec-edit-src') : null;
    if (!btn) return;
    e.preventDefault();
    openSourceEditor(btn.getAttribute('data-section'));
  });

  // ---- Diagram pan / zoom ----
  // Wheel zooms toward the cursor, drag pans, double-click (or the ⟲ button)
  // resets to fit. Drives each diagram SVG's viewBox so it stays crisp at any
  // zoom. A drag past a small threshold suppresses the follow-up click so the
  // node links keep working on a plain click.
  function setupDiagramZoom(svg) {
    var vb = (svg.getAttribute('viewBox') || '').trim().split(/[ ,]+/).map(Number);
    if (vb.length !== 4 || vb.some(isNaN)) return;
    var base = { x: vb[0], y: vb[1], w: vb[2], h: vb[3] };
    var cur = { x: base.x, y: base.y, w: base.w, h: base.h };
    var minW = base.w / 16, maxW = base.w * 1.2;

    function apply() { svg.setAttribute('viewBox', cur.x + ' ' + cur.y + ' ' + cur.w + ' ' + cur.h); }
    function reset() { cur.x = base.x; cur.y = base.y; cur.w = base.w; cur.h = base.h; apply(); }

    // Zoom by `factor` (>1 zooms out) keeping the point under (cx,cy) fixed.
    function zoomAt(factor, cx, cy) {
      var rect = svg.getBoundingClientRect();
      if (!rect.width || !rect.height) return;
      if (cur.w * factor > maxW) factor = maxW / cur.w;
      if (cur.w * factor < minW) factor = minW / cur.w;
      var px = (cx - rect.left) / rect.width;
      var py = (cy - rect.top) / rect.height;
      var sx = cur.x + px * cur.w, sy = cur.y + py * cur.h; // svg coord under cursor
      cur.w *= factor; cur.h *= factor;
      cur.x = sx - px * cur.w; cur.y = sy - py * cur.h;
      apply();
    }

    svg.addEventListener('wheel', function (e) {
      e.preventDefault();
      zoomAt(e.deltaY < 0 ? 0.85 : 1 / 0.85, e.clientX, e.clientY);
    }, { passive: false });

    var dragging = false, sx0 = 0, sy0 = 0, ox = 0, oy = 0, moved = false;
    svg.addEventListener('pointerdown', function (e) {
      if (e.button !== 0) return;
      dragging = true; moved = false; sx0 = e.clientX; sy0 = e.clientY; ox = cur.x; oy = cur.y;
      try { svg.setPointerCapture(e.pointerId); } catch (_) {}
    });
    svg.addEventListener('pointermove', function (e) {
      if (!dragging) return;
      var rect = svg.getBoundingClientRect();
      if (!rect.width) return;
      cur.x = ox - (e.clientX - sx0) / rect.width * cur.w;
      cur.y = oy - (e.clientY - sy0) / rect.height * cur.h;
      if (Math.abs(e.clientX - sx0) + Math.abs(e.clientY - sy0) > 4) moved = true;
      apply();
    });
    function endDrag(e) { if (!dragging) return; dragging = false; try { svg.releasePointerCapture(e.pointerId); } catch (_) {} }
    svg.addEventListener('pointerup', endDrag);
    svg.addEventListener('pointercancel', endDrag);
    // Capture-phase: swallow the click that follows a real drag.
    svg.addEventListener('click', function (e) {
      if (moved) { e.stopImmediatePropagation(); e.preventDefault(); moved = false; }
    }, true);
    svg.addEventListener('dblclick', function (e) { e.preventDefault(); reset(); });

    // Wrap the SVG so the zoom buttons can sit over its top-right corner.
    var wrap = document.createElement('div');
    wrap.className = 'dg-view';
    svg.parentNode.insertBefore(wrap, svg);
    wrap.appendChild(svg);
    var bar = document.createElement('div');
    bar.className = 'dg-zoom';
    function centerZoom(factor) {
      var r = svg.getBoundingClientRect();
      zoomAt(factor, r.left + r.width / 2, r.top + r.height / 2);
    }
    function mkBtn(label, title, fn) {
      var b = document.createElement('button');
      b.type = 'button'; b.textContent = label; b.title = title;
      b.addEventListener('click', function (e) { e.preventDefault(); fn(); });
      bar.appendChild(b);
    }
    mkBtn('+', 'Zoom in', function () { centerZoom(0.8); });
    mkBtn('−', 'Zoom out', function () { centerZoom(1 / 0.8); });
    mkBtn('⟲', 'Reset view', reset);
    wrap.appendChild(bar);
  }
  document.querySelectorAll('.dg-svg').forEach(setupDiagramZoom);

  // ---- Cross-probe via URL hash ----
  // /schematics/:name#comp-<REF> (the PCB sidebar's "Show in schematic" link)
  // scrolls to that component and flashes it, reusing the search-result
  // selection path. Exact ref first, then bare sub-block leaf (U2 matches
  // pwr/U2). Also handles in-page hash changes.
  function componentFromHash() {
    var h = location.hash || '';
    if (h.indexOf('#comp-') !== 0) return null;
    var want = decodeURIComponent(h.slice(6));
    if (compByRef[want]) return want;
    var found = null;
    (SCH_INDEX.components || []).forEach(function (c) {
      if (found) return;
      var r = c.ref;
      var leaf = r.indexOf('/') >= 0 ? r.slice(r.lastIndexOf('/') + 1) : r;
      if (leaf === want) found = r;
    });
    return found;
  }
  function applyHashFocus() {
    var ref = componentFromHash();
    if (ref) showComponent(ref, true);
    return !!ref;
  }
  window.addEventListener('hashchange', applyHashFocus);

  // ---- Boot ----
  if (!applyHashFocus()) showSectionList();
})();
