// /thermal/:name — the thermal review page's client.
//
// Two jobs, and deliberately nothing else. Dependency-free, like every other
// viewer here.
//
//  1. COOLING SCENARIO is a local switch. The server rendered one per-part table
//     per rung into the document, so picking a rung is a `hidden` flip on those
//     sections, a class flip on the ladder row and the segmented button, and one
//     postMessage to the board frame. No round trip for this page.
//
//     The board itself is the live PCB viewer in an iframe (pcb_thermal.js),
//     which paints the field as an overlay. It answers with a `thermal:state`
//     message carrying the payload it drew from, and the hotspot readout and
//     "solving" veil beside it are filled from THAT — never from a second fetch,
//     which is how the two halves could come to show different scenarios. The
//     legend starts at 25–125 °C and lets the reader change either endpoint;
//     that rebuilds only the field's pixels and contours, never the solve.
//
//  2. AMBIENT re-renders on the server. One fetch of this page's own
//     `?fragment=1`, whose body is exactly the two ambient-dependent regions
//     (#tp-verdict and #tp-tables). The facts JSON at /api/thermal/<name>
//     carries numbers and not prose, and re-deriving the verdict sentence here
//     is precisely how this page would come to disagree with the review panel
//     and the PDF — so the sentences stay where review_thermal.zig builds them.
//
//  3. COMPARING LAYOUTS is one fetch per board. Picking a board from the layout
//     menu is a plain navigation (the whole page, the board frame included,
//     describes a different board afterwards). The compare table's rows are
//     each a whole board solve, so they are fetched ONE AT A TIME — on a click,
//     or by a sweep the reader starts and can stop. Nothing is capped and
//     nothing is solved behind the reader's back: a design with fifty saved
//     layouts is fifty solves, and it should be the reader who spends them.
//
// Every handler is delegated off #tp-page, so a swapped-in fragment needs no
// rebinding. Picking a part row also announces it on the shared cross-probe
// channel, so a /pcb-layout or /schematics window open beside this one
// highlights the same part.
(function () {
  "use strict";
  var page = document.getElementById("tp-page");
  if (!page) return;

  var NAME = page.getAttribute("data-name") || "";
  // The saved layout on screen, empty for the design's default board. Every
  // fetch and every link this file builds carries it: a page that screens one
  // board must not link to another one's numbers.
  var LAYOUT = page.getAttribute("data-layout") || "";
  var scenario = page.getAttribute("data-scenario") || "natural";
  var ambient = parseFloat(page.getAttribute("data-ambient"));
  if (!isFinite(ambient)) ambient = 25;
  var SCALE_DEFAULT_MIN_C = 25;
  var SCALE_DEFAULT_MAX_C = 125;
  var scaleMinC = SCALE_DEFAULT_MIN_C;
  var scaleMaxC = SCALE_DEFAULT_MAX_C;
  var boardSide = "top";
  var view3d = false;
  try {
    var openingUrl = new URL(window.location.href);
    boardSide = openingUrl.searchParams.get("board_side") === "bottom" ? "bottom" : "top";
    view3d = openingUrl.searchParams.get("view") === "3d";
    var openingMinC = parseFloat(openingUrl.searchParams.get("scale_min"));
    var openingMaxC = parseFloat(openingUrl.searchParams.get("scale_max"));
    if (isFinite(openingMinC) && isFinite(openingMaxC) && openingMaxC > openingMinC) {
      scaleMinC = openingMinC;
      scaleMaxC = openingMaxC;
    }
  } catch (e) {}

  var frame = document.getElementById("tp-frame");
  var veil = document.getElementById("tp-heat-loading");
  var hotspotOut = document.getElementById("tp-hotspot");
  var labelsBox = document.getElementById("tp-labels");
  var opacityBox = document.getElementById("tp-opacity");
  var scaleMinInput = document.getElementById("tp-scale-min");
  var scaleMaxInput = document.getElementById("tp-scale-max");
  var status = document.getElementById("tp-status");
  var ambientInput = document.getElementById("tp-ambient");
  var jsonLink = document.getElementById("tp-json");
  var layoutSel = document.getElementById("tp-layout");
  var faceButtons = page.querySelectorAll("[data-board-side]");
  var viewButtons = page.querySelectorAll("[data-board-view]");

  function enc(s) { return encodeURIComponent(s); }
  function layoutParam() { return LAYOUT ? "&layout=" + enc(LAYOUT) : ""; }
  function scaleParam() {
    if (scaleMinC === SCALE_DEFAULT_MIN_C && scaleMaxC === SCALE_DEFAULT_MAX_C) return "";
    return "&scale_min=" + enc(String(scaleMinC)) + "&scale_max=" + enc(String(scaleMaxC));
  }
  function compareOpen() {
    var d = document.getElementById("tp-compare");
    return !!(d && d.open);
  }

  // ---- The board frame ----------------------------------------------------
  // The frame owns the picture; this page owns the words beside it. General
  // state crosses by message; scale changes also use the same-origin redraw
  // seam so an input gesture updates pixels synchronously.
  function tell(msg) {
    if (!frame || !frame.contentWindow) return;
    msg.t = "thermal:view";
    try { frame.contentWindow.postMessage(msg, "*"); } catch (e) { /* frame not ready yet */ }
  }
  function scalePush() {
    if (!frame || !frame.contentWindow) return;
    // Same-origin direct call gives the number inputs a synchronous redraw.
    // The message remains the loading-order fallback and keeps the frame's
    // public message contract usable when it is opened by another parent.
    try {
      var thermal = frame.contentWindow.PCBThermal;
      if (thermal && typeof thermal.setScale === "function") thermal.setScale(scaleMinC, scaleMaxC);
    } catch (e) { /* frame still navigating */ }
    tell({ scaleMinC: scaleMinC, scaleMaxC: scaleMaxC });
  }
  function scaleSet(updateUrl) {
    if (!scaleMinInput || !scaleMaxInput) return;
    var nextMinC = parseFloat(scaleMinInput.value);
    var nextMaxC = parseFloat(scaleMaxInput.value);
    var valid = isFinite(nextMinC) && isFinite(nextMaxC) && nextMaxC > nextMinC;
    scaleMinInput.setCustomValidity(valid ? "" : "Minimum must be below maximum");
    scaleMaxInput.setCustomValidity(valid ? "" : "Maximum must be above minimum");
    scaleMinInput.setAttribute("aria-invalid", valid ? "false" : "true");
    scaleMaxInput.setAttribute("aria-invalid", valid ? "false" : "true");
    if (!valid) return;
    scaleMinC = nextMinC;
    scaleMaxC = nextMaxC;
    scalePush();
    if (updateUrl) syncUrl();
  }
  function orientBoard() {
    if (!frame || !frame.contentWindow) return;
    try {
      frame.contentWindow.postMessage({
        type: "netlisp-pcb-orientation", side: boardSide, rotation: 0
      }, window.location.origin);
    } catch (e) { /* frame not ready yet */ }
  }
  function tellBoardView() {
    if (!frame || !frame.contentWindow) return;
    try {
      frame.contentWindow.postMessage({
        type: "netlisp-pcb-view", view: view3d ? "3d" : "2d"
      }, window.location.origin);
    } catch (e) { /* frame not ready yet */ }
  }
  function viewButtonsSync() {
    var selected = view3d ? "3d" : boardSide;
    for (var i = 0; i < viewButtons.length; i++) {
      var on = viewButtons[i].getAttribute("data-board-view") === selected;
      viewButtons[i].classList.toggle("on", on);
      viewButtons[i].setAttribute("aria-pressed", on ? "true" : "false");
    }
  }
  function boardSideSet(next, updateUrl) {
    boardSide = next === "bottom" ? "bottom" : "top";
    view3d = false;
    page.setAttribute("data-board-side", boardSide);
    viewButtonsSync();
    tellBoardView();
    orientBoard();
    tell({ side: boardSide });
    if (updateUrl) syncUrl();
  }
  function setupViewSet(updateUrl) {
    view3d = true;
    viewButtonsSync();
    tellBoardView();
    if (updateUrl) syncUrl();
  }
  function heatRefresh() {
    if (!frame) return;
    if (veil) { veil.hidden = false; veil.textContent = "Solving…"; }
    tell({
      scenario: scenario, ambient: ambient, side: boardSide,
      scaleMinC: scaleMinC, scaleMaxC: scaleMaxC
    });
  }
  window.addEventListener("message", function (ev) {
    var d = ev.data;
    if (frame && ev.source !== frame.contentWindow) return;
    if (d && d.type === "netlisp-pcb-ref-picked") {
      tell({ selectedRef: d.ref || "" });
      return;
    }
    if (!d || d.t !== "thermal:state") return;
    if (veil) {
      veil.hidden = !d.loading && !d.error && !d.unavailable;
      if (d.error) veil.textContent = "Heat map unavailable";
      else if (d.unavailable) veil.textContent = d.unavailable;
      else if (d.loading) veil.textContent = "Solving…";
    }
    if (d.loading) return;
    if (hotspotOut && d.hotspot) {
      hotspotOut.textContent = "Hotspot " + d.hotspot.c.toFixed(1) + " °C at " +
        d.hotspot.x_mm.toFixed(1) + ", " + d.hotspot.y_mm.toFixed(1) + " mm" +
        (d.converged === false ? " (did not converge)" : "");
    }
  });
  // The frame loads with the solve inputs in its own URL. On load it still
  // needs the display-only range, and this also covers a browser Back reload.
  if (frame) frame.addEventListener("load", function () {
    orientBoard();
    tellBoardView();
    tell({
      scenario: scenario, ambient: ambient, side: boardSide,
      scaleMinC: scaleMinC, scaleMaxC: scaleMaxC
    });
  });
  for (var f = 0; f < faceButtons.length; f++) {
    faceButtons[f].addEventListener("click", function () { boardSideSet(this.getAttribute("data-board-side"), true); });
  }
  var setupButton = document.getElementById("tp-view-3d");
  if (setupButton) setupButton.addEventListener("click", function () { setupViewSet(true); });
  if (view3d) setupViewSet(false); else boardSideSet(boardSide, false);
  if (labelsBox) labelsBox.addEventListener("change", function () { tell({ labels: labelsBox.checked }); });
  if (opacityBox) {
    opacityBox.addEventListener("input", function () { tell({ opacity: parseInt(opacityBox.value, 10) / 100 }); });
  }
  if (scaleMinInput && scaleMaxInput) {
    scaleMinInput.value = String(scaleMinC);
    scaleMaxInput.value = String(scaleMaxC);
    scaleMinInput.addEventListener("input", function () { scaleSet(true); });
    scaleMaxInput.addEventListener("input", function () { scaleSet(true); });
  }

  // ---- Scenario selection (local) ----------------------------------------
  function tpSelect(next) {
    if (!next || next === scenario) return;
    scenario = next;
    page.setAttribute("data-scenario", scenario);
    applyScenario();
    heatRefresh();
    syncUrl();
  }
  function applyScenario() {
    var btns = page.querySelectorAll(".tp-seg-btn");
    for (var i = 0; i < btns.length; i++) {
      var on = btns[i].getAttribute("data-scenario") === scenario;
      btns[i].classList.toggle("on", on);
      btns[i].setAttribute("aria-pressed", on ? "true" : "false");
    }
    var rows = page.querySelectorAll(".tp-lrow");
    for (var r = 0; r < rows.length; r++) {
      rows[r].classList.toggle("sel", rows[r].getAttribute("data-scenario") === scenario);
    }
    var tables = page.querySelectorAll(".tp-parts");
    for (var t = 0; t < tables.length; t++) {
      tables[t].hidden = tables[t].getAttribute("data-scenario") !== scenario;
    }
  }

  // ---- Ambient (one server round trip) -----------------------------------
  var pending = null, seq = 0;
  function ambientSet(next) {
    if (!isFinite(next) || next === ambient) return;
    ambient = next;
    page.setAttribute("data-ambient", String(ambient));
    if (jsonLink) {
      jsonLink.setAttribute("href", "/api/thermal/" + enc(NAME) + "?ambient=" + enc(String(ambient)) + layoutParam());
    }
    heatRefresh();
    syncUrl();
    if (pending) window.clearTimeout(pending);
    pending = window.setTimeout(reload, 320);
  }
  function reload() {
    var mine = ++seq;
    if (status) { status.hidden = false; status.textContent = "Screening at " + ambient + " °C…"; }
    // The compare table comes back unsolved, which is the honest answer: those
    // temperatures were read at the OLD ambient and every one of them moved.
    var url = "/thermal/" + enc(NAME) + "?fragment=1&ambient=" + enc(String(ambient)) +
      "&scenario=" + enc(scenario) + layoutParam() + (compareOpen() ? "&compare=1" : "");
    window.fetch(url, { credentials: "same-origin" }).then(function (res) {
      if (!res.ok) throw new Error("HTTP " + res.status);
      return res.text();
    }).then(function (html) {
      if (mine !== seq) return; // a newer ambient already won
      var box = document.createElement("div");
      box.innerHTML = html;
      swap(box, "tp-verdict");
      swap(box, "tp-tables");
      applyScenario();
      sweeping = false;
      compareProgress();
      if (status) status.hidden = true;
    }).catch(function (e) {
      if (mine !== seq) return;
      if (status) { status.hidden = false; status.textContent = "Could not re-screen: " + (e && e.message ? e.message : e); }
    });
  }
  function swap(box, id) {
    var src = box.querySelector("#" + id);
    var dst = id === "tp-verdict" ? document.getElementById("tp-verdict") : document.getElementById("tp-tables");
    if (src && dst) dst.innerHTML = src.innerHTML;
  }
  if (ambientInput) {
    ambientInput.addEventListener("change", function () { ambientSet(parseFloat(ambientInput.value)); });
    ambientInput.addEventListener("input", function () { ambientSet(parseFloat(ambientInput.value)); });
  }

  // Keep the address bar reproducing what is on screen, so a link to this page
  // opens the same rung at the same ambient.
  function syncUrl() {
    try {
      var u = new URL(window.location.href);
      u.searchParams.set("ambient", String(ambient));
      u.searchParams.set("scenario", scenario);
      if (boardSide === "bottom") u.searchParams.set("board_side", "bottom");
      else u.searchParams.delete("board_side");
      if (view3d) u.searchParams.set("view", "3d");
      else u.searchParams.delete("view");
      if (scaleMinC === SCALE_DEFAULT_MIN_C && scaleMaxC === SCALE_DEFAULT_MAX_C) {
        u.searchParams.delete("scale_min");
        u.searchParams.delete("scale_max");
      } else {
        u.searchParams.set("scale_min", String(scaleMinC));
        u.searchParams.set("scale_max", String(scaleMaxC));
      }
      if (LAYOUT) u.searchParams.set("layout", LAYOUT); else u.searchParams.delete("layout");
      if (compareOpen()) u.searchParams.set("compare", "1"); else u.searchParams.delete("compare");
      window.history.replaceState(null, "", u.toString());
    } catch (e) { /* older browser: the page still works, the link is just plain */ }
  }

  // ---- Board selection (a navigation) ------------------------------------
  // Not a fragment swap: the board frame, the heat image, the part table and
  // every cross-probe link on the page describe a different board afterwards,
  // and re-fetching them piecemeal is how two halves of one page come to show
  // two different boards.
  if (layoutSel) {
    layoutSel.addEventListener("change", function () {
      var next = layoutSel.value || "";
      if (next === LAYOUT) return;
      try {
        var u = new URL(window.location.href);
        if (next) u.searchParams.set("layout", next); else u.searchParams.delete("layout");
        u.searchParams.set("ambient", String(ambient));
        u.searchParams.set("scenario", scenario);
        if (compareOpen()) u.searchParams.set("compare", "1");
        window.location.href = u.toString();
      } catch (e) {
        window.location.href = "/thermal/" + enc(NAME) + "?ambient=" + enc(String(ambient)) +
          "&scenario=" + enc(scenario) + (boardSide === "bottom" ? "&board_side=bottom" : "") +
          (next ? "&layout=" + enc(next) : "") + scaleParam();
      }
    });
  }

  // ---- Comparing layouts (one fetch per board) ---------------------------
  // Each row is a whole second solve of a whole second board. They are filled
  // one at a time so the page stays answerable while a sweep runs, and the
  // sweep can be stopped mid-way — a half-filled table is a real answer, a
  // frozen tab is not.
  var sweeping = false;
  var goBtn = document.getElementById("tp-cgo");
  var progOut = document.getElementById("tp-cprog");

  function compareRows() { return page.querySelectorAll("#tp-crows .tp-crow"); }
  function unsolvedRows() {
    var rows = compareRows(), out = [];
    for (var i = 0; i < rows.length; i++) {
      if (rows[i].querySelector(".tp-cfill")) out.push(rows[i]);
    }
    return out;
  }
  function compareProgress() {
    if (!progOut) return;
    var total = compareRows().length;
    if (!total) return;
    var left = unsolvedRows().length;
    progOut.textContent = sweeping
      ? "Solving… " + (total - left) + " of " + total
      : (left ? (total - left) + " of " + total + " solved" : "All " + total + " solved");
    if (goBtn) goBtn.textContent = sweeping ? "Stop" : (left ? "Solve all" : "Solved");
    if (goBtn) goBtn.disabled = !sweeping && left === 0;
  }

  // One row: the server answers with that board's cells, already differenced
  // against the board on screen. Resolves either way — a sweep must not stop
  // because one layout could not be solved.
  function solveRow(row) {
    var fill = row.querySelector(".tp-cfill");
    if (!fill) return Promise.resolve();
    fill.textContent = "Solving…";
    fill.classList.add("busy");
    var url = "/thermal/" + enc(NAME) + "?row=" + enc(row.getAttribute("data-layout") || "") +
      "&scenario=" + enc(scenario) + "&ambient=" + enc(String(ambient)) + layoutParam();
    return window.fetch(url, { credentials: "same-origin" }).then(function (res) {
      if (!res.ok) throw new Error("HTTP " + res.status);
      return res.text();
    }).then(function (html) {
      fill.outerHTML = html;
    }).catch(function (e) {
      fill.classList.remove("busy");
      fill.textContent = "Could not solve: " + (e && e.message ? e.message : e);
    }).then(function () { compareProgress(); });
  }

  function sweep() {
    var queue = unsolvedRows(), at = 0;
    function step() {
      if (!sweeping || at >= queue.length) { sweeping = false; compareProgress(); return; }
      solveRow(queue[at++]).then(step);
    }
    step();
  }
  if (goBtn) {
    goBtn.addEventListener("click", function () {
      if (sweeping) { sweeping = false; compareProgress(); return; }
      sweeping = true;
      compareProgress();
      sweep();
    });
  }

  // ---- Cross-probe --------------------------------------------------------
  // The same BroadcastChannel the PCB, schematic and editor viewers share. This
  // page only SENDS: `from` is its own kind, which no receiver drops, and there
  // is nothing here to highlight in return.
  var xpc = null;
  try { xpc = new BroadcastChannel("netlisp-xprobe"); } catch (e) { xpc = null; }
  function xpSend(ref) {
    if (!xpc || !ref) return;
    try { xpc.postMessage({ from: "thermal", design: NAME, ref: ref }); } catch (e) { /* channel closed */ }
  }

  // ---- Delegated interaction ---------------------------------------------
  // Bound to #tp-page, which survives every fragment swap.
  page.addEventListener("click", function (ev) {
    var seg = ev.target.closest ? ev.target.closest(".tp-seg-btn") : null;
    if (seg) { tpSelect(seg.getAttribute("data-scenario")); return; }
    var lrow = ev.target.closest ? ev.target.closest(".tp-lrow") : null;
    if (lrow) { tpSelect(lrow.getAttribute("data-scenario")); return; }
    // A link inside a row is a navigation, not a selection.
    if (ev.target.closest && ev.target.closest("a")) return;
    var crow = ev.target.closest ? ev.target.closest(".tp-crow") : null;
    if (crow) { solveRow(crow); return; }
    var prow = ev.target.closest ? ev.target.closest(".tp-prow") : null;
    if (prow) xpSend(prow.getAttribute("data-ref"));
  });
  page.addEventListener("keydown", function (ev) {
    if (ev.key !== "Enter" && ev.key !== " ") return;
    var lrow = ev.target.closest ? ev.target.closest(".tp-lrow") : null;
    if (!lrow) return;
    ev.preventDefault();
    tpSelect(lrow.getAttribute("data-scenario"));
  });

  page.addEventListener("toggle", function (ev) {
    if (ev.target && ev.target.id === "tp-compare") { compareProgress(); syncUrl(); }
  }, true);
  compareProgress();

  // The frame's own URL carries the solve inputs. Its load message above also
  // applies the reader's display-only scale without another solve.
})();
