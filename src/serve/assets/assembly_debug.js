(function () {
  'use strict';

  const dataNode = document.getElementById('assembly-debug-data');
  if (!dataNode) return;
  const model = JSON.parse(dataNode.textContent || '{}');
  const standalone = Boolean(model.standalone);
  const messageTargetOrigin = standalone ? '*' : window.location.origin;
  const sidebarPanel = document.querySelector('.panel');
  const frame = document.getElementById('pcb-frame');
  const boardSideButton = document.getElementById('board-side');
  const boardRotateLeft = document.getElementById('board-rotate-left');
  const boardRotateRight = document.getElementById('board-rotate-right');
  const boardOrientation = document.getElementById('board-orientation');
  const load3dModels = document.getElementById('load-3d-models');
  const camReviewButton = document.getElementById('cam-review');
  const camReviewStatus = document.getElementById('cam-review-status');
  const camLayerMenu = document.getElementById('cam-layer-menu');
  let camLayerInputs = Array.from(document.querySelectorAll('[data-cam-layer]'));
  const innerCopperLayers = document.getElementById('inner-copper-layers');
  const reworkGuide = document.getElementById('rework-guide');
  const guideWorkspace = document.getElementById('guide-workspace');
  const guideListNode = document.getElementById('guide-list');
  const guideView = document.getElementById('guide-view');
  const guideBack = document.getElementById('guide-back');
  const guideTab = document.getElementById('guide-tab');
  const partsTab = document.getElementById('parts-tab');
  const assemblyPanel = document.getElementById('assembly-panel');
  const bomList = document.getElementById('bom-list');
  const assemblySearch = document.getElementById('assembly-search');
  const showDnp = document.getElementById('show-dnp');
  const searchResults = document.getElementById('search-results');
  const selection = document.getElementById('selection');
  const selectionNet = document.getElementById('selection-net');
  const selectionDatasheets = document.getElementById('selection-datasheets');
  const endpointList = document.getElementById('endpoint-list');
  const typeFilters = document.getElementById('type-filters');
  const allKinds = ['ref', 'net', 'section', 'subcircuit', 'component', 'value', 'mpn', 'testpoint'];
  const kindLabels = {
    bom: 'BOM line',
    ref: 'Refdes',
    net: 'Net',
    section: 'Section',
    subcircuit: 'Sub-circuit',
    component: 'Component',
    value: 'Value',
    mpn: 'MPN',
    testpoint: 'Test point'
  };
  let activeKinds = new Set(allKinds);
  let selected = null;
  let boardSide = 'top';
  let boardRotation = 0;
  let modelsEnabled = false;
  let camReviewRequested = new URLSearchParams(window.location.search).get('cam') === '1';
  let camReviewActive = false;
  let camReviewLoading = false;
  let camReviewError = '';
  let activeGuideFocus = null;
  const guides = Array.isArray(model.guides) ? model.guides : [];
  let openGuideIndex = -1;
  const partSides = new Map();
  const assemblyKeyboard = {
    input: assemblySearch,
    list: assemblyPanel,
    selector: '.result-item',
    index: -1,
    prefix: 'assembly-option'
  };

  function unique(values) {
    return Array.from(new Set((values || []).filter(Boolean)));
  }

  function replaceUrl(url) {
    try { history.replaceState(null, '', url); } catch (_) {}
  }

  function leaf(value) {
    const pieces = String(value || '').split('/');
    return pieces[pieces.length - 1];
  }

  function displayLabel(item) {
    return item && (item.type === 'ref' || item.type === 'testpoint') ? leaf(item.label) : item.label;
  }

  // Every datasheet declared by the parts behind `refs`, in BOM order and
  // deduplicated — a group's PDFs come from its component, so two refs of one
  // part number contribute the same sheet once.
  function datasheetsForRefs(refs) {
    const wanted = new Set((refs || []).map((ref) => String(ref).toLowerCase()));
    const found = [];
    (model.bom || []).forEach((group) => {
      const hit = (group.refs || []).some((ref) => wanted.has(String(ref).toLowerCase()));
      if (!hit) return;
      (group.datasheets || []).forEach((sheet) => {
        if (sheet && found.indexOf(sheet) < 0) found.push(sheet);
      });
    });
    return found;
  }

  function datasheetHref(sheet) {
    return /^https?:\/\//i.test(sheet) ? sheet : `/datasheets/${encodeURIComponent(sheet)}`;
  }

  // Render local sheets through /datasheets/<file> and HTTP(S) sheets directly. The
  // click is stopped from reaching an enclosing result row so opening a PDF
  // never doubles as a selection change.
  function datasheetLinks(sheets) {
    const host = document.createElement('span');
    host.className = 'result-datasheets';
    (sheets || []).forEach((sheet) => {
      const link = document.createElement(standalone ? 'span' : 'a');
      link.className = 'datasheet-link';
      if (!standalone) {
        link.href = datasheetHref(sheet);
        link.target = '_blank';
        link.rel = 'noopener noreferrer';
        link.title = `Open ${sheet}`;
      } else {
        link.title = `${sheet} — datasheet reference from the frozen release`;
      }
      link.textContent = `📄 ${sheet}`;
      link.addEventListener('click', (event) => event.stopPropagation());
      host.appendChild(link);
    });
    return host;
  }

  function netKey(value) {
    return String(value || '').trim().split('.', 1)[0].toLowerCase();
  }

  function netsForRefs(refs) {
    const wanted = new Set((refs || []).map((ref) => String(ref).toLowerCase()));
    return (model.nets || [])
      .filter((net) => (net.endpoints || []).some((endpoint) => wanted.has(String(endpoint.ref).toLowerCase())))
      .map((net) => net.name);
  }

  function parkSelection() {
    if (sidebarPanel && selection.parentNode !== sidebarPanel) sidebarPanel.appendChild(selection);
  }

  // Scroll `row` into view only when it is not already fully visible in the
  // sidebar. A row the reader just clicked is visible by definition, so this
  // is a no-op for sidebar clicks and a minimal nudge for board/deep-link
  // selections that land off-screen.
  function revealRow(row) {
    if (!row || !sidebarPanel) return;
    const rowBox = row.getBoundingClientRect();
    const panelBox = sidebarPanel.getBoundingClientRect();
    if (rowBox.top >= panelBox.top && rowBox.bottom <= panelBox.bottom) return;
    row.scrollIntoView({ block: 'nearest', inline: 'nearest' });
  }

  function placeSelection(row, scroll) {
    if (!row) {
      parkSelection();
      return;
    }
    row.after(selection);
    if (scroll) revealRow(row);
  }

  function keyboardRows(state) {
    return Array.from(state.list.querySelectorAll(state.selector));
  }

  function setKeyboardActive(state, index, scroll) {
    const rows = keyboardRows(state);
    if (!rows.length || index < 0) index = -1;
    else index = (index + rows.length) % rows.length;
    state.index = index;
    rows.forEach((row, rowIndex) => {
      if (!row.id) row.id = `${state.prefix}-${rowIndex}`;
      row.classList.toggle('keyboard-active', rowIndex === index);
    });
    if (index < 0) {
      state.input.removeAttribute('aria-activedescendant');
      return;
    }
    state.input.setAttribute('aria-activedescendant', rows[index].id);
    if (scroll) rows[index].scrollIntoView({ block: 'nearest', inline: 'nearest' });
  }

  function handleSearchKey(state, event) {
    const rows = keyboardRows(state);
    if (!rows.length) return;
    if (event.key === 'ArrowDown') {
      event.preventDefault();
      setKeyboardActive(state, state.index < 0 ? 0 : state.index + 1, true);
    } else if (event.key === 'ArrowUp') {
      event.preventDefault();
      setKeyboardActive(state, state.index < 0 ? rows.length - 1 : state.index - 1, true);
    } else if (event.key === 'Enter' && state.index >= 0) {
      event.preventDefault();
      rows[state.index].click();
    } else if (event.key === 'Escape') {
      setKeyboardActive(state, -1, false);
    }
  }

  function beginSearch(state, render) {
    if (selected) clearSelection(false);
    state.index = state.input.value.trim() ? 0 : -1;
    render();
  }

  function focusMessage(refs, nets, fit, kind, pins, context) {
    if (!frame || !frame.contentWindow) return;
    frame.contentWindow.postMessage({
      type: 'netlisp-pcb-focus',
      refs: unique(refs),
      nets: unique(nets),
      pins: pins || [],
      side: boardSide,
      kind: kind || '',
      fit: fit !== false,
      context: context === true
    }, messageTargetOrigin);
  }

  function refocusForBoardSide() {
    if (activeGuideFocus) {
      focusMessage(
        activeGuideFocus.refs,
        activeGuideFocus.nets,
        false,
        activeGuideFocus.type,
        activeGuideFocus.pins,
        activeGuideFocus.type !== 'net'
      );
      return;
    }
    if (!selected) return;
    const nets = selected.type === 'net' ? selected.nets : [];
    focusMessage(selected.refs, nets, false, selected.type);
  }

  function requestBoardParts() {
    if (!frame || !frame.contentWindow) return;
    // The iframe and shell are same-origin. Read its one physical layer table
    // directly once available; unlike the message request this also works when
    // iframe load and listener installation happen in either order.
    try {
      const innerLayers = frame.contentWindow.PCBReviewInnerLayers;
      if (typeof innerLayers === 'function') populateInnerCopperLayers(innerLayers());
    } catch (_) {}
    frame.contentWindow.postMessage({ type: 'netlisp-pcb-parts-request' }, messageTargetOrigin);
  }

  function showWorkspacePanel(name) {
    const showGuide = name === 'guide' && guideWorkspace;
    if (guideWorkspace) guideWorkspace.hidden = !showGuide;
    if (assemblyPanel) assemblyPanel.hidden = Boolean(showGuide);
    [[guideTab, Boolean(showGuide)], [partsTab, !showGuide]].forEach(([tab, active]) => {
      if (!tab) return;
      tab.classList.toggle('active', active);
      tab.setAttribute('aria-selected', active ? 'true' : 'false');
    });
  }

  function guideRefMatches(value) {
    const wanted = String(value || '').trim().toLowerCase();
    const candidates = (model.entities || []).filter((entity) =>
      entity.type === 'ref' || entity.type === 'testpoint');
    const exact = candidates.filter((entity) => String(entity.label).toLowerCase() === wanted);
    const matches = exact.length ? exact : candidates.filter((entity) => leaf(entity.label).toLowerCase() === wanted);
    return matches.length === 1 ? unique(matches.flatMap((entity) => entity.refs || [])) : [];
  }

  function guideUuidMatches(value) {
    const wanted = String(value || '').trim().toLowerCase();
    const matches = (model.parts || []).filter((part) =>
      String(part.uuid || '').toLowerCase() === wanted);
    return matches.length === 1 ? [matches[0].ref] : [];
  }

  function guideNetMatch(value) {
    const wanted = String(value || '').trim();
    const exact = (model.entities || []).find((entity) =>
      entity.type === 'net' && String(entity.label).toLowerCase() === wanted.toLowerCase());
    if (exact) return exact.label;
    const matches = (model.entities || []).filter((entity) =>
      entity.type === 'net' && leaf(entity.label).toLowerCase() === wanted.toLowerCase());
    return matches.length === 1 ? matches[0].label : '';
  }

  function resolveGuideTarget(type, rawValue) {
    const value = String(rawValue || '').trim();
    if (!value) return null;
    if (type === 'uuid') {
      const refs = guideUuidMatches(value);
      return refs.length ? { type, value, refs, nets: [], pins: [] } : null;
    }
    if (type === 'ref') {
      const refs = guideRefMatches(value);
      return refs.length ? { type, value, refs, nets: [], pins: [] } : null;
    }
    if (type === 'pin') {
      const separator = value.lastIndexOf('.');
      if (separator <= 0 || separator === value.length - 1) return null;
      const identity = value.slice(0, separator).trim();
      const pad = value.slice(separator + 1).trim();
      const refs = guideUuidMatches(identity);
      if (!refs.length) refs.push(...guideRefMatches(identity));
      if (!refs.length || !pad) return null;
      return { type, value, refs, nets: [], pins: refs.map((matchedRef) => ({ ref: matchedRef, pad })) };
    }
    if (type === 'net') {
      const net = guideNetMatch(value);
      return net ? { type, value, refs: [], nets: [net], pins: [] } : null;
    }
    return null;
  }

  function orientToGuideTarget(target) {
    if (!target || !target.refs || !target.refs.length) return;
    const sides = new Set(target.refs.map((ref) => partSides.get(String(ref).toLowerCase())).filter(Boolean));
    if (sides.size !== 1) return;
    const side = Array.from(sides)[0];
    if (side === boardSide) return;
    boardSide = side;
    applyBoardOrientation(true);
  }

  function setGuideTargetUrl(target) {
    const url = new URL(window.location.href);
    url.searchParams.delete('type');
    url.searchParams.delete('q');
    const open = openGuideIndex >= 0 ? String(guides[openGuideIndex].slug || '') : '';
    if (open) url.searchParams.set('guide', open);
    else url.searchParams.delete('guide');
    if (target) url.searchParams.set('target', `${target.type}:${target.value}`);
    else url.searchParams.delete('target');
    replaceUrl(url);
  }

  function clearGuideTarget() {
    activeGuideFocus = null;
    document.querySelectorAll('.guide-target.active').forEach((node) => node.classList.remove('active'));
  }

  function activateGuideTarget(target, button, updateUrl) {
    clearSelection(false);
    activeGuideFocus = target;
    document.querySelectorAll('.guide-target.active').forEach((node) => node.classList.remove('active'));
    button.classList.add('active');
    orientToGuideTarget(target);
    focusMessage(target.refs, target.nets, true, target.type, target.pins, target.type !== 'net');
    if (updateUrl !== false) setGuideTargetUrl(target);
  }

  function appendGuideText(host, text) {
    String(text || '').split(/(`[^`]*`)/g).filter(Boolean).forEach((piece) => {
      if (piece.length >= 2 && piece[0] === '`' && piece[piece.length - 1] === '`') {
        const code = document.createElement('code');
        code.textContent = piece.slice(1, -1);
        host.appendChild(code);
      } else {
        host.appendChild(document.createTextNode(piece));
      }
    });
  }

  function appendGuideInline(host, text) {
    const pattern = /\[\[(uuid|ref|pin|net):([^|\]]+)(?:\|([^\]]+))?\]\]/gi;
    let offset = 0;
    let match;
    while ((match = pattern.exec(text)) !== null) {
      appendGuideText(host, text.slice(offset, match.index));
      const type = match[1].toLowerCase();
      const value = match[2].trim();
      const target = resolveGuideTarget(type, value);
      const button = document.createElement('button');
      button.type = 'button';
      button.className = `guide-target guide-target-${type}`;
      button.textContent = (match[3] || value).trim();
      button.dataset.target = `${type}:${value}`.toLowerCase();
      if (target) {
        button.title = type === 'pin' ? `Show ${value} on the board` : `Show ${type} ${value} on the board`;
        button.addEventListener('click', () => activateGuideTarget(target, button, true));
      } else {
        button.disabled = true;
        button.title = `No unique board target matches ${type}:${value}`;
      }
      host.appendChild(button);
      offset = pattern.lastIndex;
    }
    appendGuideText(host, text.slice(offset));
  }

  function renderGuide(body) {
    if (!reworkGuide) return;
    reworkGuide.replaceChildren();
    const lines = String(body || '').replace(/\r/g, '').split('\n');
    let paragraph = [];
    let list = null;
    let code = null;

    function flushParagraph() {
      if (!paragraph.length) return;
      const p = document.createElement('p');
      appendGuideInline(p, paragraph.join(' '));
      reworkGuide.appendChild(p);
      paragraph = [];
    }

    function endList() {
      list = null;
    }

    lines.forEach((line) => {
      if (code) {
        if (/^\s*```/.test(line)) {
          const pre = document.createElement('pre');
          const block = document.createElement('code');
          block.textContent = code.join('\n');
          pre.appendChild(block);
          reworkGuide.appendChild(pre);
          code = null;
        } else {
          code.push(line);
        }
        return;
      }
      if (/^\s*```/.test(line)) {
        flushParagraph();
        endList();
        code = [];
        return;
      }
      if (!line.trim()) {
        flushParagraph();
        endList();
        return;
      }
      const heading = /^(#{1,4})\s+(.+)$/.exec(line);
      if (heading) {
        flushParagraph();
        endList();
        const h = document.createElement(`h${heading[1].length}`);
        appendGuideInline(h, heading[2]);
        reworkGuide.appendChild(h);
        return;
      }
      if (/^\s*(---+|\*\*\*+)\s*$/.test(line)) {
        flushParagraph();
        endList();
        reworkGuide.appendChild(document.createElement('hr'));
        return;
      }
      const bullet = /^\s*[-*]\s+(.+)$/.exec(line);
      const numbered = /^\s*\d+\.\s+(.+)$/.exec(line);
      if (bullet || numbered) {
        flushParagraph();
        const kind = numbered ? 'ol' : 'ul';
        if (!list || list.tagName.toLowerCase() !== kind) {
          list = document.createElement(kind);
          reworkGuide.appendChild(list);
        }
        const item = document.createElement('li');
        appendGuideInline(item, (bullet || numbered)[1]);
        list.appendChild(item);
        return;
      }
      const quote = /^\s*>\s?(.*)$/.exec(line);
      if (quote) {
        flushParagraph();
        endList();
        const callout = document.createElement('aside');
        callout.className = 'guide-callout';
        appendGuideInline(callout, quote[1]);
        reworkGuide.appendChild(callout);
        return;
      }
      endList();
      paragraph.push(line.trim());
    });
    flushParagraph();
    if (code) {
      const pre = document.createElement('pre');
      const block = document.createElement('code');
      block.textContent = code.join('\n');
      pre.appendChild(block);
      reworkGuide.appendChild(pre);
    }

    const help = document.createElement('details');
    help.className = 'guide-dsl-help';
    const summary = document.createElement('summary');
    summary.textContent = 'Interactive target syntax';
    const example = document.createElement('code');
    example.textContent = '[[uuid:<component UUID>|R44]]  [[pin:<component UUID>.1|R44 pad 1]]  [[net:LMX_VTUNE]]';
    help.append(summary, example);
    reworkGuide.appendChild(help);
  }

  function guideLabel(guide, index) {
    const title = String((guide && guide.title) || '').trim();
    if (title) return title;
    return String((guide && guide.slug) || '') || `Guide ${index + 1}`;
  }

  function renderGuideList() {
    if (!guideListNode) return;
    guideListNode.replaceChildren();
    guides.forEach((guide, index) => {
      const row = document.createElement('button');
      row.type = 'button';
      row.className = 'guide-list-item';
      row.dataset.slug = String(guide.slug || '');
      const title = document.createElement('span');
      title.className = 'guide-list-title';
      title.textContent = guideLabel(guide, index);
      const slug = document.createElement('span');
      slug.className = 'guide-list-slug';
      slug.textContent = `${String(guide.slug || '')}.rework.md`;
      row.append(title, slug);
      row.addEventListener('click', () => openGuide(index, true));
      guideListNode.appendChild(row);
    });
  }

  // Render one guide in place of the list. Every guide shares the article and
  // the renderer, so its targets resolve exactly as a single guide's did.
  // `.rework-guide` never scrolls itself — the sidebar panel is the scroller —
  // so a newly opened guide is rewound there.
  function openGuide(index, updateUrl) {
    const guide = guides[index];
    if (!guide || !reworkGuide) return;
    openGuideIndex = index;
    renderGuide(guide.body);
    if (guideListNode) guideListNode.hidden = true;
    if (guideView) guideView.hidden = false;
    if (sidebarPanel) sidebarPanel.scrollTop = 0;
    if (updateUrl === false) return;
    // Rewriting the URL drops its `type`/`q` selection keys, so the selection
    // they describe goes with them — the same pairing showGuideList makes.
    clearSelection(false);
    setGuideTargetUrl(null);
  }

  function guideButtonFor(dataTarget) {
    if (!reworkGuide) return null;
    return Array.from(reworkGuide.querySelectorAll('.guide-target')).find((candidate) =>
      candidate.dataset.target === dataTarget && !candidate.disabled) || null;
  }

  // A deep-linked target names no guide, so open each one until its button
  // appears; a target nothing owns leaves the panel exactly as it was found.
  function findGuideButton(dataTarget) {
    if (!reworkGuide || !guides.length) return null;
    const started = openGuideIndex;
    if (started >= 0) {
      const current = guideButtonFor(dataTarget);
      if (current) return current;
    }
    for (let index = 0; index < guides.length; index += 1) {
      openGuide(index, false);
      const button = guideButtonFor(dataTarget);
      if (button) return button;
    }
    // Nothing owns it: restore the panel and leave the URL alone, so a link
    // that failed once is still the link the reader can retry or report.
    if (started >= 0) openGuide(started, false);
    else closeGuide();
    return null;
  }

  function closeGuide() {
    openGuideIndex = -1;
    if (reworkGuide) reworkGuide.replaceChildren();
    if (guideView) guideView.hidden = true;
    if (guideListNode) guideListNode.hidden = false;
  }

  function showGuideList() {
    closeGuide();
    clearSelection(false);
    setGuideTargetUrl(null);
  }

  function applyBoardOrientation(updateUrl) {
    if (!frame) return;
    if (frame.contentWindow) {
      frame.contentWindow.postMessage({
        type: 'netlisp-pcb-orientation',
        side: boardSide,
        rotation: boardRotation
      }, messageTargetOrigin);
    }
    if (boardSideButton) {
      boardSideButton.textContent = boardSide === 'bottom' ? 'Bottom side' : 'Top side';
      boardSideButton.title = boardSide === 'bottom' ? 'Switch to top-side view' : 'Switch to bottom-side view';
      boardSideButton.setAttribute('aria-pressed', boardSide === 'bottom' ? 'true' : 'false');
    }
    if (boardOrientation) {
      boardOrientation.textContent = `${boardSide === 'bottom' ? 'Bottom' : 'Top'} · ${boardRotation}°`;
    }
    if (updateUrl) {
      const url = new URL(window.location.href);
      if (boardSide === 'bottom') url.searchParams.set('board_side', 'bottom');
      else url.searchParams.delete('board_side');
      if (boardRotation) url.searchParams.set('board_rotation', String(boardRotation));
      else url.searchParams.delete('board_rotation');
      replaceUrl(url);
    }
  }

  function rotateBoard(delta) {
    boardRotation = (boardRotation + delta + 360) % 360;
    applyBoardOrientation(true);
  }

  function restoreBoardOrientation() {
    const params = new URLSearchParams(window.location.search);
    boardSide = params.get('board_side') === 'bottom' ? 'bottom' : 'top';
    const rawRotation = Number.parseInt(params.get('board_rotation') || '0', 10);
    boardRotation = Number.isFinite(rawRotation) ? ((Math.round(rawRotation / 90) * 90) % 360 + 360) % 360 : 0;
    applyBoardOrientation(false);
  }

  function setModelsEnabled(enabled, updateUrl) {
    modelsEnabled = Boolean(enabled);
    if (load3dModels) load3dModels.checked = modelsEnabled;
    if (frame) {
      const url = new URL(frame.src, window.location.href);
      const currentlyEnabled = url.searchParams.get('model_sprites') === '1';
      url.searchParams.set('drc', '0');
      if (modelsEnabled) url.searchParams.set('model_sprites', '1');
      else url.searchParams.delete('model_sprites');
      if (currentlyEnabled !== modelsEnabled) frame.src = url.toString();
    }
    if (updateUrl) {
      const url = new URL(window.location.href);
      if (modelsEnabled) url.searchParams.set('models', '1');
      else url.searchParams.delete('models');
      replaceUrl(url);
    }
  }

  function restoreModelLoading() {
    const params = new URLSearchParams(window.location.search);
    setModelsEnabled(params.get('models') === '1', false);
  }

  function syncCamReviewControl() {
    const detail = camReviewError || (camReviewActive
      ? 'Return to the fast semantic Assembly board'
      : 'Load and inspect the exact generated Gerber and Excellon files');
    if (camReviewButton) {
      camReviewButton.disabled = camReviewLoading;
      camReviewButton.textContent = camReviewLoading
        ? 'Loading CAM…'
        : (camReviewActive ? 'Exit CAM Review' : (camReviewError ? 'Retry CAM Review' : 'CAM Review'));
      camReviewButton.setAttribute('aria-pressed', camReviewActive ? 'true' : 'false');
      camReviewButton.setAttribute('aria-busy', camReviewLoading ? 'true' : 'false');
      camReviewButton.title = detail;
    }
    if (camReviewStatus) {
      const state = camReviewLoading ? 'loading' : (camReviewActive ? 'active' : (camReviewError ? 'error' : 'semantic'));
      camReviewStatus.dataset.state = state;
      camReviewStatus.textContent = state === 'loading' ? 'Generating Gerbers…'
        : (state === 'active' ? 'Exact CAM active' : (state === 'error' ? 'CAM failed — click Retry' : 'Fast board'));
      camReviewStatus.title = detail;
    }
    if (camLayerMenu) {
      camLayerMenu.hidden = !camReviewActive;
      if (!camReviewActive) camLayerMenu.open = false;
    }
  }

  function postCamReviewRequest() {
    if (!frame || !frame.contentWindow) return;
    try {
      if (typeof frame.contentWindow.PCBReviewCamMode === 'function') {
        frame.contentWindow.PCBReviewCamMode(camReviewRequested);
        return;
      }
    } catch (_) {}
    frame.contentWindow.postMessage({
      type: 'netlisp-pcb-cam-mode',
      enabled: camReviewRequested
    }, messageTargetOrigin);
  }

  function setCamReviewRequested(enabled, updateUrl) {
    camReviewRequested = Boolean(enabled);
    camReviewError = '';
    if (!camReviewRequested) camReviewActive = false;
    camReviewLoading = camReviewRequested && !camReviewActive;
    syncCamReviewControl();
    postCamReviewRequest();
    if (updateUrl) {
      const url = new URL(window.location.href);
      if (camReviewRequested) url.searchParams.set('cam', '1');
      else url.searchParams.delete('cam');
      replaceUrl(url);
    }
  }

  function camLayerState() {
    const state = {};
    camLayerInputs.forEach((input) => { state[input.dataset.camLayer] = input.checked; });
    return state;
  }

  function savedCamLayers() {
    try { return JSON.parse(localStorage.getItem(`assembly-cam-layers:${model.name || ''}`) || 'null'); } catch (_) {}
    return null;
  }

  function restoreCamLayerInputs(saved) {
    if (!saved || typeof saved !== 'object') return;
    camLayerInputs.forEach((input) => {
      const key = input.dataset.camLayer;
      if (typeof saved[key] === 'boolean') input.checked = saved[key];
      // Migrate the former all-inner toggle without retaining it as a second
      // visibility control. Once saved again, every inner layer has own state.
      else if (key.indexOf('copper-inner-') === 0 && typeof saved.inner_copper === 'boolean') {
        input.checked = saved.inner_copper;
      }
    });
  }

  function populateInnerCopperLayers(layers) {
    if (!innerCopperLayers || !Array.isArray(layers)) return;
    innerCopperLayers.textContent = '';
    layers.forEach((layer) => {
      if (!layer || !layer.id || !layer.name) return;
      const label = document.createElement('label');
      const input = document.createElement('input');
      input.type = 'checkbox';
      input.dataset.camLayer = String(layer.id);
      input.addEventListener('change', () => applyCamLayers(true));
      label.appendChild(input);
      label.appendChild(document.createTextNode(` ${layer.name}`));
      innerCopperLayers.appendChild(label);
    });
    camLayerInputs = Array.from(document.querySelectorAll('[data-cam-layer]'));
    restoreCamLayerInputs(savedCamLayers());
    applyCamLayers(false);
  }

  function applyCamLayers(persist) {
    if (frame && frame.contentWindow) {
      frame.contentWindow.postMessage({
        type: 'netlisp-pcb-cam-visibility',
        layers: camLayerState()
      }, messageTargetOrigin);
    }
    if (persist) {
      try { localStorage.setItem(`assembly-cam-layers:${model.name || ''}`, JSON.stringify(camLayerState())); } catch (_) {}
    }
  }

  function restoreCamLayers() {
    restoreCamLayerInputs(savedCamLayers());
    applyCamLayers(false);
  }

  function setUrl(type, query) {
    const url = new URL(window.location.href);
    url.searchParams.delete('mode');
    url.searchParams.delete('target');
    if (type && query) {
      url.searchParams.set('type', type);
      url.searchParams.set('q', query);
    } else {
      url.searchParams.delete('type');
      url.searchParams.delete('q');
    }
    replaceUrl(url);
  }

  function clearSelection(updateUrl) {
    selected = null;
    clearGuideTarget();
    selection.hidden = true;
    selectionNet.hidden = true;
    selectionDatasheets.hidden = true;
    selectionDatasheets.replaceChildren();
    parkSelection();
    endpointList.replaceChildren();
    setKeyboardActive(assemblyKeyboard, -1, false);
    document.querySelectorAll('.result-item.selected').forEach((node) => node.classList.remove('selected'));
    markExactRef(null, null);
    focusMessage([], [], false);
    if (updateUrl !== false) setUrl('', '');
  }

  function endpointRows(nets) {
    const names = new Set(nets || []);
    const rows = [];
    (model.nets || []).forEach((net) => {
      if (!names.has(net.name)) return;
      (net.endpoints || []).forEach((endpoint) => rows.push(Object.assign({ net: net.name }, endpoint)));
    });
    return rows;
  }

  function renderEndpoints(nets) {
    endpointList.replaceChildren();
    const rows = endpointRows(nets);
    if (!rows.length) return;
    const heading = document.createElement('h3');
    heading.textContent = 'Connections';
    endpointList.appendChild(heading);
    const table = document.createElement('table');
    table.className = 'endpoint-table';
    table.innerHTML = '<thead><tr><th>Ref</th><th>Pad</th><th>Part</th><th>Net</th></tr></thead>';
    const body = document.createElement('tbody');
    rows.forEach((row) => {
      const tr = document.createElement('tr');
      [leaf(row.ref), row.pin, [row.component, row.value].filter(Boolean).join(' · '), row.net].forEach((text) => {
        const td = document.createElement('td');
        td.textContent = text || '—';
        tr.appendChild(td);
      });
      body.appendChild(tr);
    });
    table.appendChild(body);
    endpointList.appendChild(table);
  }

  function selectItem(item, sourceNode, queryType, queryValue, fit, applyFocus) {
    const shouldFit = fit === undefined ? item.type !== 'bom' : fit;
    clearGuideTarget();
    setKeyboardActive(assemblyKeyboard, -1, false);
    selected = Object.assign({}, item, { keepFrame: !shouldFit });
    document.querySelectorAll('.result-item.selected').forEach((node) => node.classList.remove('selected'));
    selection.hidden = item.type === 'bom';
    document.getElementById('selection-kind').textContent = kindLabels[item.type] || item.type || 'Selection';
    document.getElementById('selection-title').textContent = displayLabel(item);
    document.getElementById('selection-detail').textContent = item.detail || '';
    const testPointNets = item.type === 'testpoint' ? unique(item.nets) : [];
    selectionNet.hidden = !testPointNets.length;
    selectionNet.textContent = testPointNets.length ? `Net: ${testPointNets.join(', ')}` : '';
    renderEndpoints(item.type === 'net' ? item.nets : []);
    const sheets = datasheetsForRefs(item.refs);
    selectionDatasheets.replaceChildren();
    selectionDatasheets.hidden = !sheets.length;
    if (sheets.length) selectionDatasheets.appendChild(datasheetLinks(sheets));
    if (!sourceNode && item.type === 'bom' && item.bomKey) {
      sourceNode = bomList.querySelector(`.bom-row[data-key="${CSS.escape(item.bomKey)}"]`);
    } else if (!sourceNode && item.type !== 'bom') {
      assemblySearch.value = item.label;
      renderLists();
      sourceNode = searchRowForItem(item);
    }
    if (sourceNode) sourceNode.classList.add('selected');
    markExactRef(sourceNode, item.exactRef);
    if (item.type === 'bom') {
      parkSelection();
      revealRow(sourceNode);
    } else {
      placeSelection(sourceNode, Boolean(sourceNode));
    }
    if (applyFocus !== false) focusMessage(item.refs, item.type === 'net' ? item.nets : [], shouldFit, item.type);
    setUrl(queryType || item.type, queryValue || item.bomKey || item.label);
  }

  function bomItem(group) {
    const hidden = showDnp.checked ? new Set() : new Set(group.dnp_refs || []);
    const refs = (group.refs || []).filter((ref) => !hidden.has(ref));
    return {
      type: 'bom',
      label: group.mpn || group.value || group.component || 'Unidentified part',
      detail: [group.manufacturer, group.component, group.value, group.footprint].filter(Boolean).join(' · '),
      refs,
      nets: netsForRefs(refs),
      bomKey: group.key
    };
  }

  function visibleQty(group) {
    return Math.max(0, Number(group.qty || 0) - (showDnp.checked ? 0 : Number(group.dnp_count || 0)));
  }

  function groupSide(group) {
    const sides = new Set((group.refs || []).map((ref) => partSides.get(String(ref).toLowerCase())).filter(Boolean));
    if (sides.has('top') && sides.has('bottom')) return 'both';
    if (sides.has('bottom')) return 'bottom';
    if (sides.has('top')) return 'top';
    return '';
  }

  function hasSelectedText(row) {
    const textSelection = window.getSelection && window.getSelection();
    if (!textSelection || textSelection.isCollapsed || !textSelection.rangeCount) return false;
    return row.contains(textSelection.getRangeAt(0).commonAncestorContainer);
  }

  function markExactRef(row, exactRef) {
    document.querySelectorAll('.result-ref.exact-selected').forEach((node) => {
      node.classList.remove('exact-selected');
      node.removeAttribute('aria-current');
    });
    if (!row || !exactRef) return;
    const wanted = String(exactRef).toLowerCase();
    row.querySelectorAll('.result-ref').forEach((node) => {
      const exact = String(node.dataset.ref || '').toLowerCase() === wanted;
      node.classList.toggle('exact-selected', exact);
      if (exact) node.setAttribute('aria-current', 'true');
    });
  }

  function renderBom() {
    const query = (assemblySearch.value || '').trim().toLowerCase();
    if (bomList.contains(selection)) parkSelection();
    bomList.replaceChildren();
    let visibleParts = 0;
    let visibleGroups = 0;
    const compareGroups = (a, b, qtyFor) => {
      const qtyOrder = qtyFor(b) - qtyFor(a);
      if (qtyOrder) return qtyOrder;
      const aName = a.mpn || a.value || a.component || '';
      const bName = b.mpn || b.value || b.component || '';
      return aName.localeCompare(bName, undefined, { numeric: true, sensitivity: 'base' });
    };
    const kitOrder = (model.bom || []).slice().sort((a, b) => compareGroups(
      a,
      b,
      (group) => Math.max(0, Number(group.qty || 0) - Number(group.dnp_count || 0))
    ));
    const kitNumberByKey = new Map(kitOrder.map((group, index) => [group.key, index + 1]));
    const groups = (model.bom || []).slice().sort((a, b) => {
      const qtyOrder = visibleQty(b) - visibleQty(a);
      if (qtyOrder) return qtyOrder;
      const aName = a.mpn || a.value || a.component || '';
      const bName = b.mpn || b.value || b.component || '';
      return aName.localeCompare(bName, undefined, { numeric: true, sensitivity: 'base' });
    });
    groups.forEach((group) => {
      if (!showDnp.checked && group.dnp_count === group.qty) return;
      const haystack = [group.mpn, group.manufacturer, group.component, group.value, group.footprint]
        .concat(group.refs || []).join(' ').toLowerCase();
      if (query && !haystack.includes(query)) return;
      visibleGroups += 1;
      visibleParts += group.qty - (showDnp.checked ? 0 : group.dnp_count);
      const button = document.createElement('div');
      button.className = 'result-item bom-row';
      button.setAttribute('role', 'button');
      button.tabIndex = 0;
      button.dataset.key = group.key;
      const top = document.createElement('span');
      top.className = 'result-top';
      const titleWrap = document.createElement('span');
      titleWrap.className = 'result-title';
      const kitIndex = document.createElement('span');
      kitIndex.className = 'kit-index';
      const kitNumber = kitNumberByKey.get(group.key);
      kitIndex.textContent = `#${kitNumber}`;
      kitIndex.title = `Kit line ${kitNumber}`;
      const title = document.createElement('strong');
      title.textContent = group.mpn || 'MPN missing';
      titleWrap.append(kitIndex, title);
      const qty = document.createElement('span');
      qty.className = 'qty';
      qty.textContent = `×${visibleQty(group)}`;
      const badges = document.createElement('span');
      badges.className = 'result-badges';
      const side = groupSide(group);
      if (side) {
        const sideBadge = document.createElement('span');
        sideBadge.className = `side-badge side-${side}`;
        sideBadge.textContent = side === 'both' ? 'Both' : side[0].toUpperCase() + side.slice(1);
        sideBadge.title = side === 'both' ? 'Placed on top and bottom' : `Placed on the ${side} side`;
        badges.appendChild(sideBadge);
      }
      badges.appendChild(qty);
      top.append(titleWrap, badges);
      const meta = document.createElement('span');
      meta.className = 'result-detail';
      meta.textContent = [group.manufacturer, group.value, group.footprint].filter(Boolean).join(' · ') || group.component;
      const refs = document.createElement('span');
      refs.className = 'result-refs';
      bomItem(group).refs.forEach((ref, refIndex) => {
        if (refIndex) refs.appendChild(document.createTextNode(', '));
        const refNode = document.createElement('span');
        refNode.className = 'result-ref';
        refNode.dataset.ref = ref;
        refNode.textContent = leaf(ref);
        if (selected && selected.exactRef && String(selected.exactRef).toLowerCase() === String(ref).toLowerCase()) {
          refNode.classList.add('exact-selected');
          refNode.setAttribute('aria-current', 'true');
        }
        refs.appendChild(refNode);
      });
      button.append(top, meta, refs);
      if (selected && selected.bomKey === group.key) button.classList.add('selected');
      if (group.dnp_count) {
        const chip = document.createElement('span');
        chip.className = 'warning-chip';
        chip.textContent = `${group.dnp_count} DNP`;
        button.appendChild(chip);
      }
      if (group.conflict) {
        const warning = document.createElement('span');
        warning.className = 'warning-chip conflict';
        warning.textContent = 'Conflicting value, footprint, or manufacturer';
        button.appendChild(warning);
      }
      if ((group.datasheets || []).length) button.appendChild(datasheetLinks(group.datasheets));
      const activate = () => {
        selectItem(bomItem(group), button);
      };
      button.addEventListener('click', () => {
        if (!hasSelectedText(button)) activate();
      });
      button.addEventListener('keydown', (event) => {
        if (event.key !== 'Enter' && event.key !== ' ') return;
        event.preventDefault();
        activate();
      });
      bomList.appendChild(button);
    });
    document.getElementById('bom-summary').textContent = `${visibleGroups} line${visibleGroups === 1 ? '' : 's'} · ` +
      `${visibleParts} placement${visibleParts === 1 ? '' : 's'}`;
    if (!visibleGroups) {
      const empty = document.createElement('p');
      empty.className = 'empty-state';
      empty.textContent = 'No BOM lines match this filter.';
      bomList.appendChild(empty);
    }
    if (selected && selected.type === 'bom' && selected.bomKey) {
      const row = bomList.querySelector(`.bom-row[data-key="${CSS.escape(selected.bomKey)}"]`);
      if (row) placeSelection(row, false);
    }
  }

  function bomGroupForRef(ref) {
    const wanted = String(ref || '').toLowerCase();
    return (model.bom || []).find((group) =>
      (group.refs || []).some((candidate) => String(candidate).toLowerCase() === wanted));
  }

  function bomRowForGroup(group) {
    return Array.from(bomList.querySelectorAll('.bom-row')).find((row) => row.dataset.key === group.key) || null;
  }

  function revealBomPick(group, ref) {
    if (!showDnp.checked && (group.dnp_refs || []).some((candidate) => candidate === ref)) {
      showDnp.checked = true;
      renderBom();
    }
    if (!bomRowForGroup(group) && assemblySearch.value) {
      assemblySearch.value = '';
      renderSearch();
      renderBom();
    }
    const row = bomRowForGroup(group);
    const item = Object.assign(bomItem(group), {
      refs: [ref],
      nets: netsForRefs([ref]),
      exactRef: ref,
      detail: [leaf(ref), group.manufacturer, group.component, group.value, group.footprint].filter(Boolean).join(' · ')
    });
    selectItem(item, row, 'bom', group.key, false, false);
  }

  function revealBoardRef(ref, pickedNet) {
    const entity = (model.entities || []).find((candidate) =>
      (candidate.type === 'ref' || candidate.type === 'testpoint') &&
      String(candidate.label).toLowerCase() === String(ref).toLowerCase());
    if (!entity) return false;
    if (!activeKinds.has(entity.type)) {
      activeKinds.add(entity.type);
      renderTypeFilters();
    }
    assemblySearch.value = ref;
    renderLists();
    const row = Array.from(searchResults.querySelectorAll('.search-row')).find((candidate) =>
      candidate.dataset.type === entity.type && candidate.dataset.label === entity.label) || null;
    const item = Object.assign({}, entity, { nets: unique((entity.nets || []).concat(pickedNet || [])) });
    selectItem(item, row, entity.type, entity.label, false, false);
    return true;
  }

  function scoreEntity(entity, query) {
    const label = entity.label.toLowerCase();
    const leafName = leaf(entity.label).toLowerCase();
    if (label === query || leafName === query) return 0;
    if (label.startsWith(query) || leafName.startsWith(query)) return 1;
    if (label.includes(query)) return 2;
    if ((entity.keywords || '').toLowerCase().includes(query)) return 3;
    return 99;
  }

  function debugMatches(query) {
    const normalized = query.trim().toLowerCase();
    const matches = (model.entities || [])
      .filter((entity) => activeKinds.has(entity.type))
      .map((entity) => ({ entity, score: normalized ? scoreEntity(entity, normalized) : 4 }))
      .filter((match) => match.score < 99)
      .sort((a, b) => a.score - b.score || a.entity.label.localeCompare(b.entity.label, undefined, { numeric: true }))
      .map((match) => match.entity);
    const visible = matches.slice(0, 100);
    if (!normalized && selected && selected.type !== 'bom' && activeKinds.has(selected.type)) {
      const picked = (model.entities || []).find((entity) =>
        entity.type === selected.type && entity.label === selected.label);
      if (picked && !visible.includes(picked)) {
        visible.unshift(picked);
        if (visible.length > 100) visible.pop();
      }
    }
    return visible;
  }

  function searchRowForItem(item) {
    return Array.from(searchResults.querySelectorAll('.search-row')).find((row) =>
      row.dataset.type === item.type && row.dataset.label === item.label) || null;
  }

  function renderSearch() {
    if (searchResults.contains(selection)) parkSelection();
    searchResults.replaceChildren();
    const query = assemblySearch.value || '';
    const matches = query.trim() ? debugMatches(query) : [];
    searchResults.hidden = !matches.length;
    matches.forEach((entity) => {
      const button = document.createElement('button');
      button.type = 'button';
      button.className = 'result-item search-row';
      button.dataset.type = entity.type;
      button.dataset.label = entity.label;
      const top = document.createElement('span');
      top.className = 'result-top';
      const title = document.createElement('strong');
      title.textContent = displayLabel(entity);
      const badge = document.createElement('span');
      badge.className = `kind-badge kind-${entity.type}`;
      badge.textContent = kindLabels[entity.type] || entity.type;
      top.append(title, badge);
      const detail = document.createElement('span');
      detail.className = 'result-detail';
      detail.textContent = entity.detail || `${(entity.refs || []).length} parts`;
      button.append(top, detail);
      button.addEventListener('click', () => selectItem(entity, button));
      searchResults.appendChild(button);
    });
    if (!matches.length) {
      const empty = document.createElement('p');
      empty.className = 'empty-state';
      empty.textContent = 'No matching board objects.';
      searchResults.appendChild(empty);
    }
    if (selected && selected.type !== 'bom') {
      const row = searchRowForItem(selected);
      if (row) {
        row.classList.add('selected');
        placeSelection(row, false);
      }
    }
  }

  function renderLists() {
    renderSearch();
    renderBom();
    setKeyboardActive(assemblyKeyboard, assemblyKeyboard.index, false);
  }

  function renderTypeFilters() {
    typeFilters.replaceChildren();
    allKinds.forEach((kind) => {
      const label = document.createElement('label');
      label.className = 'type-filter';
      const input = document.createElement('input');
      input.type = 'checkbox';
      input.checked = activeKinds.has(kind);
      input.addEventListener('change', () => {
        if (input.checked) activeKinds.add(kind); else activeKinds.delete(kind);
        assemblyKeyboard.index = assemblySearch.value.trim() ? 0 : -1;
        renderLists();
      });
      label.append(input, document.createTextNode(kindLabels[kind]));
      typeFilters.appendChild(label);
    });
  }

  function restoreDeepLink() {
    const params = new URLSearchParams(window.location.search);
    const requested = params.get('guide');
    if (requested && guides.length) {
      const index = guides.findIndex((guide) => String(guide.slug || '') === requested);
      if (index >= 0) {
        showWorkspacePanel('guide');
        openGuide(index, false);
      }
    }
    const guideTarget = params.get('target');
    if (guideTarget && reworkGuide) {
      // A target names no guide, so open each in turn until one owns it — the
      // article always holds exactly the guide whose button we hand back.
      const found = findGuideButton(guideTarget.toLowerCase());
      if (found) {
        const separator = guideTarget.indexOf(':');
        const target = separator > 0
          ? resolveGuideTarget(guideTarget.slice(0, separator).toLowerCase(), guideTarget.slice(separator + 1))
          : null;
        if (target) {
          showWorkspacePanel('guide');
          activateGuideTarget(target, found, false);
          return;
        }
      }
    }
    const type = params.get('type');
    const query = params.get('q');
    if (!type || !query) return;
    if (type === 'bom') {
      const group = (model.bom || []).find((candidate) => candidate.key === query);
      if (group) selectItem(bomItem(group), null, type, query);
      return;
    }
    if (type === 'mpn') {
      const group = (model.bom || []).find((candidate) =>
        candidate.mpn && candidate.mpn.toLowerCase() === query.toLowerCase());
      if (group) selectItem(bomItem(group), null, type, query);
      return;
    }
    const entity = (model.entities || []).find((candidate) =>
      candidate.type === type && candidate.label.toLowerCase() === query.toLowerCase());
    if (entity) {
      assemblySearch.value = query;
      renderLists();
      selectItem(entity, null, type, query);
    }
  }

  if (boardSideButton) boardSideButton.addEventListener('click', () => {
    boardSide = boardSide === 'bottom' ? 'top' : 'bottom';
    applyBoardOrientation(true);
    refocusForBoardSide();
  });
  if (boardRotateLeft) boardRotateLeft.addEventListener('click', () => rotateBoard(-90));
  if (boardRotateRight) boardRotateRight.addEventListener('click', () => rotateBoard(90));
  if (load3dModels) load3dModels.addEventListener('change', () => {
    setModelsEnabled(load3dModels.checked, true);
  });
  if (camReviewButton) camReviewButton.addEventListener('click', () => {
    setCamReviewRequested(!camReviewActive, true);
  });
  camLayerInputs.forEach((input) => input.addEventListener('change', () => applyCamLayers(true)));
  if (guideTab) guideTab.addEventListener('click', () => showWorkspacePanel('guide'));
  if (guideBack) guideBack.addEventListener('click', showGuideList);
  if (partsTab) partsTab.addEventListener('click', () => {
    showWorkspacePanel('parts');
    if (activeGuideFocus) clearSelection(true);
  });
  assemblySearch.addEventListener('input', () => beginSearch(assemblyKeyboard, renderLists));
  assemblySearch.addEventListener('keydown', (event) => handleSearchKey(assemblyKeyboard, event));
  window.addEventListener('keydown', (event) => {
    if (event.key !== 'Escape') return;
    event.preventDefault();
    clearSelection(true);
  });
  showDnp.addEventListener('change', () => {
    renderLists();
    if (!selected || !selected.bomKey) return;
    const group = (model.bom || []).find((candidate) => candidate.key === selected.bomKey);
    if (group) selectItem(bomItem(group), null);
  });
  document.getElementById('clear-selection').addEventListener('click', () => clearSelection(true));
  frame.addEventListener('load', () => {
    requestBoardParts();
    applyBoardOrientation(false);
    applyCamLayers(false);
    setCamReviewRequested(camReviewRequested, false);
    if (activeGuideFocus) {
      focusMessage(
        activeGuideFocus.refs,
        activeGuideFocus.nets,
        true,
        activeGuideFocus.type,
        activeGuideFocus.pins
      );
    } else if (selected) {
      const nets = selected.type === 'net' ? selected.nets : [];
      focusMessage(selected.refs, nets, !selected.keepFrame, selected.type);
    }
  });
  window.addEventListener('message', (event) => {
    if ((!standalone && event.origin !== window.location.origin) || event.source !== frame.contentWindow) return;
    const payload = event.data || {};
    if (payload.type === 'netlisp-pcb-cam-state') {
      if (payload.state === 'loading') {
        camReviewError = '';
        camReviewLoading = true;
      } else if (payload.state === 'active') {
        camReviewError = '';
        camReviewRequested = true;
        camReviewActive = true;
        camReviewLoading = false;
      } else if (payload.state === 'semantic') {
        if (camReviewRequested) return;
        camReviewActive = false;
        camReviewLoading = false;
      } else if (payload.state === 'error') {
        camReviewError = payload.detail || 'The exact CAM view could not be loaded.';
        camReviewRequested = false;
        camReviewActive = false;
        camReviewLoading = false;
        const url = new URL(window.location.href);
        url.searchParams.delete('cam');
        replaceUrl(url);
      }
      syncCamReviewControl();
      return;
    }
    if (payload.type === 'netlisp-pcb-parts') {
      populateInnerCopperLayers(payload.innerLayers);
      partSides.clear();
      (payload.parts || []).forEach((part) => {
        if (!part || !part.ref) return;
        partSides.set(String(part.ref).toLowerCase(), part.side === 'bottom' ? 'bottom' : 'top');
      });
      if (activeGuideFocus) orientToGuideTarget(activeGuideFocus);
      renderLists();
      return;
    }
    if (payload.type === 'netlisp-pcb-ref-picked') {
      const pickedSide = payload.side === 'bottom' || payload.side === 'top'
        ? payload.side
        : partSides.get(String(payload.ref || '').toLowerCase());
      if (pickedSide && pickedSide !== boardSide) return;
      showWorkspacePanel('parts');
      const group = bomGroupForRef(payload.ref);
      if (group) {
        revealBomPick(group, payload.ref);
      } else {
        revealBoardRef(payload.ref, payload.net);
      }
      return;
    }
    if (payload.type === 'netlisp-pcb-net-picked') {
      if (payload.clear) {
        clearSelection(true);
        return;
      }
      const picked = (model.entities || []).find((entity) =>
        entity.type === 'net' && netKey(entity.label) === netKey(payload.net));
      if (picked) {
        showWorkspacePanel('parts');
        selectItem(picked, null, 'net', picked.label, false, false);
      }
      return;
    }
  });

  restoreBoardOrientation();
  restoreModelLoading();
  syncCamReviewControl();
  restoreCamLayers();
  requestBoardParts();
  renderGuideList();
  // One guide opens straight away — the list is still a click behind the back
  // control, so the single-guide page reads the same as it always did.
  if (guides.length === 1) openGuide(0, false);
  showWorkspacePanel('parts');
  renderTypeFilters();
  renderLists();
  restoreDeepLink();
})();
