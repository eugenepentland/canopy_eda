// Board Review Card view for /review/:name.
//
// The page shell (src/serve/review_card_page.zig) paints immediately; this
// script fetches GET /api/review-card/<design>[?layout=] and lays the card
// out. Everything on the page comes from that ONE document, so what a reviewer
// reads here, what `netlisp review-card` prints and what the committed Board
// Review Audit says cannot disagree.
//
// The card is expensive to compose (release preflight, ERC, fabrication gate,
// DRC, thermal screen), so the wait is narrated rather than hidden: never a
// blank page.
(function () {
  "use strict";

  // The seven-word verdict vocabulary, spelled as review_registry.Verdict
  // tags it in JSON, in the order a reviewer triages.
  var VERDICTS = ["fail", "not_declared", "unproven", "manual", "waived", "pass", "not_applicable"];
  var LABEL = {
    pass: "pass",
    fail: "fail",
    unproven: "unproven",
    waived: "waived",
    not_applicable: "n/a",
    not_declared: "not declared",
    manual: "manual"
  };
  // Stripe order reads best-to-worst left to right; triage order is above.
  var STRIPE_ORDER = ["pass", "waived", "manual", "unproven", "not_declared", "fail", "not_applicable"];

  var card = null;
  var rowIndex = [];
  var activeFilter = "all";
  var anchored = {};

  function $(sel) {
    return document.querySelector(sel);
  }
  function el(tag, cls, text) {
    var node = document.createElement(tag);
    if (cls) node.className = cls;
    if (text !== undefined && text !== null && text !== "") node.textContent = String(text);
    return node;
  }
  function label(verdict) {
    return LABEL[verdict] || verdict || "unknown";
  }
  function pill(verdict) {
    return el("span", "pill v-" + (verdict || "not_applicable"), label(verdict));
  }
  function fact(name, value, cls) {
    var box = el("div", cls ? "fact " + cls : "fact");
    box.append(el("small", null, name), el("strong", null, value === "" ? "—" : value));
    return box;
  }
  function worstOf(stripe) {
    var order = ["fail", "not_declared", "unproven", "manual", "waived", "pass"];
    for (var i = 0; i < order.length; i++) if ((stripe[order[i]] || 0) > 0) return order[i];
    return "not_applicable";
  }
  function stripeNode(stripe) {
    var wrap = el("div", "stripe");
    var any = false;
    STRIPE_ORDER.forEach(function (verdict) {
      var count = stripe[verdict] || 0;
      if (!count) return;
      any = true;
      var seg = el("span", "stripe-seg v-" + verdict, count + " " + label(verdict));
      seg.style.flexGrow = String(count);
      wrap.append(seg);
    });
    if (!any) wrap.append(el("span", "stripe-empty", "no rows"));
    return wrap;
  }
  function shortToken(token) {
    if (!token) return "—";
    return token.length > 12 ? token.slice(0, 12) + "…" : token;
  }
  function celsius(value) {
    return (typeof value === "number" ? value.toFixed(0) : "?") + " °C";
  }

  // ---- Header --------------------------------------------------------

  // Where the screening ambient came from is a row of the card itself
  // (thermal-brief-ambient), so the header quotes the engine rather than
  // re-deriving the provenance here.
  function ambientProvenance() {
    var row = findRow("thermal-brief-ambient");
    return row ? row.result : "no ambient-provenance row in this card";
  }
  function findRow(id) {
    var found = null;
    (card.categories || []).forEach(function (category) {
      (category.rows || []).forEach(function (row) {
        if (!found && row.id === id) found = row;
      });
    });
    return found;
  }
  function renderHead() {
    var host = $("#card-head");
    if (!host) return;
    host.replaceChildren();
    var identity = card.identity || {};
    var digests = card.digests || {};
    var overall = card.overall || {};
    var stripe = overall.stripe || {};

    var line = el("div", "card-idline");
    line.append(el("h2", null, identity.name || card.design || "board"));
    line.append(pill(overall.verdict));
    line.append(el("span", "stripe-empty", (stripe.total || 0) + " registered checks"));
    host.append(line);

    var facts = el("div", "card-facts");
    facts.append(fact("Revision", identity.revision || "—"));
    facts.append(fact("Part number", identity.part_number || "—"));
    facts.append(fact("Layout", identity.layout || "—"));
    facts.append(fact("Release token", shortToken(digests.release_token)));
    facts.append(fact("Blocking", String(overall.blocking || 0), (overall.blocking || 0) > 0 ? "blocking" : ""));
    facts.append(fact("Waivable", String(overall.waivable || 0)));
    facts.append(fact("Advisory", String(overall.advisory || 0)));
    facts.append(fact("Releasable", overall.releasable ? "yes" : "no", overall.releasable ? "releasable" : "not-releasable"));
    host.append(facts);
    host.append(stripeNode(stripe));

    var ambient = el("p", "card-ambient");
    ambient.textContent = "Thermal screen at " + celsius(card.ambient_c) + " — " + ambientProvenance();
    host.append(ambient);
  }
  function renderLegend() {
    var host = $("#card-legend");
    if (!host) return;
    host.replaceChildren();
    host.append(el("span", null, "Verdicts:"));
    VERDICTS.forEach(function (verdict) {
      host.append(el("span", "pill v-" + verdict, label(verdict)));
    });
  }

  // ---- Categories ----------------------------------------------------

  function recordCell(row) {
    var node = el("span", "row-record");
    var text = "closed by " + row.record;
    if (/^https?:\/\//.test(row.record)) {
      var link = el("a", null, text);
      link.href = row.record;
      node.append(link);
    } else node.textContent = text;
    return node;
  }
  function rowNode(row) {
    var tr = el("tr", "card-row");
    tr.dataset.verdict = row.verdict;
    tr.dataset.id = row.id;
    // The same registry id can judge many subjects; the first one carries the
    // #row-<id> anchor the reference view links to.
    if (!anchored[row.id]) {
      anchored[row.id] = true;
      tr.id = "row-" + row.id;
    }
    var check = el("td", "col-check");
    check.append(el("code", "row-id", row.id));
    check.append(el("span", "row-policy " + (row.policy || ""), row.policy || ""));
    var subject = el("td", "col-subject");
    subject.append(el("span", "row-scope", row.scope || ""));
    subject.append(el("span", "row-subject", row.subject || ""));
    var result = el("td", "col-result", row.result || "");
    var verdict = el("td", "col-verdict");
    verdict.append(pill(row.verdict));
    var evidence = el("td", "col-evidence");
    evidence.append(el("span", "row-evidence", row.evidence || ""));
    if (row.record) evidence.append(recordCell(row));
    var closes = el("td", "col-closes");
    closes.append(el("code", "closes-with", row.closes_with || "—"));
    tr.append(check, subject, result, verdict, evidence, closes);
    rowIndex.push({
      tr: tr,
      verdict: row.verdict,
      text: [row.id, row.scope, row.subject, row.result, row.evidence, row.closes_with, row.record]
        .join(" ").toLowerCase()
    });
    return tr;
  }
  function headerRow() {
    var tr = el("tr");
    ["Check", "Scope / subject", "Result", "Verdict", "Evidence", "Closes with"].forEach(function (name) {
      tr.append(el("th", null, name));
    });
    var head = el("thead");
    head.append(tr);
    return head;
  }
  function categoryCard(category) {
    var box = el("details", "cat-card");
    box.dataset.key = category.key;
    var stripe = category.stripe || {};
    var summary = el("summary");
    summary.append(el("h2", "cat-title", category.title || category.key));
    summary.append(pill(worstOf(stripe)));
    summary.append(stripeNode(stripe));
    box.append(summary);
    var wrap = el("div", "rows-wrap");
    var table = el("table", "rows-table");
    table.append(headerRow());
    var body = el("tbody");
    (category.rows || []).forEach(function (row) {
      body.append(rowNode(row));
    });
    table.append(body);
    wrap.append(table);
    box.append(wrap);
    return box;
  }
  function renderCategories() {
    var host = $("#card-categories");
    if (!host) return;
    host.replaceChildren();
    rowIndex = [];
    anchored = {};
    (card.categories || []).forEach(function (category) {
      var box = categoryCard(category);
      box.open = (category.stripe || {}).fail > 0;
      host.append(box);
    });
  }

  // ---- Parts, fabrication gate, ladder --------------------------------

  function chipLabel(chip) {
    return (chip.pass || 0) + " ✓ · " + (chip.unproven || 0) + " ◐ · " +
      (chip.fail || 0) + " ✗ · " + (chip.not_declared || 0) + " ?";
  }
  function chipLink(part) {
    // The BOM tab's spec sheet is the part's whole contract; the card's chip is
    // the same counts, so it sends the reader there rather than repeating it.
    var link = el("a", "chip-link v-" + (part.verdict || "not_applicable"), chipLabel(part.chip || {}));
    link.href = "/schematics/" + encodeURIComponent(DESIGN_NAME) + "#page-bom";
    link.title = "Open the schematic BOM spec sheet for " + part.ref;
    return link;
  }
  function block(hostSelector, title) {
    var host = $(hostSelector);
    if (!host) return null;
    host.replaceChildren();
    host.append(el("h2", null, title));
    var body = el("div", "block-body");
    host.append(body);
    return body;
  }
  function renderParts() {
    var body = block("#card-parts", "Parts (" + (card.parts || []).length + ")");
    if (!body) return;
    var table = el("table", "parts-table");
    var head = el("tr");
    ["Ref", "Component", "Class", "Review", "Checks", "Electrical", "Unmet", "Chip"].forEach(function (name) {
      head.append(el("th", null, name));
    });
    var thead = el("thead");
    thead.append(head);
    table.append(thead);
    var tbody = el("tbody");
    (card.parts || []).forEach(function (part) {
      var tr = el("tr");
      tr.dataset.ref = part.ref;
      tr.append(el("td", "col-ref", part.ref));
      tr.append(el("td", null, part.component || ""));
      tr.append(el("td", null, part.class || ""));
      tr.append(el("td", null, part.review || ""));
      tr.append(el("td", null, part.checks || ""));
      tr.append(el("td", null, part.electrical || ""));
      tr.append(el("td", null, part.unmet || ""));
      var chip = el("td");
      chip.append(chipLink(part));
      tr.append(chip);
      tbody.append(tr);
    });
    table.append(tbody);
    body.append(table);
  }
  function idList(ids, cls) {
    var wrap = el("div", "id-list");
    if (!ids || !ids.length) {
      wrap.append(el("span", null, "none"));
      return wrap;
    }
    ids.forEach(function (id) {
      wrap.append(el("span", cls, id));
    });
    return wrap;
  }
  function renderFab() {
    var fab = card.fab || {};
    var body = block("#card-fab", "Fabrication gate");
    if (!body) return;
    var kv = el("div", "kv");
    kv.append(fact("Gate", fab.available ? (fab.ok ? "clear" : "blocked") : "unavailable",
      fab.available && fab.ok ? "releasable" : "not-releasable"));
    kv.append(fact("Needs waiver", fab.needs_waiver ? "yes" : "no"));
    var stats = fab.stats || {};
    ["parts", "nets", "routable", "connected", "tracks", "vias", "dnp"].forEach(function (key) {
      kv.append(fact(key, String(stats[key] || 0)));
    });
    body.append(kv);
    body.append(el("strong", null, "Errors"));
    body.append(idList(fab.errors, "v-fail"));
    body.append(el("strong", null, "Warnings"));
    body.append(idList(fab.warnings, "v-unproven"));
  }
  function renderLadder() {
    var layout = card.layout || {};
    var body = block("#card-ladder", "Layout ladder and DRC");
    if (!body) return;
    var kv = el("div", "kv");
    kv.append(fact("Layout", layout.available ? "available" : "none"));
    kv.append(fact("DRC errors", String(layout.drc_errors || 0), (layout.drc_errors || 0) > 0 ? "blocking" : ""));
    kv.append(fact("DRC warnings", String(layout.drc_warnings || 0)));
    body.append(kv);
    var stages = el("div", "kv");
    (layout.ladder || []).forEach(function (stage) {
      stages.append(fact(stage.id, stage.status + " " + (stage.done || 0) + "/" + (stage.total || 0)));
    });
    body.append(stages);
    if ((layout.by_kind || []).length) {
      body.append(el("strong", null, "DRC findings by kind"));
      var kinds = el("div", "kv");
      (layout.by_kind || []).forEach(function (entry) {
        kinds.append(fact(entry.kind, String(entry.count || 0)));
      });
      body.append(kinds);
    }
  }

  // ---- Filters and search ---------------------------------------------

  function applyFilters() {
    var input = $("#card-search");
    var term = input && input.value ? input.value.trim().toLowerCase() : "";
    var visible = 0;
    rowIndex.forEach(function (entry) {
      var byVerdict = activeFilter === "all" || entry.verdict === activeFilter;
      var byTerm = !term || entry.text.indexOf(term) >= 0;
      entry.tr.hidden = !(byVerdict && byTerm);
      if (!entry.tr.hidden) visible += 1;
    });
    var cards = Array.prototype.slice.call(document.querySelectorAll(".cat-card"));
    cards.forEach(function (box) {
      var rows = Array.prototype.slice.call(box.querySelectorAll(".card-row"));
      var shown = rows.some(function (tr) {
        return !tr.hidden;
      });
      box.hidden = !shown;
      if (shown && (term || activeFilter !== "all")) box.open = true;
    });
    var empty = $("#card-empty");
    if (empty) empty.hidden = visible !== 0;
    return visible;
  }
  function setFilter(name) {
    activeFilter = name;
    Array.prototype.slice.call(document.querySelectorAll(".card-toolbar .filter")).forEach(function (button) {
      if (button.dataset.filter === name) button.classList.add("active");
      else button.classList.remove("active");
    });
    return applyFilters();
  }
  function setSearch(term) {
    var input = $("#card-search");
    if (input) input.value = term;
    return applyFilters();
  }
  function openAll(open) {
    Array.prototype.slice.call(document.querySelectorAll(".cat-card")).forEach(function (box) {
      box.open = open;
    });
  }
  function focusHash() {
    var hash = (typeof location !== "undefined" && location.hash) || "";
    if (hash.indexOf("#row-") !== 0) return false;
    var target = document.getElementById(hash.slice(1));
    if (!target) return false;
    var box = target.parentNode;
    while (box && box.className !== "cat-card") box = box.parentNode;
    if (box) box.open = true;
    if (target.scrollIntoView) target.scrollIntoView();
    return true;
  }
  function wire() {
    var search = $("#card-search");
    if (search) search.addEventListener("input", applyFilters);
    Array.prototype.slice.call(document.querySelectorAll(".card-toolbar .filter")).forEach(function (button) {
      button.addEventListener("click", function () {
        setFilter(button.dataset.filter);
      });
    });
    var expand = $("#card-expand");
    if (expand) expand.addEventListener("click", function () {
      openAll(true);
    });
    var collapse = $("#card-collapse");
    if (collapse) collapse.addEventListener("click", function () {
      openAll(false);
    });
    if (typeof window !== "undefined" && window.addEventListener) {
      window.addEventListener("hashchange", focusHash);
    }
  }

  // ---- Load ------------------------------------------------------------

  function setState(text) {
    var node = $("#card-state");
    if (node) node.textContent = text;
  }
  function renderCard(value) {
    card = value;
    renderHead();
    renderLegend();
    renderCategories();
    renderParts();
    renderFab();
    renderLadder();
    applyFilters();
    focusHash();
    setState("Card current");
    return card;
  }
  function failed(error) {
    var host = $("#card-head");
    if (host) {
      host.replaceChildren();
      host.append(el("p", "card-error", "The Board Review Card could not be composed: " + error));
    }
    setState("Card unavailable");
  }
  function cardUrl() {
    var url = "/api/review-card/" + encodeURIComponent(DESIGN_NAME);
    if (typeof LAYOUT === "string" && LAYOUT) url += "?layout=" + encodeURIComponent(LAYOUT);
    return url;
  }
  function tick(started) {
    var node = $("#card-progress");
    if (!node) return;
    var seconds = Math.round((Date.now() - started) / 1000);
    node.textContent = "Composing the Board Review Card — release checks, fabrication gate, DRC and " +
      "thermal screen — " + seconds + "s so far.";
  }
  function load() {
    var started = Date.now();
    var timer = null;
    if (typeof setInterval === "function") {
      timer = setInterval(function () {
        tick(started);
      }, 1000);
    }
    setState("Composing…");
    return fetch(cardUrl(), { headers: { accept: "application/json" } })
      .then(function (response) {
        return response.json().then(function (value) {
          if (!response.ok) throw new Error(value.error || "HTTP " + response.status);
          return value;
        });
      })
      .then(function (value) {
        return renderCard(value);
      })
      .catch(function (error) {
        failed(error && error.message ? error.message : String(error));
        return null;
      })
      .then(function (value) {
        if (timer !== null && typeof clearInterval === "function") clearInterval(timer);
        return value;
      });
  }
  function boot() {
    if (!$("#card-categories")) return Promise.resolve(null);
    wire();
    return load();
  }

  var api = {
    boot: boot,
    load: load,
    renderCard: renderCard,
    applyFilters: applyFilters,
    setFilter: setFilter,
    setSearch: setSearch,
    openAll: openAll,
    focusHash: focusHash,
    rows: function () {
      return rowIndex;
    }
  };
  if (typeof window !== "undefined") window.NETLISP_REVIEW_CARD = api;
  api.ready = boot();
})();
