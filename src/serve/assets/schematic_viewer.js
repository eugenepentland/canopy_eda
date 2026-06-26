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
    // Drop any lingering flash from a previous pick so rapid clicks don't stack.
    document.querySelectorAll('.flash').forEach(function (n) { n.classList.remove('flash'); });
    el.classList.add('flash');
    // Long enough to cover the two-pulse CSS animation (.7s × 2).
    setTimeout(function () { el.classList.remove('flash'); }, 1500);
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

  // "+ Add component" bar — only on design pages (module pages can't take a
  // new top-level instance through /api/add-instance).
  function addCompBarHtml() {
    if (typeof SCH_VIEW !== 'undefined' && SCH_VIEW === 'module') return '';
    return '<button type="button" class="sb-add-comp">+ Add component</button>';
  }
  function wireAddCompBar() {
    var b = detailBox.querySelector('.sb-add-comp');
    if (b) b.addEventListener('click', openAddWizard);
    var tt = detailBox.querySelector('.sb-tree-toggle');
    if (tt) tt.addEventListener('click', function () {
      if (tt.getAttribute('data-mode') === 'tree') showTree(); else showSectionList();
    });
  }

  // Structural tree: every section as a collapsible node with its component
  // rows inline (ref · component · value), a one-glance hierarchy. Section
  // headers expand/collapse; component rows open the component detail.
  function showTree() {
    var bySec = {};
    (SCH_INDEX.components || []).forEach(function (c) {
      var k = c.section || '';
      (bySec[k] = bySec[k] || []).push(c);
    });
    var html = addCompBarHtml() + '<span class="sb-tree-toggle" data-mode="list">≣ List view</span>';
    function compRows(list) {
      return list.slice().sort(function (a, b) { return cmpPin(a.ref, b.ref); }).map(function (c) {
        return '<div class="sb-tree-comp" data-ref="' + escapeHtml(c.ref) + '">' +
          '<span class="sb-tree-ref">' + escapeHtml(c.ref) + '</span>' +
          '<span>' + escapeHtml(c.component || '') + '</span>' +
          (c.value ? '<span class="sb-tree-val">' + escapeHtml(c.value) + '</span>' : '') + '</div>';
      }).join('');
    }
    (SCH_INDEX.sections || []).forEach(function (s) {
      var list = bySec[s.slug] || [];
      html += '<details class="sb-tree-sec" open><summary>' + escapeHtml(s.name) +
        ' <span class="muted">(' + list.length + ')</span></summary>' + compRows(list) + '</details>';
    });
    if ((bySec[''] || []).length) {
      html += '<details class="sb-tree-sec" open><summary>(no section) <span class="muted">(' +
        bySec[''].length + ')</span></summary>' + compRows(bySec['']) + '</details>';
    }
    detailBox.innerHTML = html;
    wireAddCompBar();
    detailBox.querySelectorAll('.sb-tree-comp[data-ref]').forEach(function (row) {
      row.addEventListener('click', function () { showComponent(row.getAttribute('data-ref'), true); });
    });
  }

  function showSectionList() {
    var auditHtml = auditListHtml();
    if (!SCH_INDEX.sections || !SCH_INDEX.sections.length) {
      detailBox.innerHTML = auditHtml + addCompBarHtml() + '<div class="sb-empty">No sections.</div>';
      wireAuditClicks();
      wireAddCompBar();
      return;
    }
    var html = auditHtml + addCompBarHtml() +
      '<span class="sb-tree-toggle" data-mode="tree">⊞ Tree view</span><h4>Sections</h4>';
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
    wireAddCompBar();
    detailBox.querySelectorAll('.sb-list-item[data-slug]').forEach(function (el) {
      el.addEventListener('click', function () { showSection(el.dataset.slug, true); });
    });
  }

  // ---- Add-component / add-module wizard ----
  // Modal over /api/add-instance with a live search box across the whole
  // library: pick a component (→ value + section + ref + pin→net map, emitted
  // as an (instance …)) or a module (→ sub-block name + parameter values,
  // emitted as a top-level (sub-block …)). The server auto-assigns ref-des and
  // pushes the rebuild; on success we reload so the new part renders.

  // Parse a defmodule param string ("rfbt rfbb" or "(rfbt 220k) (rfbb 47k)")
  // into [{name, def}] — first token of each (name default) group, or a bare
  // atom with no default.
  function parseModParams(str) {
    var out = [], i = 0, n = (str || '').length;
    while (i < n) {
      while (i < n && /\s/.test(str[i])) i++;
      if (i >= n) break;
      if (str[i] === '(') {
        var depth = 0, start = i;
        for (; i < n; i++) { if (str[i] === '(') depth++; else if (str[i] === ')') { depth--; if (depth === 0) { i++; break; } } }
        var inner = str.slice(start + 1, i - 1).trim();
        var sp = inner.search(/\s/);
        if (sp < 0) out.push({ name: inner, def: '' });
        else out.push({ name: inner.slice(0, sp), def: inner.slice(sp + 1).trim() });
      } else {
        var s = i;
        while (i < n && !/\s/.test(str[i]) && str[i] !== '(') i++;
        out.push({ name: str.slice(s, i), def: '' });
      }
    }
    return out;
  }

  // Turn a plain net <input> into a searchable combobox: a floating filtered
  // list of existing nets drops down on focus/typing; clicking one fills the
  // field, but the input stays freeform so a brand-new net can still be typed.
  // The popup is fixed-positioned and parented to `host` (the modal overlay) so
  // it escapes the body's overflow clipping and is removed when the modal closes.
  // Searchable combobox over a string list. `host` parents the floating
  // popup (use a non-transformed ancestor — the popup is position:fixed so it
  // escapes overflow clipping but stays anchored under the input). Optional
  // `onpick` fires after a list selection so a caller can commit immediately
  // (e.g. the sidebar pin re-wire posts as soon as a net is chosen). Freeform:
  // a value not in the list can still be typed.
  function wireNetCombo(input, nets, host, onpick) {
    input.setAttribute('autocomplete', 'off');
    var pop = document.createElement('div');
    pop.className = 'awz-net-pop';
    pop.style.display = 'none';
    host.appendChild(pop);
    function place() {
      var r = input.getBoundingClientRect();
      pop.style.left = r.left + 'px';
      pop.style.top = (r.bottom + 2) + 'px';
      pop.style.width = Math.max(r.width, 140) + 'px';
    }
    function render() {
      var q = input.value.trim().toLowerCase();
      var hits = nets.filter(function (n) { return !q || n.toLowerCase().indexOf(q) >= 0; });
      if (!hits.length) { pop.style.display = 'none'; return; }
      pop.innerHTML = hits.slice(0, 40).map(function (n) {
        return '<div class="awz-net-opt">' + escapeHtml(n) + '</div>';
      }).join('');
      pop.querySelectorAll('.awz-net-opt').forEach(function (o) {
        o.addEventListener('mousedown', function (e) {
          e.preventDefault();
          input.value = o.textContent;
          pop.style.display = 'none';
          if (onpick) onpick(input.value);
        });
      });
      place();
      pop.style.display = 'block';
    }
    input.addEventListener('focus', render);
    input.addEventListener('input', render);
    input.addEventListener('keydown', function (e) { if (e.key === 'Escape') pop.style.display = 'none'; });
    input.addEventListener('blur', function () { setTimeout(function () { pop.style.display = 'none'; }, 120); });
  }

  function openAddWizard() {
    var ov = document.createElement('div');
    ov.className = 'src-edit-overlay';
    var secOpts = '<option value="">(top level)</option>' +
      (SCH_INDEX.sections || []).map(function (s) {
        return '<option value="' + escapeHtml(s.name) + '">' + escapeHtml(s.name) + '</option>';
      }).join('');
    ov.innerHTML =
      '<div class="src-edit-box add-wiz">' +
        '<div class="src-edit-head"><h3>Add component or module</h3>' +
          '<span class="src-edit-hint">Search the library, then fill in the details</span></div>' +
        '<div class="add-wiz-body">' +
          '<div class="awz-search-wrap">' +
            '<input class="awz-search" placeholder="Search components & modules…" spellcheck="false" autocomplete="off">' +
            '<div class="awz-results"></div>' +
          '</div>' +
          '<div class="awz-detail"></div>' +
        '</div>' +
        '<div class="src-edit-foot">' +
          '<span class="awz-msg src-edit-err"></span>' +
          '<button type="button" class="src-edit-btn awz-cancel">Cancel</button>' +
          '<button type="button" class="src-edit-btn primary awz-add" disabled>Add</button>' +
        '</div>' +
      '</div>';
    document.body.appendChild(ov);
    function close() { if (ov.parentNode) ov.parentNode.removeChild(ov); }
    ov.querySelector('.awz-cancel').addEventListener('click', close);
    ov.addEventListener('mousedown', function (e) { if (e.target === ov) close(); });

    var netNames = (SCH_INDEX.nets || []).map(function (n) { return n.name; });

    var search = ov.querySelector('.awz-search');
    var results = ov.querySelector('.awz-results');
    var detail = ov.querySelector('.awz-detail');
    var addBtn = ov.querySelector('.awz-add');
    var msg = ov.querySelector('.awz-msg');
    var items = [];        // flat [{name, kind, family, params}]
    var selected = null;

    loadLibFull(function (f) {
      items = (f.components || []).map(function (c) { return { name: c.name, kind: 'component', family: !!c.family, footprint: c.footprint || '' }; })
        .concat((f.modules || []).map(function (m) { return { name: m.name, kind: 'module', params: m.params || '', placement: !!m.placement }; }));
      renderResults('');
      search.focus();
    });

    function renderResults(q) {
      q = (q || '').toLowerCase();
      var hits = items.filter(function (it) { return !q || it.name.toLowerCase().indexOf(q) >= 0; });
      hits.sort(function (a, b) { return a.name.localeCompare(b.name); });
      if (!hits.length) { results.innerHTML = '<div class="awz-empty">No matches</div>'; return; }
      results.innerHTML = hits.slice(0, 60).map(function (it) {
        var badge = it.kind === 'module' ? 'module' : (it.family ? 'family' : 'part');
        var hint = it.kind === 'module' && it.params ? '<span class="awz-phint">' + escapeHtml(it.params) + '</span>' : '';
        return '<div class="awz-result" data-name="' + escapeHtml(it.name) + '" data-kind="' + it.kind + '">' +
          '<span class="awz-badge ' + badge + '">' + badge + '</span>' +
          '<span class="awz-rname">' + escapeHtml(it.name) + '</span>' + hint + '</div>';
      }).join('');
      results.querySelectorAll('.awz-result').forEach(function (el) {
        el.addEventListener('click', function () {
          var it = items.filter(function (x) { return x.name === el.dataset.name && x.kind === el.dataset.kind; })[0];
          if (it) selectItem(it, el);
        });
      });
    }
    search.addEventListener('input', function () { renderResults(search.value.trim()); });

    function selectItem(it, el) {
      selected = it;
      results.querySelectorAll('.awz-result').forEach(function (r) { r.classList.remove('sel'); });
      if (el) el.classList.add('sel');
      addBtn.disabled = false;
      msg.textContent = '';
      if (it.kind === 'module') renderModuleDetail(it); else renderComponentDetail(it);
    }

    function renderComponentDetail(it) {
      detail.innerHTML =
        '<div class="awz-pick">Component: <b>' + escapeHtml(it.name) + '</b></div>' +
        (it.footprint ? footprintPreviewHtml(it.footprint) : '') +
        '<div class="awz-row"><label>Value</label>' +
          '<input class="awz-val" placeholder="100nF (optional)" spellcheck="false"></div>' +
        '<div class="awz-row"><label>Section</label><select class="awz-sec">' + secOpts + '</select></div>' +
        '<div class="awz-row"><label>Ref-des</label>' +
          '<input class="awz-ref" placeholder="auto (e.g. C12)" spellcheck="false"></div>' +
        '<div class="awz-pins-head">Pin connections</div>' +
        '<div class="awz-pins"></div>' +
        '<button type="button" class="src-edit-btn awz-add-pin">+ pin</button>';
      if (it.footprint) loadFootprintPreview(detail);
      var pinsBox = detail.querySelector('.awz-pins');
      function addPinRow(pin, net) {
        var row = document.createElement('div');
        row.className = 'awz-pin-row';
        row.innerHTML = '<input class="awz-pin" placeholder="pin#" spellcheck="false">' +
          '<input class="awz-net" placeholder="net" spellcheck="false" autocomplete="off">' +
          '<button type="button" class="awz-pin-del" title="Remove">×</button>';
        row.querySelector('.awz-pin').value = pin || '';
        var netInput = row.querySelector('.awz-net');
        netInput.value = net || '';
        wireNetCombo(netInput, netNames, ov);
        row.querySelector('.awz-pin-del').addEventListener('click', function () { row.remove(); });
        pinsBox.appendChild(row);
      }
      addPinRow('1', ''); addPinRow('2', '');
      detail.querySelector('.awz-add-pin').addEventListener('click', function () { addPinRow('', ''); });
    }

    function renderModuleDetail(it) {
      var params = parseModParams(it.params);
      var rows = params.length ? params.map(function (p) {
        return '<div class="awz-row"><label>' + escapeHtml(p.name) + '</label>' +
          '<input class="awz-param" data-name="' + escapeHtml(p.name) + '" placeholder="' +
          escapeHtml(p.def || '(required)') + '" spellcheck="false"></div>';
      }).join('') :
        '<div class="awz-row"><label>Args</label>' +
          '<input class="awz-args" placeholder="positional or named args (optional)" spellcheck="false"></div>';
      detail.innerHTML =
        '<div class="awz-pick">Module: <b>' + escapeHtml(it.name) + '</b></div>' +
        modLayoutHtml(it) +
        '<div class="awz-row"><label>Name</label>' +
          '<input class="awz-name" value="' + escapeHtml(it.name) + '" spellcheck="false"></div>' +
        '<div class="awz-params-head">Parameters' +
          (params.length ? ' <span class="src-edit-hint">leave blank to use the default</span>' : '') +
          '</div>' + rows;
      if (it.placement) loadModLayout(detail, it.name);
    }

    // A module's premade PCB layout, rendered server-side by /api/pcb-png as a
    // module name (force-solved from its (placement …) spec). Shown only when
    // the module actually has a premade layout; otherwise a short note.
    function modLayoutHtml(it) {
      if (!it.placement) return '<div class="awz-nolayout">No premade PCB layout — it will auto-place when solved.</div>';
      return '<div class="awz-mod-layout" data-mod="' + escapeHtml(it.name) + '">' +
        '<div class="sb-fp-title">Premade layout <span class="muted">' + escapeHtml(it.name) + '</span></div>' +
        '<div class="awz-mod-img"><span class="sb-fp-empty muted">Loading layout…</span></div>' +
        '</div>';
    }
    function loadModLayout(scope, mod) {
      var box = scope.querySelector('.awz-mod-img');
      if (!box) return;
      var img = new Image();
      img.alt = 'PCB layout for ' + mod;
      img.onload = function () { box.innerHTML = ''; box.appendChild(img); };
      img.onerror = function () { box.innerHTML = '<span class="sb-fp-empty muted">No layout preview available.</span>'; };
      img.src = '/api/pcb-png/' + encodeURIComponent(mod) + '?width=460&names=origin';
    }

    addBtn.addEventListener('click', function () {
      if (!selected) { msg.textContent = 'Pick a component or module.'; return; }
      var body;
      if (selected.kind === 'module') {
        var nm = (detail.querySelector('.awz-name').value || '').trim() || selected.name;
        var args = '';
        var paramInputs = detail.querySelectorAll('.awz-param');
        if (paramInputs.length) {
          var parts = [];
          paramInputs.forEach(function (inp) {
            var v = inp.value.trim();
            if (v) parts.push('(' + inp.dataset.name + ' ' + v + ')');
          });
          args = parts.join(' ');
        } else {
          var af = detail.querySelector('.awz-args');
          args = af ? af.value.trim() : '';
        }
        // Every module needs a top-level (import …) to resolve.
        body = { kind: 'module', component: selected.name, name: nm, args: args, import: true };
      } else {
        var pins = {};
        detail.querySelectorAll('.awz-pin-row').forEach(function (r) {
          var p = r.querySelector('.awz-pin').value.trim();
          var n = r.querySelector('.awz-net').value.trim();
          if (p && n) pins[p] = n;
        });
        body = {
          component: selected.name,
          value: detail.querySelector('.awz-val').value.trim(),
          section: detail.querySelector('.awz-sec').value,
          ref: detail.querySelector('.awz-ref').value.trim(),
          pins: pins,
          // Families (cap-0402, …) auto-load; a non-family part (an IC) needs (import …).
          import: !selected.family
        };
      }
      msg.textContent = 'Adding…';
      fetch('/api/add-instance/' + DESIGN_NAME, {
        method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body)
      })
        .then(function (r) { return r.json().then(function (j) { return { ok: r.ok, j: j }; }); })
        .then(function (res) {
          if (!res.ok || !res.j || res.j.ok === false) { msg.textContent = (res.j && res.j.error) || 'add failed'; return; }
          window.location.reload();
        })
        .catch(function (e) { msg.textContent = e.message || 'network error'; });
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
    // Sub-blocks are declared `(sub-block "name" (module …))` in the design
    // file — offer the same "Edit source →" jump components get, landing on that
    // declaration so the user can edit its module/args (the design page only;
    // module pages have no /api/source for themselves).
    var canEditSub = sec.sub && (typeof SCH_VIEW === 'undefined' || SCH_VIEW !== 'module');
    if (canEditSub) {
      html += '<div class="sb-src-edit"><a href="#" data-subedit="' + escapeHtml(sec.name) + '" ' +
        'title="Open the source editor at this sub-block’s declaration">Edit source →</a></div>';
    }
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
    var subEdit = detailBox.querySelector('.sb-src-edit a[data-subedit]');
    if (subEdit) subEdit.addEventListener('click', function (e) {
      e.preventDefault();
      openSourceEditorAtSubBlock(subEdit.getAttribute('data-subedit'));
    });
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

  // Lazily-loaded library index ({components, modules}), fetched once per page
  // from /api/lib-index. `loadInspLib` returns just the components (the
  // inspector's footprint datalist); `loadLibFull` returns the whole index
  // (the add wizard's search box, which lists components AND modules).
  var inspLibComps = null;
  var libFull = null;
  function loadLibFull(cb) {
    if (libFull) { cb(libFull); return; }
    fetch('/api/lib-index').then(function (r) { return r.json(); })
      .then(function (j) {
        libFull = { components: (j && j.components) || [], modules: (j && j.modules) || [] };
        inspLibComps = libFull.components;
        cb(libFull);
      })
      .catch(function () { libFull = { components: [], modules: [] }; inspLibComps = []; cb(libFull); });
  }
  function loadInspLib(cb) { loadLibFull(function (f) { cb(f.components); }); }

  // POST a surgical edit, then act on the result. `reload` true forces a full
  // page reload (the netlist/geometry changed); false just advances the
  // version watermark so our own edit doesn't trigger the 2s poll's reload.
  function postEdit(endpoint, body, reload, onErr) {
    fetch(endpoint + '/' + DESIGN_NAME, {
      method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body)
    })
      // Parse the body tolerantly: error paths may return a plaintext message
      // (not JSON), which a bare r.json() would turn into a cryptic
      // "Unexpected token" instead of the actual error.
      .then(function (r) {
        return r.text().then(function (t) {
          var j = null;
          try { j = t ? JSON.parse(t) : null; } catch (_) { j = { error: t }; }
          return { ok: r.ok, j: j };
        });
      })
      .then(function (res) {
        if (!res.ok || !res.j || res.j.ok === false || res.j.error) {
          onErr((res.j && (res.j.error || res.j.message)) || 'edit failed'); return;
        }
        if (reload) { window.location.reload(); return; }
        if (res.j && typeof res.j.version === 'number') lastVersion = res.j.version;
      })
      .catch(function (e) { onErr(e.message || 'network error'); });
  }

  // Unified detail view for any component — hubs render their pin table,
  // passives render a compact info card with a "show net" jump for each pin.
  function showComponent(ref, doScroll) {
    var c = compByRef[ref];
    if (!c) return;
    if (doScroll) {
      // Hubs (U/J/…) are HTML `.sch-hub` cards; passives are inline
      // `<g class="component">` symbols nested *inside* a hub's SVG. Flash
      // whichever we matched directly — walking up to `.closest('.sch-hub')`
      // would wrongly light up the enclosing IC card instead of the passive.
      var anchor = document.querySelector('.sch-hub[data-ref="' + cssEscape(ref) + '"]')
                || document.querySelector('svg [data-ref="' + cssEscape(ref) + '"].component');
      if (anchor) { scrollTo(anchor); flash(anchor); }
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
    // Source cross-probe: `src` is the byte offset of this instance's defining
    // form in the design file (absent for sub-block parts, whose source lives
    // in a module file the editor can't load — and module pages, where
    // /api/source/:name doesn't resolve).
    var canEditSrc = c.src && (typeof SCH_VIEW === 'undefined' || SCH_VIEW !== 'module');
    if (canEditSrc) {
      html += '<div class="sb-src-edit"><a href="#" ' +
        'title="Open the source editor at this instance’s definition">Edit source →</a></div>';
      // Structured inspector: edit value / footprint / MPN and delete the part
      // without touching the source — each field POSTs a surgical edit. For
      // passives the panel opens by default and the component field reads as
      // "Footprint" (the package-named component family IS the footprint), so a
      // passive's value + package are editable at a glance.
      var isPassive = c.kind === 'passive';
      html += '<details class="sb-inspect"' + (isPassive ? ' open' : '') + '><summary>' +
        (isPassive ? 'Edit value / footprint' : 'Edit component') + '</summary>' +
        '<div class="sb-insp-field"><label>Value</label>' +
          '<input class="sb-insp-val" spellcheck="false" value="' + escapeHtml(c.value || '') + '">' +
          '<button class="sb-insp-btn" data-act="value">Save</button></div>' +
        '<div class="sb-insp-field"><label>' + (isPassive ? 'Footprint' : 'Component') + '</label>' +
          '<input class="sb-insp-comp" spellcheck="false" value="' + escapeHtml(c.component || '') + '">' +
          '<button class="sb-insp-btn" data-act="comp">Apply</button></div>' +
        (isPassive && c.footprint ? '<div class="sb-insp-hint">PCB pad: ' + escapeHtml(c.footprint) + '</div>' : '') +
        '<div class="sb-insp-field"><label>MPN</label>' +
          '<input class="sb-insp-mpn" spellcheck="false" placeholder="manufacturer part #" value="' + escapeHtml(c.mpn || '') + '">' +
          '<button class="sb-insp-btn" data-act="mpn">Save</button></div>' +
        '<div class="sb-insp-msg"></div>' +
        '<button class="sb-insp-del" data-act="delete">Delete component</button>' +
        '</details>';
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
    var srcLink = detailBox.querySelector('.sb-src-edit a');
    if (srcLink) {
      srcLink.addEventListener('click', function (e) {
        e.preventDefault();
        openSourceEditorAtOffset(c.src, ref);
      });
    }
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
    if (canEditSrc) wireInspector(detailBox, ref, c);
  }

  // Wire the structured inspector panel + inline pin re-wiring for an
  // editable (top-level, non-module) instance. Each control POSTs a surgical
  // edit; structural changes reload the page, scalar value/MPN edits don't.
  function wireInspector(box, ref, c) {
    var panel = box.querySelector('.sb-inspect');
    if (!panel) return;
    var msg = panel.querySelector('.sb-insp-msg');
    function showMsg(text, isErr) {
      msg.textContent = text;
      msg.className = 'sb-insp-msg' + (isErr ? ' is-error' : ' is-ok');
    }
    // Net names (for inline pin re-wiring) from the scene graph; the
    // component/footprint field gets a searchable combo from the library index.
    var netNames = (SCH_INDEX.nets || []).map(function (n) { return n.name; });
    var compInput = panel.querySelector('.sb-insp-comp');
    if (compInput) loadInspLib(function (comps) {
      wireNetCombo(compInput, comps.map(function (cc) { return cc.name; }), box);
    });
    panel.querySelectorAll('.sb-insp-btn').forEach(function (btn) {
      btn.addEventListener('click', function () {
        var act = btn.getAttribute('data-act');
        if (act === 'value') {
          postEdit('/api/edit-value', { ref: ref, value: panel.querySelector('.sb-insp-val').value.trim(), srcOff: c.src }, false,
            function (e) { showMsg(e, true); });
          showMsg('Saved value.', false);
        } else if (act === 'mpn') {
          postEdit('/api/edit-mpn', { ref: ref, mpn: panel.querySelector('.sb-insp-mpn').value.trim() }, false,
            function (e) { showMsg(e, true); });
          showMsg('Saved MPN.', false);
        } else if (act === 'comp') {
          var nc = panel.querySelector('.sb-insp-comp').value.trim();
          if (!nc || nc === c.component) { showMsg('Enter a different component.', true); return; }
          showMsg('Applying…', false);
          postEdit('/api/edit-footprint', { ref: ref, component: nc, oldComponent: c.component || '', srcOff: c.src }, true,
            function (e) { showMsg(e, true); });
        }
      });
    });
    var del = panel.querySelector('.sb-insp-del');
    if (del) del.addEventListener('click', function () {
      if (!window.confirm('Delete ' + ref + ' from the design?')) return;
      showMsg('Deleting…', false);
      postEdit('/api/remove-instance', { ref: ref }, true, function (e) { showMsg(e, true); });
    });
    // Inline pin re-wiring: an ✎ button on each pin row swaps the net text for
    // an input (net datalist); Enter/blur POSTs rewire-pin and reloads.
    box.querySelectorAll('.sb-pin-row').forEach(function (row) {
      var pin = row.getAttribute('data-pin');
      var netCell = row.querySelector('.sb-pin-net');
      if (!netCell || !pin) return;
      var edit = document.createElement('button');
      edit.className = 'sb-pin-edit';
      edit.textContent = '✎';
      edit.title = 'Re-wire pin ' + pin;
      edit.addEventListener('click', function (e) {
        e.stopPropagation();
        var inp = document.createElement('input');
        inp.className = 'sb-pin-net-input';
        inp.spellcheck = false;
        inp.value = row.getAttribute('data-net') || '';
        netCell.replaceWith(inp);
        inp.focus(); inp.select();
        var done = false;
        function commit() {
          if (done) return; done = true;
          var nn = inp.value.trim();
          if (!nn || nn === (row.getAttribute('data-net') || '')) { showComponent(ref, false); return; }
          postEdit('/api/rewire-pin', { ref: ref, pin: pin, net: nn, srcOff: c.src }, true, function (er) { alert('Re-wire failed: ' + er); showComponent(ref, false); });
        }
        // Searchable net dropdown; picking a net commits immediately.
        wireNetCombo(inp, netNames, box, function () { commit(); });
        inp.addEventListener('keydown', function (ev) {
          if (ev.key === 'Enter') { ev.preventDefault(); commit(); }
          else if (ev.key === 'Escape') { done = true; showComponent(ref, false); }
        });
        inp.addEventListener('blur', commit);
      });
      row.appendChild(edit);
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
  // Clicking Push first POSTs the sync with ?dry_run=1, shows the would-be op
  // list + summary counts in a preview modal, and only on Confirm POSTs the
  // real (writing) sync. The result — applied-op counts, lock-file warning, or
  // the server's error body (e.g. "design has no (kicad-pcb …) form") — lands
  // in a toast.
  var pushPcbBtn = document.getElementById('push-kicad-pcb-btn');

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

  // Which schematic section / sub-circuit an op belongs to, for grouping the
  // preview. Adds carry `canopy_section`; sub-block parts have a "<sub>/<ref>"
  // ref we split on; bare top-level refs fall under "Main board".
  function kicadSectionOf(op) {
    if (op.canopy_section) return op.canopy_section;
    var r = op.ref || '';
    var i = r.indexOf('/');
    if (i >= 0) return r.slice(0, i);
    return 'Main board';
  }

  // Op list for the preview modal, GROUPED BY SCHEMATIC SECTION so the user
  // reads the change set sub-circuit by sub-circuit. Each section heading lists
  // its board-shape changes — parts added/removed, footprint/3D re-bakes, value
  // edits, stale flags. Pure metadata (refdes renames + canopy_*/MPN/etc field
  // writes) never moves a part, so it's hidden behind a one-line count instead
  // of cluttering the list. Pad-net rewires, stitching vias and staging boxes
  // collapse into a single muted "housekeeping" summary.
  function buildKicadOpsHtml(ops) {
    var esc = escapeHtml;
    function refOf(op) { return esc(op.ref || op.uuid || '?'); }
    // Swap rows stay clickable: the inline old-vs-new footprint compare expands
    // under the row (board copy via /api/board-footprint, library /api/footprint).
    function swapAttrs(op) {
      return ' data-cmp-uuid="' + esc(op.uuid || '') + '" data-cmp-fp="' + esc(op.new_footprint_name || '') + '"' +
        ' title="Click to compare old vs new footprint"';
    }
    // Render one meaningful op as a kind-badged row.
    function opRow(op) {
      var kind, body, attrs = '', cls = '';
      if (op.op === 'add') {
        kind = 'add';
        body = refOf(op) + (op.footprint_name ? ' · ' + esc(op.footprint_name) : '') +
          (op.value ? ' · = ' + esc(op.value) : '');
      } else if (op.op === 'remove') {
        kind = 'remove'; body = refOf(op) + ' <span class="kpv-cat-hint">removed from board</span>';
      } else if (op.op === 'flag_stale') {
        kind = 'stale'; body = refOf(op) + ' <span class="kpv-cat-hint">on board, not in design — flagged</span>';
      } else if (op.op === 'swap_footprint') {
        kind = (op.reason === 'model') ? 'model' : 'fp';
        body = refOf(op) + (op.new_footprint_name ? ' · ' + esc(op.new_footprint_name) : '') +
          '<span class="kpv-cmp-link">compare ▾</span>';
        attrs = swapAttrs(op); cls = ' kpv-clickable';
      } else if (op.op === 'set_field' && op.field === 'value') {
        kind = 'value';
        body = refOf(op) + ' · ' + (op.old ? esc(op.old) + ' → ' : '') + esc(op.value || '');
      } else {
        kind = 'op'; body = esc(kicadOpLabel(op));
      }
      return '<div class="kpv-op' + cls + '"' + attrs + '>' +
        '<span class="op-kind k-' + kind + '">' + kind + '</span>' + body + '</div>';
    }
    // Partition: meaningful board-shape ops (grouped by section) vs. hidden
    // metadata vs. housekeeping (pad-nets / vias / staging graphics).
    var meaningful = [], padnets = 0, vias = 0, gfx = 0, hiddenMeta = 0;
    ops.forEach(function (op) {
      if (op.op === 'set_field') {
        if (op.field === 'value') meaningful.push(op); else hiddenMeta++;
      } else if (op.op === 'set_pad_net') padnets++;
      else if (op.op === 'add_via') vias++;
      else if (op.op === 'create_board_item') gfx++;
      else meaningful.push(op);    // add / remove / swap_footprint / flag_stale / unknown
    });
    var html = '';
    // Group meaningful ops by section in first-appearance order.
    var order = [], bySec = {};
    meaningful.forEach(function (op) {
      var s = kicadSectionOf(op);
      if (!bySec[s]) { bySec[s] = []; order.push(s); }
      bySec[s].push(op);
    });
    order.forEach(function (s) {
      var list = bySec[s];
      html += '<div class="kpv-sec"><span class="kpv-sec-title">' + esc(s) + '</span>' +
        '<span class="kpv-sec-count">' + list.length + ' change' + (list.length === 1 ? '' : 's') + '</span></div>' +
        list.map(opRow).join('');
    });
    // Housekeeping + hidden-metadata summary lines (muted, never a part move).
    var house = [];
    if (padnets) house.push(padnets + ' pad-net assignment' + (padnets === 1 ? '' : 's'));
    if (vias) house.push(vias + ' stitching via' + (vias === 1 ? '' : 's'));
    if (gfx) house.push(gfx + ' staging box' + (gfx === 1 ? '' : 'es'));
    if (house.length) html += '<div class="kpv-house">+ ' + house.join(', ') +
      ' — routing &amp; staging, applied automatically</div>';
    if (hiddenMeta) html += '<div class="kpv-house">' + hiddenMeta +
      ' refdes / field metadata change' + (hiddenMeta === 1 ? '' : 's') +
      ' hidden — labels &amp; BOM fields only, nothing moves</div>';
    if (!html) html = '<div class="kpv-empty">No board changes.</div>';
    return html;
  }

  function kicadSummaryChips(s) {
    var keys = ['updated', 'relabeled', 'added', 'removed', 'swapped', 'flagged_stale', 'suppressed', 'vias'];
    return keys.map(function (k) {
      var n = (s && s[k]) || 0;
      return '<span class="kpv-chip' + (n > 0 ? ' hot' : '') + '">' + n + ' ' + k.replace('_', ' ') + '</span>';
    }).join('');
  }

  // Build + show the dry-run preview modal. confirm() runs the real push.
  // Build the "seed sub-circuits from saved layout" checkbox block from the
  // dry-run's sub_circuits[]. Each entry the saved layout can place gets a
  // checkbox (default OFF — a plain Confirm reproduces today's staging-grid
  // behavior exactly); checked sub-circuits reproduce the saved layout —
  // anchored on their IC when it is already on the board, else placed together
  // in one off-board box (shared offset → full geometry preserved) as one group.
  function buildSeedSectionHtml(subs) {
    if (!subs || !subs.length) return '';
    var rows = subs.map(function (s, i) {
      var where = s.on_board && s.anchor
        ? 'around ' + escapeHtml(leafRef(s.anchor)) + ' (already on board)'
        : 'off-board, in the shared layout box';
      return '<label class="kpv-seed-row">' +
        '<input type="checkbox" class="kpv-seed-cb" data-name="' + escapeAttr(s.name) + '">' +
        '<span class="kpv-seed-name">' + escapeHtml(s.name) + '</span>' +
        '<span class="kpv-seed-hint">' + s.parts + ' part' + (s.parts === 1 ? '' : 's') + ' · ' + where + '</span>' +
        '</label>';
    }).join('');
    return '<div class="kpv-seed">' +
      '<div class="kpv-seed-head">' +
        '<span>Seed sub-circuit layout from saved PCB layout</span>' +
        '<span class="kpv-seed-actions">' +
          '<button type="button" class="kpv-seed-all">All</button>' +
          '<button type="button" class="kpv-seed-none">None</button>' +
        '</span>' +
      '</div>' +
      '<div class="kpv-seed-note">Checked sub-circuits reproduce the saved PCB layout. Any whose IC is already on the board flow in around it; the rest are placed together in one labelled box just off the board — keeping their exact saved positions relative to each other — as a single draggable KiCad group. Unchecked parts go to the staging grid as before.</div>' +
      rows +
      '</div>';
  }
  // Last path segment of a possibly sub-block-prefixed ref ("mcu/U12" → "U12").
  function leafRef(r) { var i = r.lastIndexOf('/'); return i >= 0 ? r.slice(i + 1) : r; }
  function escapeAttr(s) { return escapeHtml(s).replace(/"/g, '&quot;'); }

  function showKicadPreview(title, dryJson, onConfirm) {
    var ops = (dryJson && dryJson.ops) || [];
    var subs = (dryJson && dryJson.sub_circuits) || [];
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
        buildSeedSectionHtml(subs) +
        '<div class="kpv-ops">' + opsHtml + '</div>' +
        '<div class="kpv-foot">' +
          '<button class="kpv-btn kpv-cancel">Cancel</button>' +
          '<button class="kpv-btn primary kpv-confirm">Confirm — write board</button>' +
        '</div>' +
      '</div>';
    document.body.appendChild(overlay);
    // Seed checkbox All/None helpers.
    var seedBox = overlay.querySelector('.kpv-seed');
    if (seedBox) {
      var setAll = function (on) {
        var cbs = seedBox.querySelectorAll('.kpv-seed-cb');
        for (var i = 0; i < cbs.length; i++) cbs[i].checked = on;
      };
      seedBox.querySelector('.kpv-seed-all').addEventListener('click', function () { setAll(true); });
      seedBox.querySelector('.kpv-seed-none').addEventListener('click', function () { setAll(false); });
    }
    // Swap rows expand an inline old-vs-new footprint comparison.
    overlay.querySelector('.kpv-ops').addEventListener('click', function (e) {
      var row = e.target.closest ? e.target.closest('.kpv-clickable') : null;
      if (row) toggleFootprintCompare(row);
    });
    function close() { if (overlay.parentNode) overlay.parentNode.removeChild(overlay); }
    overlay.addEventListener('mousedown', function (e) { if (e.target === overlay) close(); });
    overlay.querySelector('.kpv-x').addEventListener('click', close);
    overlay.querySelector('.kpv-cancel').addEventListener('click', close);
    var confirmBtn = overlay.querySelector('.kpv-confirm');
    confirmBtn.addEventListener('click', function () {
      confirmBtn.disabled = true;
      confirmBtn.textContent = 'Writing…';
      // Collect the checked sub-circuits so the real write seeds their layout.
      var seed = [];
      var cbs = overlay.querySelectorAll('.kpv-seed-cb');
      for (var i = 0; i < cbs.length; i++) {
        if (cbs[i].checked) seed.push(cbs[i].dataset.name);
      }
      onConfirm(close, function () {
        confirmBtn.disabled = false;
        confirmBtn.textContent = 'Confirm — write board';
      }, seed);
    });
  }

  // Fetch a footprint-preview JSON and draw it into `target` (shared FP
  // renderer — same engine as the sidebar/library previews).
  function fetchFpPreviewInto(target, url) {
    fetch(url).then(function (r) {
      if (!r.ok) return r.text().then(function (t) { throw new Error(t || 'no preview'); });
      return r.json();
    }).then(function (data) {
      var s = FP.el('svg', {});
      FP.drawFootprint(s, data);
      s.style.width = '100%'; s.style.height = 'auto'; s.style.maxHeight = '180px'; s.style.display = 'block'; s.style.borderRadius = '4px';
      target.innerHTML = '';
      target.appendChild(s);
    }).catch(function (e) {
      target.textContent = (e && e.message) ? e.message : 'preview unavailable';
    });
  }

  // Toggle the inline old-vs-new footprint comparison under a swap row.
  // OLD = the footprint as it exists on the board right now (by KiCad uuid);
  // NEW = the library footprint the sync would re-bake it to. Both render
  // through the same engine in footprint-local mm, so shapes compare 1:1.
  function toggleFootprintCompare(row) {
    var next = row.nextElementSibling;
    if (next && next.classList.contains('kpv-cmp-panel')) { next.remove(); return; }
    var panel = document.createElement('div');
    panel.className = 'kpv-cmp-panel';
    panel.innerHTML =
      '<div class="kpv-cmp-col"><div class="kpv-cmp-cap">On board now</div><div class="kpv-cmp-svg">Loading…</div></div>' +
      '<div class="kpv-cmp-col"><div class="kpv-cmp-cap">After sync (library)</div><div class="kpv-cmp-svg">Loading…</div></div>';
    row.parentNode.insertBefore(panel, row.nextSibling);
    var cols = panel.querySelectorAll('.kpv-cmp-svg');
    fetchFpPreviewInto(cols[0], '/api/board-footprint/' + encodeURIComponent(DESIGN_NAME) + '?uuid=' + encodeURIComponent(row.dataset.cmpUuid || ''));
    fetchFpPreviewInto(cols[1], '/api/footprint/' + encodeURIComponent(row.dataset.cmpFp || ''));
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
        showKicadPreview(title, dry, function (closeModal, resetConfirm, seed) {
          var opts = { method: 'POST' };
          if (seed && seed.length) {
            opts.headers = { 'Content-Type': 'application/json' };
            opts.body = JSON.stringify({ seed: seed });
          }
          fetch(realUrl, opts).then(function (r) {
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
            if (typeof refreshKicadSyncChip === 'function') refreshKicadSyncChip();
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

  // The single Push button runs the full sync — prune stale footprints +
  // refresh footprint geometry (prune=1&refresh=1) — through the dry-run
  // preview modal so every change is shown and confirmed before the board is
  // written. Results land in a toast (see wireKicadPreviewButton).
  wireKicadPreviewButton(pushPcbBtn, 'Push to KiCad PCB', 'prune=1&refresh=1', 'Previewing…');

  // ---- KiCad PCB sync-freshness chip ----
  // For designs that declare a (kicad-pcb …) target the header carries a
  // #kicad-sync-chip. On load (and on click to re-check, and after a Push) we
  // dry-run the file-based sync and reflect the result: green when the board
  // already matches the netlist, amber + a pending-change count when a Push
  // would write the .kicad_pcb, grey when the board file can't be read. The
  // count excludes `suppressed` (already-applied no-ops) so it tracks exactly
  // what a Push would change.
  var kicadSyncChip = document.getElementById('kicad-sync-chip');
  function setSyncChip(state, text, title) {
    if (!kicadSyncChip) return;
    kicadSyncChip.className = 'head-link head-btn sync-chip ' + state;
    kicadSyncChip.textContent = text;
    kicadSyncChip.title = title;
  }
  function refreshKicadSyncChip() {
    if (!kicadSyncChip || kicadSyncChip.dataset.busy === '1') return;
    kicadSyncChip.dataset.busy = '1';
    setSyncChip('sync-checking', '⟳ PCB sync…', 'Checking whether the .kicad_pcb matches the design…');
    fetch('/api/sync-kicad-pcb/' + DESIGN_NAME + '?dry_run=1', { method: 'POST' }).then(function (r) {
      return r.text().then(function (body) { return { ok: r.ok, body: body }; });
    }).then(function (resp) {
      kicadSyncChip.dataset.busy = '';
      if (!resp.ok) {
        setSyncChip('sync-unknown', '⚠ PCB unreachable', resp.body || 'Could not read the .kicad_pcb board.');
        return;
      }
      var j = {};
      try { j = JSON.parse(resp.body); } catch (_e) {}
      var s = (j && j.summary) || {};
      var pending = (s.added || 0) + (s.removed || 0) + (s.updated || 0) + (s.swapped || 0) + (s.vias || 0);
      var stale = s.flagged_stale || 0;
      var relabeled = s.relabeled || 0;
      // Headline count = material/structural changes only. Refdes renames and
      // canopy_*/BOM-field stamps (`relabeled`) don't move anything, so they're
      // a calm secondary note rather than inflating the "needs sync (N)" number.
      var total = pending + stale;
      if (total === 0 && relabeled === 0) {
        setSyncChip('sync-ok', '✓ PCB in sync', 'The .kicad_pcb matches the design netlist. Click to re-check.');
        return;
      }
      var parts = [];
      if (s.added) parts.push(s.added + ' added');
      if (s.removed) parts.push(s.removed + ' removed');
      if (s.updated) parts.push(s.updated + ' updated');
      if (s.swapped) parts.push(s.swapped + ' footprint swap' + (s.swapped > 1 ? 's' : ''));
      if (s.vias) parts.push(s.vias + ' vias');
      if (stale) parts.push(stale + ' stale on board');
      if (relabeled) parts.push(relabeled + ' relabeled');
      if (total === 0) {
        // Only refdes/field relabels pending — nothing moves, so stay calm.
        setSyncChip('sync-ok', '✓ PCB in sync · ' + relabeled + ' relabel' + (relabeled === 1 ? '' : 's'),
          'Pending: ' + parts.join(', ') + ' (labels & BOM fields only, nothing moves). Open KiCad ▾ → Push to KiCad PCB. Click to re-check.');
        return;
      }
      setSyncChip('sync-stale', '⚠ PCB needs sync (' + total + ')',
        'Pending: ' + parts.join(', ') + '. Open KiCad ▾ → Push to KiCad PCB. Click to re-check.');
    }).catch(function (e) {
      kicadSyncChip.dataset.busy = '';
      setSyncChip('sync-unknown', '⚠ PCB unreachable', 'Sync check failed: ' + e);
    });
  }
  if (kicadSyncChip) {
    kicadSyncChip.addEventListener('click', refreshKicadSyncChip);
    refreshKicadSyncChip();
  }

  // ---- Export SRC ----
  // Fetches the raw .sexp source via /api/source/:name and saves it as a
  // <design>.sexp file download (Blob + a temporary <a download>).
  var copySrcBtn = document.getElementById('copy-src-btn');
  if (copySrcBtn) {
    copySrcBtn.addEventListener('click', function () {
      if (copySrcBtn.dataset.busy === '1') return;
      copySrcBtn.dataset.busy = '1';
      var original = copySrcBtn.textContent;
      copySrcBtn.textContent = 'Exporting…';
      fetch('/api/source/' + DESIGN_NAME).then(function (r) {
        if (!r.ok) throw new Error('fetch failed: ' + r.status);
        return r.json();
      }).then(function (j) {
        var src = (j && typeof j.source === 'string') ? j.source : '';
        if (!src) throw new Error('empty source');
        downloadText(DESIGN_NAME + '.sexp', src);
        copySrcBtn.textContent = '✓ Exported';
        setTimeout(function () {
          copySrcBtn.textContent = original;
          copySrcBtn.dataset.busy = '';
        }, 1200);
      }).catch(function (e) {
        copySrcBtn.textContent = original;
        copySrcBtn.dataset.busy = '';
        alert('Export failed: ' + e);
      });
    });
  }

  // Trigger a browser download of `text` as `filename` via a transient
  // object-URL anchor (revoked once the click is dispatched).
  function downloadText(filename, text) {
    var blob = new Blob([text], { type: 'application/octet-stream' });
    var url = URL.createObjectURL(blob);
    var a = document.createElement('a');
    a.href = url;
    a.download = filename;
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
    setTimeout(function () { URL.revokeObjectURL(url); }, 0);
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
          '<span class="src-edit-hint">⌘/Ctrl-S save · ⌘/Ctrl-F find · ⌘/Ctrl-Space complete · live-checked as you type</span></div>' +
        '<div class="src-edit-tools">' +
          '<span class="src-tools-label">Insert:</span>' +
          '<button type="button" class="src-edit-btn src-snip" data-snip="section">section</button>' +
          '<button type="button" class="src-edit-btn src-snip" data-snip="instance">instance</button>' +
          '<button type="button" class="src-edit-btn src-snip" data-snip="subblock">sub-block</button>' +
          '<button type="button" class="src-edit-btn src-snip" data-snip="net">net</button>' +
          '<button type="button" class="src-edit-btn src-snip" data-snip="decouple">decouple</button>' +
          '<button type="button" class="src-edit-btn src-edit-outline" title="Toggle component outline">Outline</button>' +
          '<span class="src-tools-gap"></span>' +
          '<button type="button" class="src-edit-btn src-edit-format" title="Re-indent by paren depth (comments preserved)">Tidy indent</button>' +
        '</div>' +
        '<div class="src-edit-find" hidden>' +
          '<input type="text" class="src-find-input" placeholder="Find…" spellcheck="false">' +
          '<span class="src-find-count"></span>' +
          '<button type="button" class="src-edit-btn src-find-prev" title="Previous match (Shift-Enter)">↑</button>' +
          '<button type="button" class="src-edit-btn src-find-next" title="Next match (Enter)">↓</button>' +
          '<button type="button" class="src-edit-btn src-find-close" title="Close (Esc)">×</button>' +
        '</div>' +
        '<div class="src-split-wrap">' +
          '<div class="src-edit-cm"></div>' +
          '<div class="src-split-panel" hidden>' +
            '<div class="src-split-head">Components</div>' +
            '<div class="src-split-list"></div>' +
          '</div>' +
        '</div>' +
        '<div class="src-edit-problems" hidden></div>' +
        '<div class="src-edit-foot">' +
          '<span class="src-edit-status src-status-ok" title="Click to list problems">checking…</span>' +
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
      tabSize: 2,
      gutters: ['CodeMirror-linenumbers', 'eda-diag-gutter']
    });

    var state = {
      overlay: overlay,
      cm: cm,
      errEl: overlay.querySelector('.src-edit-err'),
      secEl: overlay.querySelector('.src-edit-sec'),
      saveBtn: overlay.querySelector('.src-edit-save'),
      statusEl: overlay.querySelector('.src-edit-status'),
      problemsEl: overlay.querySelector('.src-edit-problems'),
      loaded: false,
      loadPromise: null,
      diagMarks: [],
      diagLineClasses: []
    };

    function close() {
      if (overlay.parentNode) overlay.parentNode.removeChild(overlay);
      srcEditor = null;
    }
    overlay.querySelector('.src-edit-cancel').addEventListener('click', close);
    overlay.addEventListener('mousedown', function (e) { if (e.target === overlay) close(); });

    // ---- Find bar (⌘/Ctrl-F) ----
    // Self-contained search over the document: the vendored CodeMirror bundle
    // is core-only (no search/dialog addons), so matches are found with a
    // case-insensitive literal regex on the raw string and highlighted via
    // markText. Enter/Shift-Enter cycle, Esc closes back into the editor.
    var findBar = overlay.querySelector('.src-edit-find');
    var findInput = overlay.querySelector('.src-find-input');
    var findCount = overlay.querySelector('.src-find-count');
    var findMatches = []; // [{start,len}] string indices into cm.getValue()
    var findCur = -1;
    var findMarks = [];
    var findTimer = null;

    function clearFindMarks() {
      findMarks.forEach(function (m) { m.clear(); });
      findMarks = [];
    }
    function showFindMatch() {
      if (findCur < 0 || findCur >= findMatches.length) return;
      var m = findMatches[findCur];
      var from = cm.posFromIndex(m.start);
      var to = cm.posFromIndex(m.start + m.len);
      cm.setSelection(from, to);
      cm.scrollIntoView({ from: from, to: to }, 80);
      findCount.textContent = (findCur + 1) + '/' + findMatches.length;
    }
    function runFind() {
      clearFindMarks();
      findMatches = [];
      findCur = -1;
      var q = findInput.value;
      if (!q) { findCount.textContent = ''; return; }
      var doc = cm.getValue();
      var re = new RegExp(q.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), 'gi');
      var m;
      while ((m = re.exec(doc)) !== null) {
        findMatches.push({ start: m.index, len: m[0].length });
      }
      if (!findMatches.length) { findCount.textContent = '0 results'; return; }
      // Highlight-all is capped so a one-letter query on a big file doesn't
      // mint thousands of marks; the counter still reports the full total.
      var cap = Math.min(findMatches.length, 500);
      for (var k = 0; k < cap; k++) {
        findMarks.push(cm.markText(
          cm.posFromIndex(findMatches[k].start),
          cm.posFromIndex(findMatches[k].start + findMatches[k].len),
          { className: 'cm-find-match' }
        ));
      }
      // Start from the first match at/after the cursor so opening the bar
      // near your edit point lands nearby instead of at the file top.
      var cursorIdx = cm.indexFromPos(cm.getCursor('from'));
      findCur = 0;
      for (var j = 0; j < findMatches.length; j++) {
        if (findMatches[j].start >= cursorIdx) { findCur = j; break; }
      }
      showFindMatch();
    }
    function stepFind(dir) {
      if (!findMatches.length) return;
      findCur = (findCur + dir + findMatches.length) % findMatches.length;
      showFindMatch();
    }
    function openFind() {
      findBar.hidden = false;
      if (cm.somethingSelected()) {
        var sel = cm.getSelection();
        if (sel.length <= 200 && sel.indexOf('\n') < 0) findInput.value = sel;
      }
      findInput.focus();
      findInput.select();
      runFind();
    }
    function closeFind() {
      findBar.hidden = true;
      clearFindMarks();
      findCount.textContent = '';
      cm.focus();
    }
    findInput.addEventListener('input', function () {
      if (findTimer) clearTimeout(findTimer);
      findTimer = setTimeout(runFind, 120);
    });
    findInput.addEventListener('keydown', function (e) {
      if (e.key === 'Enter') { e.preventDefault(); stepFind(e.shiftKey ? -1 : 1); }
      else if (e.key === 'Escape') { e.preventDefault(); closeFind(); }
    });
    overlay.querySelector('.src-find-prev').addEventListener('click', function () { stepFind(-1); });
    overlay.querySelector('.src-find-next').addEventListener('click', function () { stepFind(1); });
    overlay.querySelector('.src-find-close').addEventListener('click', closeFind);
    // Edits shift every offset — re-run the search while the bar is open.
    cm.on('change', function () {
      if (findBar.hidden) return;
      if (findTimer) clearTimeout(findTimer);
      findTimer = setTimeout(runFind, 200);
    });
    // One bubble-phase handler covers the whole modal (editor, buttons, find
    // input itself): preventDefault stops the browser's native page find.
    overlay.addEventListener('keydown', function (e) {
      if ((e.ctrlKey || e.metaKey) && !e.altKey && (e.key === 'f' || e.key === 'F')) {
        e.preventDefault();
        openFind();
      }
    });

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
    cm.setOption('extraKeys', {
      'Cmd-S': save,
      'Ctrl-S': save,
      'Ctrl-Space': function () { openAC(); },
      'Cmd-Space': function () { openAC(); },
      'Esc': function () {
        if (!findBar.hidden) closeFind(); else return CodeMirror.Pass;
      }
    });

    state.loadPromise = fetch('/api/source/' + DESIGN_NAME)
      .then(function (r) { return r.json(); })
      .then(function (j) {
        cm.setValue(typeof j.source === 'string' ? j.source : '');
        state.loaded = true;
        setTimeout(function () { cm.refresh(); }, 0);
      })
      .catch(function (e) { state.errEl.textContent = 'Load failed: ' + e.message; });

    // ---- Live diagnostics ----
    // Debounced POST to /api/validate (read-only dry eval): parse/eval errors,
    // lint warnings, and failed assertions come back with 1-based spans. We
    // paint located ones as gutter markers + line tints + underlines (native
    // title tooltips), and list everything in a togglable problems panel.
    function clearDiagnostics() {
      state.diagMarks.forEach(function (m) { m.clear(); });
      state.diagMarks = [];
      state.diagLineClasses.forEach(function (ln) {
        cm.removeLineClass(ln, 'wrap', 'cm-diag-error-line');
        cm.removeLineClass(ln, 'wrap', 'cm-diag-warn-line');
      });
      state.diagLineClasses = [];
      cm.clearGutter('eda-diag-gutter');
    }
    function applyDiagnostics(diags) {
      clearDiagnostics();
      var nE = 0, nW = 0;
      diags.forEach(function (d) { if (d.severity === 'error') nE++; else nW++; });
      var byLine = {};
      diags.forEach(function (d) {
        if (!d.line || d.line < 1 || d.line > cm.lineCount()) return;
        var ln = d.line - 1;
        (byLine[ln] = byLine[ln] || []).push(d);
      });
      Object.keys(byLine).forEach(function (lnStr) {
        var ln = +lnStr, ds = byLine[ln];
        var isErr = ds.some(function (d) { return d.severity === 'error'; });
        cm.addLineClass(ln, 'wrap', isErr ? 'cm-diag-error-line' : 'cm-diag-warn-line');
        state.diagLineClasses.push(ln);
        var lineTxt = cm.getLine(ln) || '';
        ds.forEach(function (d) {
          var ch0 = Math.max(0, (d.col || 1) - 1);
          var to = lineTxt.length;
          if (ch0 >= to) ch0 = Math.max(0, to - 1);
          state.diagMarks.push(cm.markText(
            { line: ln, ch: ch0 }, { line: ln, ch: to },
            { className: isErr ? 'cm-diag-underline-error' : 'cm-diag-underline-warn', title: d.message }
          ));
        });
        var dot = document.createElement('span');
        dot.className = 'cm-diag-dot ' + (isErr ? 'is-error' : 'is-warn');
        dot.textContent = isErr ? '●' : '▲';
        dot.title = ds.map(function (d) { return d.message; }).join('\n');
        dot.addEventListener('click', function () { cm.setCursor({ line: ln, ch: 0 }); cm.focus(); });
        cm.setGutterMarker(ln, 'eda-diag-gutter', dot);
      });
      var s = state.statusEl;
      s.className = 'src-edit-status';
      if (nE > 0) { s.classList.add('src-status-err'); s.textContent = '✕ ' + nE + ' error' + (nE > 1 ? 's' : '') + (nW ? ' · ' + nW + ' warning' + (nW > 1 ? 's' : '') : ''); }
      else if (nW > 0) { s.classList.add('src-status-warn'); s.textContent = '▲ ' + nW + ' warning' + (nW > 1 ? 's' : ''); }
      else { s.classList.add('src-status-ok'); s.textContent = '✓ no problems'; }
      renderProblems(diags);
    }
    function renderProblems(diags) {
      var p = state.problemsEl;
      p.textContent = '';
      if (!diags.length) { p.hidden = true; return; }
      diags.forEach(function (d) {
        var row = document.createElement('div');
        row.className = 'src-prob src-prob-' + d.severity;
        row.setAttribute('data-line', d.line || 0);
        var loc = document.createElement('span');
        loc.className = 'src-prob-loc';
        loc.textContent = d.line > 0 ? ('L' + d.line) : '•';
        var msg = document.createElement('span');
        msg.className = 'src-prob-msg';
        msg.textContent = d.message;
        row.appendChild(loc); row.appendChild(msg);
        var fix = quickFixFor(d);
        if (fix) {
          var fb = document.createElement('button');
          fb.className = 'src-prob-fix';
          fb.textContent = fix.label;
          fb.addEventListener('click', function (e) { e.stopPropagation(); fix.apply(); });
          row.appendChild(fb);
        }
        p.appendChild(row);
      });
    }
    // Offer a one-click fix for the two commonest footguns: an unbound name
    // that's actually a library part (→ add to the import form) or an unquoted
    // net (→ wrap it in quotes at the diagnostic's span).
    function quickFixFor(d) {
      if (d.severity !== 'error') return null;
      // (a) The evaluator already identified an un-imported library part.
      var lib = /'([^']+)' is in the library/.exec(d.message);
      if (lib) return { label: '+ import ' + lib[1], apply: function () { addImportFix(lib[1]); } };
      // (b) Generic unknown/unbound name → import if we recognise it, else a
      // likely-unquoted net to wrap in quotes.
      var m = /unknown name '([^']+)'/.exec(d.message) || /[Uu]nbound (?:variable|name) '?([A-Za-z0-9_+\-.\/~]+)'?/.exec(d.message);
      if (!m) return null;
      var name = m[1];
      var comps = (state.libIndex && state.libIndex.components) || [];
      var mods = (state.libIndex && state.libIndex.modules) || [];
      var isLib = comps.some(function (c) { return c.name === name; }) || mods.some(function (mm) { return mm.name === name; });
      if (isLib) return { label: '+ import ' + name, apply: function () { addImportFix(name); } };
      if (d.line > 0 && /^[A-Za-z0-9_+\-.\/~]+$/.test(name)) return { label: 'Quote "' + name + '"', apply: function () { quoteTokenFix(d, name); } };
      return null;
    }
    function addImportFix(name) {
      var doc = cm.getValue();
      var imp = doc.indexOf('(import');
      if (imp >= 0) {
        var close = matchParenIndex(doc, imp);
        if (close > imp) {
          var pos = cm.posFromIndex(close);
          cm.replaceRange(' ' + name, pos, pos);
        }
      } else {
        cm.replaceRange('(import ' + name + ')\n', { line: 0, ch: 0 });
      }
      scheduleValidate();
    }
    function quoteTokenFix(d, name) {
      var from = { line: d.line - 1, ch: Math.max(0, d.col - 1) };
      var line = cm.getLine(from.line) || '';
      // Only wrap when the token at the span really is the bare name.
      if (line.substr(from.ch, name.length) !== name) { scheduleValidate(); return; }
      var to = { line: from.line, ch: from.ch + name.length };
      cm.replaceRange('"' + name + '"', from, to);
      scheduleValidate();
    }
    // Index of the ')' matching the '(' at openIdx, respecting strings and
    // ; comments. Returns -1 if unbalanced.
    function matchParenIndex(doc, openIdx) {
      var depth = 0, inStr = false;
      for (var i = openIdx; i < doc.length; i++) {
        var c = doc[i];
        if (inStr) { if (c === '\\') { i++; continue; } if (c === '"') inStr = false; continue; }
        if (c === '"') { inStr = true; continue; }
        if (c === ';') { while (i < doc.length && doc[i] !== '\n') i++; continue; }
        if (c === '(') depth++;
        else if (c === ')') { depth--; if (depth === 0) return i; }
      }
      return -1;
    }
    var valTimer = null;
    function scheduleValidate() { if (valTimer) clearTimeout(valTimer); valTimer = setTimeout(runValidate, 400); }
    function runValidate() {
      if (!state.loaded) return;
      libReady(); // so quick-fixes can distinguish a library part from a net
      fetch('/api/validate/' + DESIGN_NAME, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ source: cm.getValue() })
      })
        .then(function (r) { return r.json(); })
        .then(function (j) { applyDiagnostics((j && j.diagnostics) || []); })
        .catch(function () { /* keep last good diagnostics */ });
    }
    cm.on('change', scheduleValidate);
    state.problemsEl.addEventListener('click', function (e) {
      var r = e.target.closest ? e.target.closest('.src-prob') : null;
      if (!r) return;
      var ln = +r.getAttribute('data-line');
      if (ln > 0) revealEditorLine(state, ln - 1);
    });
    state.statusEl.addEventListener('click', function () {
      if (state.problemsEl.childNodes.length) state.problemsEl.hidden = !state.problemsEl.hidden;
    });
    // Kick a first validation once the file lands.
    state.loadPromise && state.loadPromise.then(function () { runValidate(); });

    // ---- Snippets ----
    var SNIPPETS = {
      section: '(section "Name" "one-line technical summary"\n  (row 0) (col 1)\n  )\n',
      instance: '(instance "U1" component-name\n  (pin 1 "NET1")\n  (pin 2 "NET2"))\n',
      subblock: '(sub-block "name" (module-name))\n',
      net: '(net "NET_NAME" "alias1" "alias2")\n',
      decouple: '(decouple "VDD" 1 per-pin (pins-of "U1" "VDD"))\n'
    };
    function insertSnippet(kind) {
      var snip = SNIPPETS[kind];
      if (!snip) return;
      var cur = cm.getCursor();
      // Indent the snippet to the current line's leading whitespace.
      var lead = (cm.getLine(cur.line) || '').match(/^\s*/)[0];
      var text = snip.replace(/\n(?!$)/g, '\n' + lead);
      cm.replaceRange(text, cur);
      cm.focus();
      scheduleValidate();
    }
    overlay.querySelectorAll('.src-snip').forEach(function (b) {
      b.addEventListener('click', function () { insertSnippet(b.getAttribute('data-snip')); });
    });

    // ---- Tidy indent ----
    // Whitespace-only reindent by paren depth. Strings and ; comments are
    // skipped when counting depth, and only leading whitespace is rewritten —
    // every token and comment is preserved (the AST printer would drop
    // comments, so we never round-trip through it).
    function netParenDelta(line) {
      var d = 0, inStr = false;
      for (var i = 0; i < line.length; i++) {
        var c = line[i];
        if (inStr) { if (c === '\\') { i++; continue; } if (c === '"') inStr = false; continue; }
        if (c === '"') { inStr = true; continue; }
        if (c === ';') break;
        if (c === '(') d++; else if (c === ')') d--;
      }
      return d;
    }
    function tidyIndent() {
      var lines = cm.getValue().split('\n');
      var out = [], depth = 0;
      for (var i = 0; i < lines.length; i++) {
        var line = lines[i].replace(/^\s+/, '');
        if (line === '') { out.push(''); continue; }
        var lead = 0;
        while (lead < line.length && line[lead] === ')') lead++;
        var indent = Math.max(0, depth - lead);
        out.push('  '.repeat(indent) + line);
        depth = Math.max(0, depth + netParenDelta(line));
      }
      var cur = cm.getCursor();
      cm.setValue(out.join('\n'));
      cm.setCursor(cur);
      scheduleValidate();
    }
    overlay.querySelector('.src-edit-format').addEventListener('click', tidyIndent);

    // ---- Split structured↔source outline ----
    // A live list of the design's (instance …) forms parsed from the buffer.
    // Edits to the source update the list (source→structured); clicking a row
    // jumps the editor to that instance (structured→source navigation).
    var splitPanel = overlay.querySelector('.src-split-panel');
    var splitList = overlay.querySelector('.src-split-list');
    var splitBox = overlay.querySelector('.src-edit-box');
    function parseInstances(doc) {
      var re = /\(instance\s+"([^"]+)"\s+(?:\(\s*([^\s)]+)\s+"([^"]*)"\s*\)|([^\s)]+))/g, m, out = [];
      while ((m = re.exec(doc))) out.push({ ref: m[1], comp: m[2] || m[4] || '', val: m[3] || '', idx: m.index });
      return out;
    }
    function refreshSplit() {
      if (splitPanel.hidden) return;
      var doc = cm.getValue();
      splitList.textContent = '';
      parseInstances(doc).forEach(function (it) {
        var row = document.createElement('div');
        row.className = 'src-split-item';
        var ref = document.createElement('span'); ref.className = 'src-split-ref'; ref.textContent = it.ref;
        var comp = document.createElement('span'); comp.className = 'src-split-comp';
        comp.textContent = it.comp + (it.val ? ' ' + it.val : '');
        row.appendChild(ref); row.appendChild(comp);
        row.addEventListener('click', function () {
          revealEditorLine(state, doc.slice(0, it.idx).split('\n').length - 1);
        });
        splitList.appendChild(row);
      });
    }
    overlay.querySelector('.src-edit-outline').addEventListener('click', function () {
      splitPanel.hidden = !splitPanel.hidden;
      splitBox.classList.toggle('has-split', !splitPanel.hidden);
      refreshSplit();
      setTimeout(function () { cm.refresh(); }, 0);
    });
    cm.on('change', refreshSplit);

    // ---- Autocomplete ----
    // Custom popup (the vendored bundle has no show-hint addon). Sources:
    // form names (static, with the grammar we know), nets + ref-des parsed
    // from the buffer, and library components/modules from /api/lib-index.
    var FORMS = ['instance', 'net', 'section', 'sub-block', 'port', 'pin', 'part',
      'decouple', 'series', 'fanout', 'note', 'group', 'import', 'design-block',
      'defmodule', 'bus', 'bus-net', 'bus-port', 'pins', 'protocol', 'role',
      'calc', 'description', 'status', 'assert', 'assert-range', 'let', 'if',
      'cond', 'fmt', 'replicate', 'board', 'placement', 'floorplan',
      'diagram-layout', 'stub', 'hierarchical-ids', 'kicad-pcb'];
    var ac = { el: null, items: [], sel: 0, from: null, to: null };
    function libReady() {
      if (state.libIndex || state.libFetching) return;
      state.libFetching = true;
      fetch('/api/lib-index').then(function (r) { return r.json(); })
        .then(function (j) { state.libIndex = j || { components: [], modules: [] }; })
        .catch(function () { state.libIndex = { components: [], modules: [] }; });
    }
    function collectIdents() {
      var doc = cm.getValue(), refs = {}, nets = {}, m;
      var ri = /\(instance\s+"([^"]+)"/g;
      while ((m = ri.exec(doc))) refs[m[1]] = 1;
      var sq = /"([^"\\]*(?:\\.[^"\\]*)*)"/g;
      while ((m = sq.exec(doc))) { var s = m[1]; if (s && s.indexOf(' ') < 0 && !refs[s]) nets[s] = 1; }
      return { refs: Object.keys(refs), nets: Object.keys(nets) };
    }
    function ctxAt() {
      var cur = cm.getCursor(), line = cm.getLine(cur.line) || '', left = line.slice(0, cur.ch);
      var inStr = ((left.match(/"/g) || []).length % 2) === 1;
      var tm = left.match(/[A-Za-z0-9_+\-.\/~]*$/);
      var token = tm ? tm[0] : '';
      var tokenStart = cur.ch - token.length;
      var bi = tokenStart - 1;
      while (bi >= 0 && line[bi] === ' ') bi--;
      var afterParen = bi >= 0 && line[bi] === '(';
      var isImport = /\(import\b/.test(left);
      return { cur: cur, token: token, tokenStart: tokenStart, inStr: inStr, afterParen: afterParen, isImport: isImport };
    }
    function candidatesFor(c) {
      var out = [], idents = collectIdents();
      var comps = (state.libIndex && state.libIndex.components) || [];
      var mods = (state.libIndex && state.libIndex.modules) || [];
      function add(text, type) { out.push({ text: text, type: type }); }
      if (c.inStr) {
        idents.nets.forEach(function (n) { add(n, 'net'); });
        idents.refs.forEach(function (r) { add(r, 'ref'); });
      } else if (c.afterParen) {
        FORMS.forEach(function (f) { add(f, 'form'); });
        comps.forEach(function (cc) { add(cc.name, cc.family ? 'family' : 'comp'); });
        mods.forEach(function (mm) { add(mm.name, 'module'); });
      } else {
        // bare token mid-form: import args, module args, component refs.
        comps.forEach(function (cc) { add(cc.name, cc.family ? 'family' : 'comp'); });
        mods.forEach(function (mm) { add(mm.name, 'module'); });
        if (!c.isImport) idents.nets.forEach(function (n) { add(n, 'net'); });
      }
      var q = c.token.toLowerCase();
      if (q) {
        out = out.filter(function (o) { return o.text.toLowerCase().indexOf(q) >= 0; });
        out.sort(function (a, b) {
          var ap = a.text.toLowerCase().indexOf(q) === 0 ? 0 : 1;
          var bp = b.text.toLowerCase().indexOf(q) === 0 ? 0 : 1;
          if (ap !== bp) return ap - bp;
          return a.text.length - b.text.length;
        });
      }
      // De-dup by text, cap.
      var seen = {}, dedup = [];
      for (var i = 0; i < out.length && dedup.length < 40; i++) {
        if (seen[out[i].text]) continue;
        seen[out[i].text] = 1; dedup.push(out[i]);
      }
      return dedup;
    }
    var acKeyMap = {
      Up: function () { moveAC(-1); }, Down: function () { moveAC(1); },
      Enter: function () { pickAC(); }, Tab: function () { pickAC(); },
      Esc: function () { closeAC(); }
    };
    function closeAC() {
      if (!ac.el) return;
      cm.removeKeyMap(acKeyMap);
      if (ac.el.parentNode) ac.el.parentNode.removeChild(ac.el);
      ac.el = null; ac.items = [];
    }
    function moveAC(dir) {
      if (!ac.el) return;
      ac.sel = (ac.sel + dir + ac.items.length) % ac.items.length;
      Array.prototype.forEach.call(ac.el.children, function (li, i) {
        li.classList.toggle('sel', i === ac.sel);
        if (i === ac.sel) li.scrollIntoView({ block: 'nearest' });
      });
    }
    function pickAC() {
      if (!ac.el || !ac.items.length) return;
      var it = ac.items[ac.sel];
      cm.replaceRange(it.text, ac.from, ac.to);
      closeAC();
      cm.focus();
      scheduleValidate();
    }
    function openAC() {
      libReady();
      var c = ctxAt();
      var items = candidatesFor(c);
      if (!items.length || (c.token.length === 0 && !c.afterParen && !c.inStr)) { closeAC(); return; }
      closeAC();
      ac.items = items; ac.sel = 0;
      ac.from = { line: c.cur.line, ch: c.tokenStart };
      ac.to = { line: c.cur.line, ch: c.cur.ch };
      var el = document.createElement('ul');
      el.className = 'src-ac';
      items.forEach(function (it, i) {
        var li = document.createElement('li');
        if (i === 0) li.className = 'sel';
        var t = document.createElement('span'); t.className = 'src-ac-text'; t.textContent = it.text;
        var ty = document.createElement('span'); ty.className = 'src-ac-type'; ty.textContent = it.type;
        li.appendChild(t); li.appendChild(ty);
        li.addEventListener('mousedown', function (e) { e.preventDefault(); ac.sel = i; pickAC(); });
        el.appendChild(li);
      });
      var coords = cm.cursorCoords(ac.from, 'page');
      el.style.left = coords.left + 'px';
      el.style.top = coords.bottom + 'px';
      document.body.appendChild(el);
      ac.el = el;
      cm.addKeyMap(acKeyMap);
    }
    cm.on('inputRead', function () { openAC(); });
    cm.on('cursorActivity', function () {
      // Close if the cursor left the active completion range.
      if (!ac.el) return;
      var cur = cm.getCursor();
      if (cur.line !== ac.from.line || cur.ch < ac.from.ch) closeAC();
    });
    cm.on('blur', function () { setTimeout(closeAC, 120); });

    return state;
  }

  // Center the editor on `line`, flash it, and leave the cursor there.
  function revealEditorLine(state, line) {
    state.cm.focus();
    state.cm.setCursor({ line: line, ch: 0 });
    var top = state.cm.charCoords({ line: line, ch: 0 }, 'local').top;
    state.cm.scrollTo(null, top - state.cm.getScrollInfo().clientHeight / 2);
    state.cm.addLineClass(line, 'background', 'cm-section-flash');
    setTimeout(function () { state.cm.removeLineClass(line, 'background', 'cm-section-flash'); }, 1500);
  }

  // Reveal the first line matching `needle` in the editor (or just focus when
  // the form isn't found — e.g. a replicate-generated sub-block has no literal
  // declaration). `label` shows in the editor header.
  function scrollEditorToText(state, needle, label) {
    function go() {
      state.secEl.textContent = label ? '· ' + label : '';
      if (!needle) { state.cm.focus(); return; }
      var doc = state.cm.getValue();
      var idx = doc.indexOf(needle);
      if (idx < 0) { state.cm.focus(); return; }
      revealEditorLine(state, doc.slice(0, idx).split('\n').length - 1);
    }
    if (state.loaded) go(); else state.loadPromise.then(go);
  }

  function scrollEditorToSection(state, sectionName) {
    scrollEditorToText(state, sectionName ? '(section "' + sectionName + '"' : '', sectionName);
  }

  // Jump to a byte offset (SCH_INDEX components[].src, reported by the Zig
  // renderer). The offset indexes the UTF-8 source bytes, not the JS (UTF-16)
  // string, so derive the line by counting newline bytes up to it.
  function scrollEditorToOffset(state, byteOff, label) {
    function go() {
      state.secEl.textContent = label ? '· ' + label : '';
      var bytes = new TextEncoder().encode(state.cm.getValue());
      var line = 0;
      var end = Math.min(byteOff, bytes.length);
      for (var i = 0; i < end; i++) {
        if (bytes[i] === 10) line++;
      }
      revealEditorLine(state, line);
    }
    if (state.loaded) go(); else state.loadPromise.then(go);
  }

  function openSourceEditor(sectionName) {
    if (!window.CodeMirror) { alert('Source editor failed to load (CodeMirror missing)'); return; }
    if (!srcEditor) srcEditor = buildSourceEditor();
    scrollEditorToSection(srcEditor, sectionName);
  }

  // Open the source editor at a sub-block's `(sub-block "name" …)` declaration.
  function openSourceEditorAtSubBlock(subName) {
    if (!window.CodeMirror) { alert('Source editor failed to load (CodeMirror missing)'); return; }
    if (!srcEditor) srcEditor = buildSourceEditor();
    scrollEditorToText(srcEditor, '(sub-block "' + subName + '"', subName);
  }

  function openSourceEditorAtOffset(byteOff, label) {
    if (!window.CodeMirror) { alert('Source editor failed to load (CodeMirror missing)'); return; }
    if (!srcEditor) srcEditor = buildSourceEditor();
    scrollEditorToOffset(srcEditor, byteOff, label);
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
    // 64x: deep enough that a dense section's schematic tile (a dozen part
    // symbols packed into one block) reaches comfortably readable pin text.
    var minW = base.w / 64, maxW = base.w * 1.2;

    // ---- Semantic zoom (Layout view only) ----
    // The server stamps data-lod="0" on the Layout SVG when it carries a
    // glance layer. Zoom drives the attribute through 0 (group chips) →
    // 1 (the full block diagram with labels) → 2 (each block becomes a
    // window onto its section's real schematic); the page CSS does the
    // actual cross-fades, so this stays one attribute write.
    var hasLod = svg.hasAttribute('data-lod');
    var lodTag = null, deepBuilt = false;
    function lodFor(z) { return z < 1.45 ? '0' : (z < 3.0 ? '1' : '2'); }
    function updateLod() {
      if (!hasLod) return;
      var l = lodFor(base.w / cur.w);
      if (l === '2' && !deepBuilt) buildDeepLayer();
      if (svg.getAttribute('data-lod') !== l) svg.setAttribute('data-lod', l);
      if (lodTag) lodTag.textContent = 'LOD ' + l + ' · ' + (l === '0' ? 'glance' : l === '1' ? 'detail' : 'schematic');
    }

    // ---- Deep layer (LOD 2): the actual schematic inside each block ----
    // Every diagram node links to its section card (#sec-SLUG / #sub-SLUG),
    // and each card already contains the real hub-and-spoke schematic as
    // standalone <svg class="hub-inset"> elements. Clone them into a nested
    // <svg> scaled to the node's box, so zooming past the detail level turns
    // each block into a window onto its actual circuit. Built lazily on the
    // first entry into LOD 2; pointer-events stay off so clicks fall through
    // to the node link (jump to the full card below).
    function buildDeepLayer() {
      deepBuilt = true;
      var NS = 'http://www.w3.org/2000/svg';
      var deep = document.createElementNS(NS, 'g');
      deep.setAttribute('class', 'dg-deep');
      var made = 0;
      svg.querySelectorAll('a.dg-node-link').forEach(function (link) {
        var href = link.getAttribute('href') || '';
        if (href.indexOf('#sec-') !== 0) return;
        var slug = href.slice(5);
        var card = document.getElementById('sec-' + slug) || document.getElementById('sub-' + slug);
        if (!card) return;
        var insets = card.querySelectorAll('svg.hub-inset');
        if (!insets.length) return;
        var rects = link.querySelectorAll('.dg-rect');
        var rect = rects[rects.length - 1];
        if (!rect) return;
        var x = parseFloat(rect.getAttribute('x')), y = parseFloat(rect.getAttribute('y'));
        var bw = parseFloat(rect.getAttribute('width')), bh = parseFloat(rect.getAttribute('height'));
        if ([x, y, bw, bh].some(isNaN)) return;
        var GAP = 48, parts = [];
        insets.forEach(function (s) {
          var vb = (s.getAttribute('viewBox') || '').split(/[ ,]+/).map(Number);
          if (vb.length !== 4 || vb.some(isNaN)) return;
          parts.push({ el: s, w: vb[2], h: vb[3] });
        });
        if (!parts.length) return;
        // Pack the card's insets into the row count that wastes the least
        // scale inside the wide block box — one long row shrinks a many-part
        // section (the MCU core) to dust, one tall stack does the same to a
        // pair, so try each and keep the best fit.
        function measure(rows) {
          var cols = Math.ceil(parts.length / rows), W = 0, H = 0, grid = [];
          for (var ri = 0; ri < rows; ri++) {
            var row = parts.slice(ri * cols, (ri + 1) * cols);
            if (!row.length) continue;
            var rw = row.reduce(function (a, p) { return a + p.w; }, 0) + GAP * (row.length - 1);
            var rh = 0;
            row.forEach(function (p) { rh = Math.max(rh, p.h); });
            grid.push({ row: row, w: rw, h: rh });
            W = Math.max(W, rw);
            H += rh + (grid.length > 1 ? GAP : 0);
          }
          return { grid: grid, W: W, H: H, scale: Math.min((bw - 6) / W, (bh - 6) / H) };
        }
        var best = measure(1);
        for (var r = 2; r <= Math.min(parts.length, 4); r++) {
          var m = measure(r);
          if (m.scale > best.scale) best = m;
        }
        var W = best.W, H = best.H;
        var tile = document.createElementNS(NS, 'g');
        var back = document.createElementNS(NS, 'rect');
        back.setAttribute('x', x); back.setAttribute('y', y);
        back.setAttribute('width', bw); back.setAttribute('height', bh);
        back.setAttribute('rx', 6);
        back.setAttribute('fill', '#0d1117');
        back.setAttribute('stroke', rect.getAttribute('stroke') || '#30363d');
        back.setAttribute('stroke-width', '1');
        tile.appendChild(back);
        var outer = document.createElementNS(NS, 'svg');
        outer.setAttribute('x', x + 3); outer.setAttribute('y', y + 3);
        outer.setAttribute('width', bw - 6); outer.setAttribute('height', bh - 6);
        outer.setAttribute('viewBox', '0 0 ' + W + ' ' + H);
        outer.setAttribute('preserveAspectRatio', 'xMidYMid meet');
        var rowY = 0;
        best.grid.forEach(function (g) {
          var off = (W - g.w) / 2;
          g.row.forEach(function (p) {
            var clone = p.el.cloneNode(true);
            clone.removeAttribute('class');
            clone.removeAttribute('id');
            clone.setAttribute('x', off);
            clone.setAttribute('y', rowY + (g.h - p.h) / 2);
            clone.setAttribute('width', p.w);
            clone.setAttribute('height', p.h);
            off += p.w + GAP;
            outer.appendChild(clone);
          });
          rowY += g.h + GAP;
        });
        tile.appendChild(outer);
        deep.appendChild(tile);
        made++;
      });
      if (made) svg.appendChild(deep);
    }

    function apply() { svg.setAttribute('viewBox', cur.x + ' ' + cur.y + ' ' + cur.w + ' ' + cur.h); updateLod(); }
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

    // The diagram's node boxes are <a> links: starting a drag on one fires the
    // browser's native link-drag (a ghost of the SVG follows the cursor)
    // instead of our pan. Killing dragstart keeps pointer-based panning the
    // only drag behavior.
    svg.addEventListener('dragstart', function (e) { e.preventDefault(); });

    var dragging = false, sx0 = 0, sy0 = 0, ox = 0, oy = 0, moved = false;
    svg.addEventListener('pointerdown', function (e) {
      if (e.button !== 0) return;
      // In layout-edit mode a press on a block is a block-drag, not a pan — let
      // the node's own pointer handler own it (background still pans).
      if (svg.classList.contains('dg-editing') && e.target.closest &&
          e.target.closest('.dg-node-link, .dg-node')) return;
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

    if (hasLod) {
      lodTag = document.createElement('span');
      lodTag.className = 'dg-lod-tag';
      lodTag.title = 'Detail level — zoom to change (scroll, buttons, or click a chip)';
      bar.insertBefore(lodTag, bar.firstChild);
      updateLod();

      // Click a glance chip → glide the viewBox into that group's region; the
      // zoom crosses the LOD threshold, so the chip "opens" into its blocks.
      var glideRaf = null;
      function glideTo(x, y, w2, h2) {
        if (glideRaf) cancelAnimationFrame(glideRaf);
        var from = { x: cur.x, y: cur.y, w: cur.w, h: cur.h }, t0 = null;
        function step(ts) {
          if (t0 === null) t0 = ts;
          var p = Math.min(1, (ts - t0) / 360); p = p * (2 - p);
          cur.x = from.x + (x - from.x) * p; cur.y = from.y + (y - from.y) * p;
          cur.w = from.w + (w2 - from.w) * p; cur.h = from.h + (h2 - from.h) * p;
          apply();
          if (p < 1) glideRaf = requestAnimationFrame(step);
        }
        glideRaf = requestAnimationFrame(step);
      }
      svg.querySelectorAll('.dg-chip').forEach(function (chip) {
        chip.addEventListener('click', function () {
          var r = {
            x: parseFloat(chip.getAttribute('data-x')), y: parseFloat(chip.getAttribute('data-y')),
            w: parseFloat(chip.getAttribute('data-w')), h: parseFloat(chip.getAttribute('data-h'))
          };
          if (isNaN(r.x) || isNaN(r.w)) return;
          // Frame the region with padding, but force the zoom past the LOD-0
          // threshold so a huge group still switches to its block view.
          var pad = 70;
          var tw = Math.max(r.w + pad * 2, (r.h + pad * 2) * base.w / base.h);
          tw = Math.min(Math.max(tw, minW), base.w / 1.55);
          var th = tw * base.h / base.w;
          glideTo(r.x + r.w / 2 - tw / 2, r.y + r.h / 2 - th / 2, tw, th);
        });
      });
    }
  }
  document.querySelectorAll('.dg-svg').forEach(setupDiagramZoom);

  // ---- Hover-focus dimming (declutter) ----
  // A dense Layout diagram is hard to trace because every net is drawn at once.
  // Hovering a block dims every connection except the nets touching it (and the
  // blocks at their far ends), so the diagram reads one subsystem at a time.
  // Pure presentation: the block carries data-gid, each edge/dot/arrow carries
  // data-a/data-b (its endpoint gids), and we just toggle the .dg-hot class the
  // CSS fades around. Works at any zoom (LOD 0's glance layer has no .dg-node,
  // so it's unaffected).
  document.querySelectorAll('.dg-svg').forEach(function (svg) {
    var nodes = svg.querySelectorAll('.dg-node[data-gid]');
    if (nodes.length < 3) return; // nothing to declutter on a 2-block diagram
    if (svg.querySelectorAll('[data-a]').length === 0) return; // no wires to dim (e.g. the blocks-only Layout view)
    function clearFocus() {
      svg.classList.remove('dg-focus');
      svg.querySelectorAll('.dg-hot').forEach(function (el) { el.classList.remove('dg-hot'); });
    }
    nodes.forEach(function (node) {
      node.addEventListener('mouseenter', function () {
        var gid = node.getAttribute('data-gid');
        if (gid === null) return;
        clearFocus();
        svg.classList.add('dg-focus');
        var neigh = Object.create(null);
        neigh[gid] = true;
        svg.querySelectorAll('[data-a="' + gid + '"],[data-b="' + gid + '"]').forEach(function (el) {
          el.classList.add('dg-hot');
          neigh[el.getAttribute('data-a')] = true;
          neigh[el.getAttribute('data-b')] = true;
        });
        nodes.forEach(function (n) {
          if (neigh[n.getAttribute('data-gid')]) n.classList.add('dg-hot');
        });
      });
      node.addEventListener('mouseleave', clearFocus);
    });
  });

  // ---- Layout-tab drag-to-arrange ----
  // An "Edit layout" toggle on the Layout SVG lets you drag blocks; "Save"
  // regenerates a (diagram-layout …) from the dragged grid (anchor + a
  // staircase of right-of / below constraints — the DSL is relative-only) and
  // POSTs it to /api/diagram-layout, preserving any (group …)/(edge …) lines.
  var LAYOUT_CELL_W = 484, LAYOUT_CELL_H = 214; // node_w+gap × node_h+gap

  // Map a client (screen) point into the SVG's user coordinate space — robust
  // to the viewer's zoom/pan because getScreenCTM reflects the live viewBox.
  function svgPoint(svg, cx, cy) {
    var pt = svg.createSVGPoint(); pt.x = cx; pt.y = cy;
    var m = svg.getScreenCTM();
    if (!m) return { x: cx, y: cy };
    var p = pt.matrixTransform(m.inverse());
    return { x: p.x, y: p.y };
  }
  // Build a (diagram-layout …) form from placed blocks. Exposed for tests via
  // window.__buildDiagramForm. `extra` = preserved (group …)/(edge …) lines.
  function buildDiagramForm(blocks, extra) {
    if (!blocks.length) return '(diagram-layout)';
    blocks.forEach(function (b) {
      b.col = Math.round(b.x / LAYOUT_CELL_W);
      b.row = Math.round(b.y / LAYOUT_CELL_H);
    });
    var rowsMap = {};
    blocks.forEach(function (b) { (rowsMap[b.row] = rowsMap[b.row] || []).push(b); });
    var rowKeys = Object.keys(rowsMap).map(Number).sort(function (a, b) { return a - b; });
    var lines = [], anchor = null, prevRowFirst = null;
    function q(s) { return '"' + String(s).replace(/"/g, '\\"') + '"'; }
    rowKeys.forEach(function (rk, ri) {
      var row = rowsMap[rk].sort(function (a, b) { return a.col - b.col; });
      row.forEach(function (b, ci) {
        if (ri === 0 && ci === 0) anchor = b.name;
        else if (ci === 0) lines.push('(place ' + q(b.name) + ' (below ' + q(prevRowFirst) + '))');
        else lines.push('(place ' + q(b.name) + ' (right-of ' + q(row[ci - 1].name) + '))');
      });
      prevRowFirst = row[0].name;
    });
    var body = '  (anchor ' + q(anchor) + ')';
    if (lines.length) body += '\n  ' + lines.join('\n  ');
    (extra || []).forEach(function (e) { body += '\n  ' + e; });
    return '(diagram-layout\n' + body + ')';
  }
  if (typeof window !== 'undefined') window.__buildDiagramForm = buildDiagramForm;

  // Extract balanced (group …)/(edge …)/(row …) sub-forms from a diagram-layout
  // form's text, to preserve them across a drag-driven regeneration.
  function extractLayoutGroups(src) {
    var form = src.match(/\((?:diagram-layout|layout)\b/);
    if (!form) return [];
    var start = form.index, depth = 0, i = start, inStr = false, body = '';
    for (; i < src.length; i++) {
      var c = src[i];
      body += c;
      if (inStr) { if (c === '\\') { body += src[++i]; } else if (c === '"') inStr = false; continue; }
      if (c === '"') inStr = true;
      else if (c === ';') { while (i < src.length && src[i] !== '\n') body += src[++i] || ''; }
      else if (c === '(') depth++;
      else if (c === ')') { depth--; if (depth === 0) break; }
    }
    var out = [];
    var re = /\((?:group|edge|row)\b/g, m;
    while ((m = re.exec(body))) {
      var s = m.index, d = 0, j = s, str = false, frag = '';
      for (; j < body.length; j++) {
        var ch = body[j]; frag += ch;
        if (str) { if (ch === '\\') { frag += body[++j]; } else if (ch === '"') str = false; continue; }
        if (ch === '"') str = true; else if (ch === '(') d++; else if (ch === ')') { d--; if (d === 0) break; }
      }
      out.push(frag);
    }
    return out;
  }

  document.querySelectorAll('.dg-svg[data-lod]').forEach(function (svg) {
    var nodes = svg.querySelectorAll('.dg-node[data-name]');
    if (nodes.length < 2) return;
    var bar = document.createElement('div');
    bar.className = 'dg-edit-bar';
    bar.innerHTML = '<button type="button" class="dg-edit-toggle">✎ Edit layout</button>' +
      '<button type="button" class="dg-edit-save" hidden>Save</button>' +
      '<button type="button" class="dg-edit-cancel" hidden>Cancel</button>' +
      '<span class="dg-edit-msg"></span>';
    var parent = svg.parentNode;
    if (parent) { parent.style.position = parent.style.position || 'relative'; parent.appendChild(bar); }
    var editing = false, drag = null;
    var toggle = bar.querySelector('.dg-edit-toggle');
    var saveBtn = bar.querySelector('.dg-edit-save');
    var cancelBtn = bar.querySelector('.dg-edit-cancel');
    var msg = bar.querySelector('.dg-edit-msg');

    function nodeBase(node) {
      var rect = node.querySelector('rect');
      return { x: parseFloat(rect.getAttribute('x')) || 0, y: parseFloat(rect.getAttribute('y')) || 0 };
    }
    function setEditing(on) {
      editing = on;
      svg.classList.toggle('dg-editing', on);
      toggle.hidden = on; saveBtn.hidden = !on; cancelBtn.hidden = !on;
      msg.textContent = on ? 'Drag blocks, then Save' : '';
    }
    toggle.addEventListener('click', function () { setEditing(true); });
    cancelBtn.addEventListener('click', function () { window.location.reload(); });

    // Pointer events (not mouse) so stopPropagation actually keeps the SVG's
    // pointer-based pan from firing on the same press; pointer capture makes the
    // drag robust if the cursor briefly leaves the block.
    nodes.forEach(function (node) {
      node.addEventListener('pointerdown', function (e) {
        if (!editing || e.button !== 0) return;
        e.preventDefault(); e.stopPropagation();
        var tr = node.transform.baseVal.consolidate();
        var base = { tx: tr ? tr.matrix.e : 0, ty: tr ? tr.matrix.f : 0 };
        var p0 = svgPoint(svg, e.clientX, e.clientY);
        drag = { node: node, base: base, p0: p0 };
        try { node.setPointerCapture(e.pointerId); } catch (_) {}
      });
      // While editing, a block press/release must not follow its <a> cross-probe
      // link (would navigate away mid-edit).
      node.addEventListener('click', function (e) { if (editing) { e.preventDefault(); e.stopPropagation(); } });
    });
    window.addEventListener('pointermove', function (e) {
      if (!drag) return;
      var p = svgPoint(svg, e.clientX, e.clientY);
      drag.node.setAttribute('transform', 'translate(' + (drag.base.tx + p.x - drag.p0.x) + ',' + (drag.base.ty + p.y - drag.p0.y) + ')');
    });
    window.addEventListener('pointerup', function () { drag = null; });

    saveBtn.addEventListener('click', function () {
      msg.textContent = 'Saving…';
      var blocks = [];
      nodes.forEach(function (node) {
        var b = nodeBase(node);
        var tr = node.transform.baseVal.consolidate();
        blocks.push({ name: node.getAttribute('data-name'), x: b.x + (tr ? tr.matrix.e : 0), y: b.y + (tr ? tr.matrix.f : 0) });
      });
      // Preserve groups/edges from the current source, then write back.
      fetch('/api/source/' + DESIGN_NAME).then(function (r) { return r.json(); })
        .then(function (j) {
          var extra = extractLayoutGroups(typeof j.source === 'string' ? j.source : '');
          var form = buildDiagramForm(blocks, extra);
          return fetch('/api/diagram-layout/' + DESIGN_NAME, {
            method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ form: form })
          });
        })
        .then(function (r) { return r.json(); })
        .then(function (res) {
          if (!res || res.ok === false) { msg.textContent = (res && res.error) || 'save failed'; return; }
          window.location.reload();
        })
        .catch(function (e) { msg.textContent = e.message || 'network error'; });
    });
  });

  // ---- Diagram block → section cross-probe ----
  // Every block in the Layout / Power / Clocks / Control / System diagrams is
  // an SVG <a href="#sec-SLUG"> link. Native hash-nav already jumps there, but
  // when the target section is already on-screen the jump is invisible — so
  // intercept the click to scroll-center AND flash the section, the same
  // feedback the sidebar's section list gives. A sub-block attached inside a
  // section renders under id="sub-SLUG", so fall back to that anchor.
  document.addEventListener('click', function (e) {
    var link = e.target.closest && e.target.closest('a.dg-node-link');
    if (!link) return;
    var href = link.getAttribute('href') || '';
    if (href.indexOf('#sec-') !== 0) return;
    var slug = href.slice(5);
    var anchor = document.getElementById('sec-' + slug) || document.getElementById('sub-' + slug);
    if (!anchor) return; // let native nav try if we can't resolve it
    e.preventDefault();
    scrollTo(anchor);
    flash(anchor);
  });

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

  // ---- Revision changelog popover ----
  // The header "Rev <id>" pill (rendered by render_html.zig when the design
  // declares a (revision …) form with (change …) entries) opens an in-file
  // changelog. Toggle on click; close on outside-click or Escape. No-op when
  // the design has no revision/changelog (the pill is a plain span then).
  (function () {
    var pill = document.getElementById('rev-pill');
    var panel = document.getElementById('rev-changelog');
    if (!pill || !panel) return;
    var wrap = pill.parentNode;
    function close() {
      panel.hidden = true;
      wrap.classList.remove('open');
      pill.setAttribute('aria-expanded', 'false');
    }
    function open() {
      panel.hidden = false;
      wrap.classList.add('open');
      pill.setAttribute('aria-expanded', 'true');
    }
    pill.addEventListener('click', function (e) {
      e.stopPropagation();
      if (panel.hidden) open(); else close();
    });
    document.addEventListener('click', function (e) {
      if (!panel.hidden && !wrap.contains(e.target)) close();
    });
    document.addEventListener('keydown', function (e) {
      if (e.key === 'Escape' && !panel.hidden) close();
    });
  })();

  // ---- Boot ----
  if (!applyHashFocus()) showSectionList();
})();
