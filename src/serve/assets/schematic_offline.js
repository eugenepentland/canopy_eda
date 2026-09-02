// netlisp-offline-schematic-search
// Dependency-free, read-only search/navigation for exported schematic HTML.
(function () {
  'use strict';

  var searchInput = document.getElementById('sch-search');
  var resultsBox = document.getElementById('sb-results');
  var detailBox = document.getElementById('sb-detail');
  if (!searchInput || !resultsBox || !detailBox || typeof SCH_INDEX === 'undefined') return;

  var currentResults = [];
  var selectedIdx = -1;
  var compByRef = {};
  var sectionBySlug = {};
  var netByName = {};
  (SCH_INDEX.components || []).forEach(function (c) { compByRef[c.ref] = c; });
  (SCH_INDEX.sections || []).forEach(function (s) { sectionBySlug[s.slug] = s; });
  (SCH_INDEX.nets || []).forEach(function (n) { netByName[n.name] = n; });

  function escapeHtml(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
    });
  }
  function cssEscape(s) {
    if (window.CSS && CSS.escape) return CSS.escape(s);
    return String(s).replace(/[^a-zA-Z0-9_-]/g, '\\$&');
  }
  function cmpPin(a, b) {
    var ra = /^([A-Za-z]*)(\d*)$/.exec(a) || [];
    var rb = /^([A-Za-z]*)(\d*)$/.exec(b) || [];
    if (ra[1] !== rb[1]) return ra[1] < rb[1] ? -1 : 1;
    var na = parseInt(ra[2] || '0', 10);
    var nb = parseInt(rb[2] || '0', 10);
    if (na !== nb) return na - nb;
    return a < b ? -1 : a > b ? 1 : 0;
  }
  function clearHighlight() {
    document.querySelectorAll('.net-active,.pin-active,.flash').forEach(function (n) {
      n.classList.remove('net-active', 'pin-active', 'flash');
    });
  }
  function highlightNet(net) {
    clearHighlight();
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
    document.querySelectorAll('.flash').forEach(function (n) { n.classList.remove('flash'); });
    el.classList.add('flash');
    setTimeout(function () { el.classList.remove('flash'); }, 1500);
  }
  function scrollToElement(el) {
    if (el) el.scrollIntoView({ behavior: 'auto', block: 'center' });
  }
  function componentAnchor(ref) {
    return document.querySelector('.sch-hub[data-ref="' + cssEscape(ref) + '"]') ||
      document.querySelector('svg [data-ref="' + cssEscape(ref) + '"].component');
  }

  function search(query) {
    var q = (query || '').trim().toLowerCase();
    if (!q) return [];
    var out = [];
    function push(rec) { if (out.length < 25) out.push(rec); }
    (SCH_INDEX.sections || []).forEach(function (s) {
      if (s.name.toLowerCase().indexOf(q) !== -1 || (s.description || '').toLowerCase().indexOf(q) !== -1) {
        push({ kind: 'section', label: s.name, sub: s.description, slug: s.slug, category: s.category || '' });
      }
    });
    (SCH_INDEX.components || []).forEach(function (c) {
      var mpn = (c.mpn || '').toLowerCase();
      var mfr = (c.manufacturer || '').toLowerCase();
      var matched = c.ref.toLowerCase().indexOf(q) !== -1 ||
        (c.component || '').toLowerCase().indexOf(q) !== -1 ||
        (c.value || '').toLowerCase().indexOf(q) !== -1 ||
        mpn.indexOf(q) !== -1 || mfr.indexOf(q) !== -1;
      if (!matched) return;
      var sub = (c.component || '') + (c.value ? ' · ' + c.value : '');
      if (mpn && (mpn.indexOf(q) !== -1 || mfr.indexOf(q) !== -1)) {
        sub += ' · ' + (c.manufacturer ? c.manufacturer + ' ' : '') + c.mpn;
      }
      push({ kind: 'comp', label: c.ref, sub: sub, ref: c.ref });
    });
    (SCH_INDEX.nets || []).forEach(function (n) {
      if (n.name.toLowerCase().indexOf(q) !== -1) {
        var count = (n.members || []).length;
        push({ kind: 'net', label: n.name, sub: count + ' pin' + (count === 1 ? '' : 's'), net: n.name });
      }
    });
    (SCH_INDEX.components || []).forEach(function (c) {
      if (c.kind !== 'hub') return;
      (c.pins || []).forEach(function (p) {
        var hay = (p.id + ' ' + (p.fn || '') + ' ' + (p.alt || '')).toLowerCase();
        if (hay.indexOf(q) !== -1) {
          var sub = (p.fn || p.net || '') + (p.alt && p.alt !== p.fn ? ' · ' + p.alt : '');
          push({ kind: 'pin', label: c.ref + '.' + p.id, sub: sub, ref: c.ref, pin: p.id, net: p.net });
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
    resultsBox.innerHTML = currentResults.map(function (r, i) {
      var metaLabel = r.kind === 'section' && r.category ? r.category : r.kind;
      var metaClass = r.kind === 'section' && r.category
        ? 'sb-cat cat-' + r.category
        : 'sb-result-meta t-' + (r.kind === 'section' ? 'sec' : r.kind);
      return '<div class="sb-result' + (i === selectedIdx ? ' selected' : '') + '" data-idx="' + i + '">' +
        '<div class="sb-result-label" title="' + escapeHtml(r.label + (r.sub ? ' — ' + r.sub : '')) + '">' +
        escapeHtml(r.label) + (r.sub ? ' <span class="muted">' + escapeHtml(r.sub) + '</span>' : '') + '</div>' +
        '<span class="' + metaClass + '">' + escapeHtml(metaLabel) + '</span></div>';
    }).join('');
    resultsBox.classList.add('open');
  }
  function closeResults() {
    currentResults = [];
    selectedIdx = -1;
    renderResults();
  }

  function showSectionList() {
    if (!(SCH_INDEX.sections || []).length) {
      detailBox.innerHTML = '<div class="sb-empty">No sections.</div>';
      return;
    }
    var html = '<h4>Sections</h4>';
    SCH_INDEX.sections.forEach(function (s) {
      html += '<div class="sb-list-item" data-slug="' + escapeHtml(s.slug) + '">' +
        '<div class="sb-li-head"><span>' + escapeHtml(s.name) + '</span></div>' +
        (s.description ? '<div class="sb-li-sub">' + escapeHtml(s.description) + '</div>' : '') + '</div>';
    });
    detailBox.innerHTML = html;
    detailBox.querySelectorAll('.sb-list-item[data-slug]').forEach(function (el) {
      el.addEventListener('click', function () { showSection(el.dataset.slug, true); });
    });
  }
  function wireBack() {
    var back = detailBox.querySelector('.sb-back');
    if (back) back.addEventListener('click', showSectionList);
  }
  function showSection(slug, doScroll) {
    var sec = sectionBySlug[slug];
    if (!sec) return;
    if (doScroll) {
      var anchor = document.getElementById('sec-' + slug) || document.getElementById('sub-' + slug);
      scrollToElement(anchor);
      flash(anchor);
    }
    var html = '<span class="sb-back">← All sections</span><h4>' + escapeHtml(sec.name) + '</h4>';
    if (sec.description) html += '<div class="sb-comp-meta">' + escapeHtml(sec.description) + '</div>';
    if (!(sec.hubs || []).length) html += '<div class="sb-empty">No hubs in this section.</div>';
    (sec.hubs || []).forEach(function (ref) {
      var c = compByRef[ref];
      if (!c) return;
      html += '<div class="sb-list-item" data-ref="' + escapeHtml(ref) + '"><div class="sb-li-head">' +
        escapeHtml(ref) + '</div><div class="sb-li-sub">' + escapeHtml(c.component || '') +
        (c.value ? ' · ' + escapeHtml(c.value) : '') + '</div></div>';
    });
    detailBox.innerHTML = html;
    wireBack();
    detailBox.querySelectorAll('.sb-list-item[data-ref]').forEach(function (el) {
      el.addEventListener('click', function () { showComponent(el.dataset.ref, true); });
    });
  }
  function showComponent(ref, doScroll) {
    var c = compByRef[ref];
    if (!c) return;
    if (doScroll) {
      var anchor = componentAnchor(ref);
      scrollToElement(anchor);
      flash(anchor);
    }
    var html = '<span class="sb-back">← All sections</span><h4>' + escapeHtml(ref) + '</h4>' +
      '<div class="sb-comp-meta">' + escapeHtml(c.component || '') +
      (c.value ? ' · ' + escapeHtml(c.value) : '') + '</div>';
    var pins = c.kind === 'hub' ? (c.pins || []).slice() : [];
    if (c.kind !== 'hub') {
      (SCH_INDEX.nets || []).forEach(function (n) {
        (n.members || []).forEach(function (m) {
          if (m.ref === ref) pins.push({ id: m.pin, net: n.name, fn: m.fn || '' });
        });
      });
    }
    pins.sort(function (a, b) { return cmpPin(a.id, b.id); });
    if (!pins.length) html += '<div class="sb-empty">No pin connections.</div>';
    pins.forEach(function (p) {
      html += '<div class="sb-pin-row" data-ref="' + escapeHtml(ref) + '" data-pin="' + escapeHtml(p.id) +
        '" data-net="' + escapeHtml(p.net || '') + '"><div class="sb-pin-id">' + escapeHtml(p.id) +
        '</div><div><div class="sb-pin-net">' + (p.net ? escapeHtml(p.net) : '<span class="muted">—</span>') +
        '</div>' + (p.fn || p.alt ? '<div class="sb-pin-fn">' + escapeHtml(p.fn || '') +
        (p.alt && p.alt !== p.fn ? ' <span class="sb-pin-alt">' + escapeHtml(p.alt) + '</span>' : '') + '</div>' : '') +
        '</div></div>';
    });
    detailBox.innerHTML = html;
    wireBack();
    detailBox.querySelectorAll('.sb-pin-row').forEach(function (row) {
      row.addEventListener('click', function () {
        if (row.dataset.net) showNet(row.dataset.net, true);
      });
    });
  }
  function showNet(net, doScroll) {
    var rec = netByName[net];
    var first = highlightNet(net);
    if (doScroll) scrollToElement(first);
    var members = rec ? (rec.members || []).slice() : [];
    var html = '<span class="sb-back">← All sections</span><h4>' + escapeHtml(net) + '</h4>' +
      '<div class="sb-comp-meta">' + members.length + ' connection' + (members.length === 1 ? '' : 's') + '</div>';
    members.sort(function (a, b) {
      return a.ref === b.ref ? cmpPin(a.pin, b.pin) : (a.ref < b.ref ? -1 : 1);
    });
    members.forEach(function (m) {
      var c = compByRef[m.ref];
      html += '<div class="sb-net-row" data-ref="' + escapeHtml(m.ref) + '"><div class="sb-net-row-head">' +
        '<span class="sb-net-ref">' + escapeHtml(m.ref) + '</span> <span class="sb-net-comp">' +
        escapeHtml(c ? c.component || '' : '') + '</span></div><div class="sb-net-pins">' + escapeHtml(m.pin) + '</div></div>';
    });
    detailBox.innerHTML = html;
    wireBack();
    detailBox.querySelectorAll('.sb-net-row[data-ref]').forEach(function (row) {
      row.addEventListener('click', function () { showComponent(row.dataset.ref, true); });
    });
  }
  function pickResult(r) {
    if (!r) return;
    if (r.kind === 'section') showSection(r.slug, true);
    else if (r.kind === 'comp') showComponent(r.ref, true);
    else if (r.kind === 'net') showNet(r.net, true);
    else if (r.kind === 'pin') {
      showComponent(r.ref, true);
      if (r.net) highlightNet(r.net);
      var pin = document.querySelector('svg .pin-stub[data-ref="' + cssEscape(r.ref) + '"][data-pin^="' + cssEscape(r.pin) + '"]');
      if (pin) {
        pin.classList.add('pin-active');
        scrollToElement(pin);
      }
    }
    closeResults();
  }

  searchInput.addEventListener('input', function () {
    currentResults = search(searchInput.value);
    selectedIdx = currentResults.length ? 0 : -1;
    renderResults();
    if (!searchInput.value.trim()) clearHighlight();
  });
  searchInput.addEventListener('keydown', function (e) {
    if (e.key === 'ArrowDown' && currentResults.length) {
      e.preventDefault(); selectedIdx = (selectedIdx + 1) % currentResults.length; renderResults();
    } else if (e.key === 'ArrowUp' && currentResults.length) {
      e.preventDefault(); selectedIdx = (selectedIdx - 1 + currentResults.length) % currentResults.length; renderResults();
    } else if (e.key === 'Enter' && selectedIdx >= 0) {
      e.preventDefault(); pickResult(currentResults[selectedIdx]);
    } else if (e.key === 'Escape') {
      e.preventDefault(); searchInput.value = ''; clearHighlight(); closeResults(); searchInput.blur();
    }
  });
  resultsBox.addEventListener('click', function (e) {
    var item = e.target.closest && e.target.closest('.sb-result');
    if (item) pickResult(currentResults[parseInt(item.dataset.idx, 10)]);
  });
  document.addEventListener('keydown', function (e) {
    if (e.target === searchInput) return;
    var typing = e.target && (e.target.tagName === 'INPUT' || e.target.tagName === 'TEXTAREA' || e.target.isContentEditable);
    if (!typing && (e.key === '/' || ((e.ctrlKey || e.metaKey) && e.key === 'f'))) {
      e.preventDefault(); searchInput.focus(); searchInput.select();
    }
  });
  document.addEventListener('click', function (e) {
    var comp = e.target.closest && e.target.closest('svg .component');
    if (comp && comp.dataset.ref && compByRef[comp.dataset.ref]) { showComponent(comp.dataset.ref, false); return; }
    var net = e.target.closest && e.target.closest('svg .net');
    if (net && net.dataset.net) showNet(net.dataset.net, false);
  });

  showSectionList();
}());
