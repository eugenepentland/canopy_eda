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
        var anchor = document.getElementById(el.dataset.anchor);
        if (anchor) { scrollTo(anchor); flash(anchor); }
      });
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
      // Datasheet + requirements strip sits under the title, always visible.
      // Datasheets are declared in the component's lib/components/<name>.sexp
      // as `(datasheet "file.pdf")` and uploaded generically to /api/upload-
      // datasheet; this panel just links to whatever is declared. Requirements
      // are read-only rules ("VDD must be decoupled within 3mm") that tie
      // library parts to validation steps during schematic review.
      var safe = escapeHtml(componentName);
      var dsList = (data && data.datasheets) || [];
      var reqList = (data && data.requirements) || [];
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
      if (reqList.length) {
        html += '<div class="sb-req-title">Requirements</div>' +
          '<ul class="sb-req-list">' + reqList.map(function (r) {
            var t = escapeHtml(r.text);
            if (r.pdf) {
              var hParts = [];
              if (r.page) hParts.push('page=' + encodeURIComponent(r.page));
              if (r.quote) hParts.push('highlight=' + encodeURIComponent(r.quote));
              var href = '/pdf-view/' + encodeURIComponent(r.pdf) + (hParts.length ? '?' + hParts.join('&') : '');
              t += ' <a class="sb-req-ref" href="' + href + '" target="_blank" rel="noopener">📄 ' + escapeHtml(r.pdf) + (r.page ? ' p.' + r.page : '') + '</a>';
            }
            return '<li>' + t + '</li>';
          }).join('') + '</ul>';
      }
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

  // ---- Boot ----
  showSectionList();
})();
