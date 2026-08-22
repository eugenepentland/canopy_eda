// pcb_route_session.js — interactive routing sessions on the /pcb-layout page.
//
// The user watches the autorouter work on the REAL board; when it gets stuck
// it surfaces the evidence (a search-frontier heatmap + a blocker list) and the
// user answers with gestures — draw a corridor, rip a blocker, restrict layers,
// retry, or skip. Accepted hints distill into a (pcb-plan) fragment at the end.
//
// This is the sibling of pcb_replay.js: it lives in the same #panel-replay dock,
// enters the SAME exclusive view mode, and REUSES pcb_replay.js's shared surface
// (window.PCBReplayShared) for the copper painter, screen→world math, tool
// gating, decision-log text, and the scorebar mode chip — so both players draw
// the same board and read as one dock rather than duplicating that machinery.
//
// Wire contract (built by the HTTP agent, src/serve/route_session_api.zig):
//   POST /api/route-session/<name>/start  {parts:[{ref,x,y,rot,side}…]}  (blocks ~60s)
//   GET  /api/route-session/<name>                                       (reconnect)
//   POST /api/route-session/<name>/hint   {action, …}                    (resumes)
//   DELETE /api/route-session/<name>
//   GET  /api/route-session/<name>/distill → {ok, fragment, hints}
// hint actions: corridor{net,points:[[x,y]…]} | rip{nets:[…]} |
//   route_now{net} | layers{net,allowed:[…]} | abandon{net}
// stuck.occupancy: [{layer:"F.Cu",cells:"<b64>"}…] — per-layer occupied-cell
// grids over stuck.frontier's window, toggled via the #rs-occview switcher.
//
// Contract marker strings (grepped by integration tests): route-session
// rs-stuck rs-corridor frontier
(function () {
  "use strict";

  // Tolerate the panel being absent (module / RO / non-replay pages), like
  // pcb_replay.js and pcb_kicad_import.js guard on their trigger elements.
  var panel = document.getElementById("panel-replay");
  if (!panel) return;
  if (typeof PCB === "undefined") return;
  // Layer spellings come from the blob (PCB.layer_names, emitted out of
  // src/board_layers.zig), the fallback rows below included.
  var LN = PCB.layer_names || {};

  var $ = function (id) { return document.getElementById(id); };

  // ── Shared surface from pcb_replay.js (loaded first) ─────────────────────
  // paintFrame / gateTools / eventText / dotClass / labels / chip come from
  // there. The coordinate helpers are reconstructed locally from the PCB blob
  // (identical to what pcb_replay.js does) so the corridor click math never
  // depends on script load order — screenToWorld needs S/MX/MY/M anyway.
  var SH = window.PCBReplayShared || {};
  var S = PCB.scale || 1, MX = PCB.minx || 0, MY = PCB.miny || 0, M = PCB.margin || 0;
  function X(mm) { return (mm - MX + M) * S; }
  function Y(mm) { return (mm - MY + M) * S; }
  function screenToWorld(cx, cy) {
    if (SH.screenToWorld) return SH.screenToWorld(cx, cy);
    var svg = document.getElementById("pcb-svg");
    if (!svg) return { x: 0, y: 0 };
    var p = null;
    try {
      var m = svg.getScreenCTM();
      if (m) { var inv = m.inverse(), pt = svg.createSVGPoint(); pt.x = cx; pt.y = cy; pt = pt.matrixTransform(inv); p = { x: pt.x, y: pt.y }; }
    } catch (e) { }
    if (!p) {
      var r = svg.getBoundingClientRect(), v = svg.viewBox.baseVal;
      p = { x: v.x + (cx - r.left) * (v.width / Math.max(r.width, 1)),
            y: v.y + (cy - r.top) * (v.height / Math.max(r.height, 1)) };
    }
    return { x: p.x / S + MX - M, y: p.y / S + MY - M };
  }

  // ── State ─────────────────────────────────────────────────────────────
  var state = null;          // last route-session state JSON
  var active = false;        // exclusive view + gating engaged
  var startTimer = null;     // elapsed-time ticker while a request blocks
  var pulseTimer = null;     // repaint ticker so the stuck pad markers pulse
  var occView = -1;          // stuck grid view: -1 frontier, else occupancy layer index
  var corridorArmed = false, corridorPts = [];
  var ripArmed = false, ripPick = null;
  var logSeq = 0;            // events already appended to the decision log
  var pendingResume = null;  // GET-state stashed for the resume banner

  // ── Small DOM helpers ───────────────────────────────────────────────────
  function setText(id, t) { var e = $(id); if (e) e.textContent = t; }
  function show(id, on) { var e = $(id); if (e) e.hidden = !on; }
  function setArmed(id, on) { var e = $(id); if (e) e.classList.toggle("armed", !!on); }
  function status(msg, kind) { var s = $("rp-status"); if (!s) return; s.textContent = msg || ""; s.className = "rp-status" + (kind ? (" " + kind) : ""); }
  function rsHint(msg, kind) { var e = $("rs-hint"); if (!e) return; e.textContent = msg || ""; e.className = "rs-hint" + (kind ? (" " + kind) : ""); }
  function isStuck() { return !!(active && state && state.status === "stuck"); }
  function stuckNet() { return (state && state.stuck && state.stuck.net) || ""; }

  // ── Overlay painter (drawn by pcb_board.js under the world transform) ─────
  // Heatmap UNDER copper; the stuck net's copper haloed via the shared painter;
  // corridor waypoints and pulsing pad endpoints on top. NEVER writes PCB state.
  function sessionPaint(ctx) {
    if (!active || !state) return;
    var stuck = (state.status === "stuck") ? (state.stuck || null) : null;
    if (stuck && stuck.frontier) drawStuckGrid(ctx, stuck);
    var events = state.events || [];
    var ev = events.length ? events[events.length - 1] : null;
    if (ev && SH.paintFrame) {
      var frameEv = ev, drc = null;
      if (stuck) frameEv = { tracks: ev.tracks || [], vias: ev.vias || [], net: stuck.net || null, related: [] };
      else if (state.status === "done") drc = (state.final && state.final.drc) || null;
      SH.paintFrame(ctx, frameEv, state.nets || [], { drc: drc });
    }
    drawCorridor(ctx);
    if (stuck && stuck.pads) drawPads(ctx, stuck.pads);
  }

  // Stuck-card cell grids share one painter over the frontier's window; the
  // Grid-view toggle picks the dataset + palette. Cells: base64 → one byte per
  // grid cell, row-major; cell (r,c) at index r*cols+c, world at origin +
  // c/r*cell_mm. Frontier: 0 unvisited (skipped), 1 reached (faint cyan),
  // 2 blocked-by-copper (red), 3 blocked-by-clearance (orange).
  var FRONTIER_FILLS = [null, "rgba(90,200,230,0.13)", "rgba(240,72,72,0.20)", "rgba(240,150,45,0.17)"];
  // Occupancy (the router's raw per-layer grid truth): 0 free (skipped),
  // 1 this net's own copper (green), 2 foreign copper (red), 3 blocked
  // otherwise — clearance halo / keepout / board edge (orange).
  var OCC_FILLS = [null, "rgba(105,196,111,0.22)", "rgba(240,72,72,0.30)", "rgba(240,150,45,0.20)"];
  function drawStuckGrid(ctx, stuck) {
    var og = (occView >= 0 && stuck.occupancy) ? stuck.occupancy[occView] : null;
    if (og) drawCellGrid(ctx, stuck.frontier, og.cells, OCC_FILLS);
    else drawCellGrid(ctx, stuck.frontier, stuck.frontier.cells, FRONTIER_FILLS);
  }
  function drawCellGrid(ctx, f, cells, fills) {
    if (!f || !cells) return;
    var bin; try { bin = atob(cells); } catch (e) { return; }
    var cols = f.cols | 0, rows = f.rows | 0, cm = f.cell_mm || 1;
    if (cols <= 0 || rows <= 0) return;
    var ox = (f.origin && f.origin[0]) || 0, oy = (f.origin && f.origin[1]) || 0;
    var n = Math.min(bin.length, cols * rows);
    var arr = new Uint8Array(n);
    for (var i = 0; i < n; i++) arr[i] = bin.charCodeAt(i);
    var wpx = cm * S + 0.6; // small overdraw hides seams between cells
    ctx.save();
    for (var val = 1; val <= 3; val++) {
      ctx.fillStyle = fills[val];
      for (var j = 0; j < n; j++) {
        if (arr[j] !== val) continue;
        var r = (j / cols) | 0, c = j - r * cols;
        ctx.fillRect(X(ox + c * cm), Y(oy + r * cm), wpx, wpx);
      }
    }
    ctx.restore();
  }

  // Stuck-net endpoints: pulsing amber rings so the eye lands on what's failing.
  function drawPads(ctx, pads) {
    if (!pads || !pads.length) return;
    var pulse = 0.5 + 0.5 * Math.sin(Date.now() / 260);
    ctx.save();
    pads.forEach(function (p) {
      if (!p) return;
      var x = X(p[0]), y = Y(p[1]);
      ctx.strokeStyle = "#ffd166"; ctx.lineWidth = 2;
      ctx.globalAlpha = 0.5 + 0.45 * pulse;
      ctx.beginPath(); ctx.arc(x, y, 7 + 4 * pulse, 0, 6.2832); ctx.stroke();
      ctx.globalAlpha = 0.95; ctx.fillStyle = "#ffe08a";
      ctx.beginPath(); ctx.arc(x, y, 2.5, 0, 6.2832); ctx.fill();
    });
    ctx.globalAlpha = 1;
    ctx.restore();
  }

  // In-progress corridor: numbered dots joined by a dashed cyan polyline.
  function drawCorridor(ctx) {
    if (!corridorArmed || !corridorPts.length) return;
    ctx.save();
    if (corridorPts.length > 1) {
      ctx.setLineDash([6, 4]); ctx.strokeStyle = "#66d9ef"; ctx.lineWidth = 1.8; ctx.globalAlpha = 0.9;
      ctx.beginPath();
      corridorPts.forEach(function (p, i) { var x = X(p[0]), y = Y(p[1]); if (i === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y); });
      ctx.stroke(); ctx.setLineDash([]);
    }
    corridorPts.forEach(function (p, i) {
      var x = X(p[0]), y = Y(p[1]);
      ctx.globalAlpha = 1; ctx.fillStyle = "#66d9ef";
      ctx.beginPath(); ctx.arc(x, y, 6.5, 0, 6.2832); ctx.fill();
      ctx.fillStyle = "#062329"; ctx.font = "bold 9px sans-serif";
      ctx.textAlign = "center"; ctx.textBaseline = "middle";
      ctx.fillText(String(i + 1), x, y);
    });
    ctx.restore();
  }

  function repaint() { if (window.PCBRepaint) window.PCBRepaint(); }
  function startPulse() { stopPulse(); pulseTimer = setInterval(function () { if (active && isStuck()) repaint(); }, 260); }
  function stopPulse() { if (pulseTimer) { clearInterval(pulseTimer); pulseTimer = null; } }

  // ── Exclusive view mode (shared with pcb_replay.js) ──────────────────────
  var LOCK = ["rp-load", "rp-clear", "rp-adopt", "rp-prev", "rp-play", "rp-next", "rp-slider"];
  var lockPrev = {};
  function lockReplayControls(on) {
    if (on) LOCK.forEach(function (id) { var e = $(id); if (!e) return; if (!(id in lockPrev)) lockPrev[id] = e.disabled; e.disabled = true; });
    else { LOCK.forEach(function (id) { var e = $(id); if (e && (id in lockPrev)) e.disabled = lockPrev[id]; }); lockPrev = {}; }
  }
  function updateChip() {
    if (!active || !SH.setModeChip) return;
    var t = "ROUTING";
    if (state) {
      if (state.status === "stuck") t = "STUCK · " + (stuckNet() || "?");
      else if (state.status === "done") t = "DONE · " + ((state.final && (state.final.routed + "/" + state.final.total)) || "");
      else if (state.status === "aborted") t = "ABORTED";
      else t = "ROUTING · " + (state.status || "working");
    }
    SH.setModeChip(t);
  }
  function enterMode() {
    if (active) { updateChip(); return; }
    active = true;
    window.PCBOverlay = window.PCBOverlay || { paint: null };
    window.PCBOverlay.paint = sessionPaint;
    window.PCBOverlay.exclusive = true;
    var gc = $("rp-ghost"); window.PCBOverlay.ghost = !!(gc && gc.checked);
    if (SH.gateTools) SH.gateTools(true);
    lockReplayControls(true);
    var b = $("rp-session"); if (b) b.textContent = "✕ End session";
    updateChip();
    repaint();
  }
  function exitMode() {
    active = false;
    disarmCorridor(); disarmRip();
    stopPulse();
    if (window.PCBOverlay) { window.PCBOverlay.paint = null; window.PCBOverlay.exclusive = false; window.PCBOverlay.ghost = false; }
    if (SH.gateTools) SH.gateTools(false);
    lockReplayControls(false);
    if (SH.clearModeChip) SH.clearModeChip();
    if (window.PCBSelNet) window.PCBSelNet(null);
    var b = $("rp-session"); if (b) b.textContent = "⚡ Interactive route";
    repaint();
  }

  // ── Decision log (append-only, flat; reuses pcb_replay.js's text/labels) ──
  function renderLog() {
    var log = $("rp-log"); if (!log || !state || !state.events) return;
    var opts = { final: state.final, search_limited: (state.final && state.final.search_limited) || [] };
    var frag = document.createDocumentFragment();
    for (; logSeq < state.events.length; logSeq++) {
      var ev = state.events[logSeq];
      var t = SH.eventText ? SH.eventText(ev, opts) : ["Router", ev.kind || "", ""];
      var li = document.createElement("li");
      li.setAttribute("data-step", String(logSeq));
      var seq = document.createElement("span"); seq.className = "seq"; seq.textContent = String(logSeq + 1);
      var dot = document.createElement("span"); dot.className = "dot " + (SH.dotClass ? SH.dotClass(ev.kind) : "");
      var name = document.createElement("span"); name.className = "event-name"; name.textContent = t[1];
      var meta = document.createElement("span"); meta.className = "event-meta"; meta.textContent = (ev.routed || 0) + "/" + (ev.total || 0);
      li.appendChild(seq); li.appendChild(dot); li.appendChild(name); li.appendChild(meta);
      frag.appendChild(li);
    }
    log.appendChild(frag);
    log.scrollTop = log.scrollHeight; // keep the tail in view while live
  }

  // ── Stuck / done cards ───────────────────────────────────────────────────
  function rsHideCards() {
    ["rs-stuck", "rs-done", "rs-resume", "rs-layers-pop", "rs-frag-wrap"].forEach(function (id) { show(id, false); });
    rsHint("");
  }
  function showStuck() {
    var replay = document.getElementById("route-replay"); if (replay) replay.open = true;
    var s = state.stuck || {};
    setText("rs-net", s.net || "—");
    setText("rs-attempts", (s.attempts != null) ? ("attempt " + s.attempts) : "");
    var occ = (s.layer_occupancy || []).map(function (o) {
      return o.layer + " " + Math.round((o.occupied || 0) * 100) + "%";
    }).join("   ·   ");
    setText("rs-occ", occ ? ("Layer occupancy:  " + occ) : "");
    buildOccView(s);
    renderBlockers(s.blockers || []);
    show("rs-stuck", true);
    show("rs-done", false);
  }
  // Grid-view switcher: the frontier heatmap vs one occupied-cells grid per
  // copper layer — the "why does the router call this region blocked" view.
  function buildOccView(s) {
    var box = $("rs-occview"); if (!box) return;
    box.textContent = "";
    var occ = s.occupancy || [];
    if (!occ.length) { show("rs-occview", false); setText("rs-occlegend", ""); return; }
    if (occView >= occ.length) occView = -1;
    var mk = function (label, idx) {
      var b = document.createElement("button");
      b.type = "button"; b.textContent = label;
      if (occView === idx) b.className = "sel";
      b.addEventListener("click", function () { occView = idx; buildOccView(s); repaint(); });
      box.appendChild(b);
    };
    mk("Frontier", -1);
    occ.forEach(function (g, i) { mk(g.layer || ("L" + i), i); });
    show("rs-occview", true);
    renderOccLegend();
  }
  function renderOccLegend() {
    var e = $("rs-occlegend"); if (!e) return;
    e.textContent = "";
    var items = (occView < 0)
      ? [["#5ac8e6", "search reached"], ["#f04848", "foreign copper wall"], ["#f0962d", "clearance"], [null, "unpainted = never reached"]]
      : [["#f04848", "other nets' copper"], ["#f0962d", "keepout / clearance / edge"], ["#69c46f", "this net's copper"], [null, "unpainted = free"]];
    items.forEach(function (it) {
      var sp = document.createElement("span");
      if (it[0]) { var dot = document.createElement("i"); dot.style.background = it[0]; sp.appendChild(dot); }
      sp.appendChild(document.createTextNode(it[1]));
      e.appendChild(sp);
    });
  }
  function renderBlockers(bl) {
    var ul = $("rs-blockers"); if (!ul) return; ul.textContent = "";
    if (!bl.length) {
      var empty = document.createElement("li");
      empty.textContent = "(no rip-eligible blockers reported)";
      empty.style.cursor = "default"; empty.style.gridTemplateColumns = "1fr";
      ul.appendChild(empty); return;
    }
    bl.forEach(function (b) {
      var li = document.createElement("li"); li.setAttribute("data-net", b.net || "");
      var n = document.createElement("span"); n.className = "bl-net"; n.textContent = b.net || "?";
      var sh = document.createElement("span"); sh.className = "bl-share";
      if (b.share != null) sh.textContent = (b.share <= 1 ? Math.round(b.share * 100) : Math.round(b.share)) + "%";
      var co = document.createElement("span"); co.className = "bl-cost";
      if (b.rip_cost != null) co.textContent = "rip " + b.rip_cost;
      li.appendChild(n); li.appendChild(sh); li.appendChild(co);
      // Hover / click flashes the blocker on the board; while rip is armed a
      // click also picks the net to rip.
      li.addEventListener("mouseenter", function () { if (window.PCBSelNet && b.net) window.PCBSelNet(b.net); });
      li.addEventListener("click", function () {
        if (window.PCBSelNet && b.net) window.PCBSelNet(b.net);
        if (ripArmed) selectRipBlocker(b.net, li);
      });
      ul.appendChild(li);
    });
  }
  function showDone() {
    var f = state.final || {};
    var drcN = (f.drc && f.drc.length) || 0;
    var errN = (f.drc || []).filter(function (d) { return d.severity === "err"; }).length;
    setText("rs-done-sum", (f.routed != null ? f.routed : "?") + "/" + (f.total != null ? f.total : "?") +
      " nets routed · " + errN + "E / " + (drcN - errN) + "W DRC" +
      (state.hints_accepted != null ? (" · " + state.hints_accepted + " hint" + (state.hints_accepted === 1 ? "" : "s")) : ""));
    var d = $("rs-distill"); if (d) d.disabled = false;
    show("rs-done", true);
    show("rs-stuck", false);
  }

  // ── Render the whole dock from a state response ──────────────────────────
  function renderState(j) {
    state = j;
    if (!active) enterMode();
    renderLog();
    updateChip();
    if (state.status === "stuck") {
      showStuck(); startPulse();
      status("router stuck on " + (stuckNet() || "?") + " — answer below", "warn");
    } else {
      show("rs-stuck", false); stopPulse(); disarmCorridor(); disarmRip();
      if (state.status === "done") {
        showDone();
        status("routing complete · " + ((state.final && (state.final.routed + "/" + state.final.total)) || ""), "ok");
      } else if (state.status === "aborted") {
        show("rs-done", false);
        status("session aborted", "warn");
      } else {
        show("rs-done", false);
        status("router working …", "running");
      }
    }
    repaint();
  }

  // ── Network ──────────────────────────────────────────────────────────────
  function url(suffix) { return "/api/route-session/" + encodeURIComponent(PCB.name) + (suffix || ""); }
  function parseState(r) {
    return r.text().then(function (txt) {
      var j;
      try { j = JSON.parse(txt); } catch (e) { throw new Error("the server returned an invalid route-session response"); }
      if (!r.ok || j.ok === false) throw new Error(j.error || ("route session failed (HTTP " + r.status + ")"));
      return j;
    });
  }
  function post(suffix, body) {
    return fetch(url(suffix), {
      method: "POST", headers: { "Content-Type": "application/json" },
      body: body ? JSON.stringify(body) : "{}"
    }).then(parseState);
  }
  function setBusy(b) {
    ["rs-corridor", "rs-rip", "rs-layers", "rs-retry", "rs-abandon", "rs-distill", "rs-close", "rp-session"].forEach(function (id) {
      var e = $(id); if (e) e.disabled = b;
    });
  }
  function startElapsed(prefix) {
    stopElapsed();
    var t0 = Date.now();
    status(prefix + " 0s", "running");
    startTimer = setInterval(function () { status(prefix + " " + Math.floor((Date.now() - t0) / 1000) + "s", "running"); }, 1000);
  }
  function stopElapsed() { if (startTimer) { clearInterval(startTimer); startTimer = null; } }

  function resetDock() {
    logSeq = 0;
    occView = -1;
    ["rp-log", "rp-summary", "rp-deltas"].forEach(function (id) { var e = $(id); if (e) e.textContent = ""; });
    rsHideCards();
  }

  function startSession() {
    // The board AS DRAWN — PCB.parts is the live array pcb_board.js mutates on
    // every drag/flip, and the same {ref,x,y,rot,side} shape window.PCBBoardBody
    // posts. The page emits its blob as `const PCB=…`, a classic-script LEXICAL
    // global, so `window.PCB` is undefined: read the bare binding (via typeof to
    // stay strict-safe, as pcb_3d_viewer.js does). Posting nothing here silently
    // routed the SOLVED placement instead of the one on screen.
    var parts = ((typeof PCB !== "undefined" && PCB.parts) || []).map(function (p) {
      return { ref: p.ref, x: p.x, y: p.y, rot: p.rot || 0, side: p.side || "top" };
    });
    resetDock();
    enterMode();
    setBusy(true);
    startElapsed("routing… (initial pipeline may take ~1 min)");
    post("/start", { parts: parts })
      .then(function (j) { stopElapsed(); renderState(j); })
      .catch(function (err) { stopElapsed(); status((err && err.message) || "route session failed", "error"); exitMode(); rsHideCards(); state = null; })
      .finally(function () { setBusy(false); });
  }

  function sendHint(body, label) {
    disarmCorridor(); disarmRip();
    show("rs-layers-pop", false);
    setBusy(true);
    startElapsed("applying " + label + "…");
    rsHint("");
    post("/hint", body)
      .then(function (j) { stopElapsed(); renderState(j); })
      .catch(function (err) { stopElapsed(); status((err && err.message) || "hint failed", "error"); })
      .finally(function () { setBusy(false); });
  }

  function endSession() {
    try { fetch(url(""), { method: "DELETE" }); } catch (e) { }
    state = null;
    exitMode();
    rsHideCards();
    status("session closed", "");
  }

  function onSessionBtn() { if (active) endSession(); else startSession(); }

  // ── Reconnect: offer to resume a session left running ────────────────────
  function checkResume() {
    fetch(url(""))
      .then(function (r) { if (r.status === 404) return null; return r.text().then(function (t) { try { return JSON.parse(t); } catch (e) { return null; } }); })
      .then(function (j) {
        if (!j || j.ok === false || !j.session) return;
        if (j.status === "aborted") return;
        pendingResume = j;
        show("rs-resume", true);
      })
      .catch(function () { });
  }
  function resumeSession() {
    var j = pendingResume; if (!j) return;
    show("rs-resume", false);
    resetDock();
    renderState(j);
  }

  // ── Corridor gesture ─────────────────────────────────────────────────────
  function withinBoard(ev) {
    var svg = document.getElementById("pcb-svg"); if (!svg) return false;
    var r = svg.getBoundingClientRect();
    return ev.clientX >= r.left && ev.clientX <= r.right && ev.clientY >= r.top && ev.clientY <= r.bottom;
  }
  // Capture-phase document listeners while armed. On a board click we consume
  // the event (preventDefault + stopPropagation in the CAPTURE phase, before
  // pcb_board.js's bubble-phase svg pointerdown), so no part-drag/marquee fires.
  // Clicks outside the board (the dock buttons) fall through untouched.
  function corridorDown(ev) {
    if (ev.button !== 0) return;
    if (panel.contains(ev.target)) return; // never hijack clicks on our own dock
    if (!withinBoard(ev)) return;
    ev.preventDefault(); ev.stopPropagation();
    var w = screenToWorld(ev.clientX, ev.clientY);
    corridorPts.push([+w.x.toFixed(3), +w.y.toFixed(3)]);
    rsHint("Corridor for " + stuckNet() + ": " + corridorPts.length + " waypoint" + (corridorPts.length > 1 ? "s" : "") +
      ". Enter / double-click confirms, Esc cancels.");
    var b = $("rs-corridor"); if (b) b.textContent = "Confirm corridor (" + corridorPts.length + ")";
    repaint();
  }
  function corridorDbl(ev) {
    if (!withinBoard(ev)) return;
    ev.preventDefault(); ev.stopPropagation();
    confirmCorridor();
  }
  function corridorKey(ev) {
    if (ev.key === "Enter") { ev.preventDefault(); ev.stopPropagation(); confirmCorridor(); }
    else if (ev.key === "Escape") { ev.preventDefault(); ev.stopPropagation(); disarmCorridor(); rsHint("Corridor cancelled."); }
  }
  function armCorridor() {
    if (!isStuck()) return;
    disarmRip();
    corridorArmed = true; corridorPts = [];
    setArmed("rs-corridor", true);
    var b = $("rs-corridor"); if (b) b.textContent = "Confirm corridor";
    rsHint("Corridor for " + stuckNet() + ": click waypoints on the board. Enter / double-click confirms, Esc cancels.");
    document.addEventListener("pointerdown", corridorDown, true);
    document.addEventListener("dblclick", corridorDbl, true);
    document.addEventListener("keydown", corridorKey, true);
    repaint();
  }
  function disarmCorridor() {
    if (!corridorArmed) { return; }
    corridorArmed = false;
    setArmed("rs-corridor", false);
    var b = $("rs-corridor"); if (b) b.textContent = "Draw corridor";
    document.removeEventListener("pointerdown", corridorDown, true);
    document.removeEventListener("dblclick", corridorDbl, true);
    document.removeEventListener("keydown", corridorKey, true);
    repaint();
  }
  // A double-click adds two near-coincident points before firing dblclick; drop
  // consecutive waypoints within ~0.2 mm so the confirm click doesn't dup.
  function dedupPts(pts) {
    var out = [];
    for (var i = 0; i < pts.length; i++) {
      var p = pts[i], last = out[out.length - 1];
      if (last && Math.abs(last[0] - p[0]) < 0.2 && Math.abs(last[1] - p[1]) < 0.2) continue;
      out.push(p);
    }
    return out;
  }
  function confirmCorridor() {
    var pts = dedupPts(corridorPts);
    if (pts.length < 2) { rsHint("Draw at least two waypoints before confirming.", "err"); return; }
    var net = stuckNet();
    disarmCorridor();
    sendHint({ action: "corridor", net: net, points: pts }, "corridor (" + pts.length + " pts) on " + net);
  }
  function corridorClick() { if (!isStuck()) return; if (corridorArmed) confirmCorridor(); else armCorridor(); }

  // ── Rip gesture ──────────────────────────────────────────────────────────
  function ripKey(ev) { if (ev.key === "Escape") { ev.preventDefault(); disarmRip(); rsHint("Rip cancelled."); } }
  function armRip() {
    if (!isStuck()) return;
    disarmCorridor();
    ripArmed = true; ripPick = null;
    setArmed("rs-rip", true);
    var b = $("rs-rip"); if (b) b.textContent = "Rip a blocker";
    rsHint("Rip: click a blocker row to pick the net, then click Confirm rip. Esc cancels.");
    document.addEventListener("keydown", ripKey, true);
  }
  function disarmRip() {
    if (!ripArmed) { return; }
    ripArmed = false; ripPick = null;
    setArmed("rs-rip", false);
    var b = $("rs-rip"); if (b) b.textContent = "Rip a blocker";
    var ul = $("rs-blockers"); if (ul) Array.prototype.forEach.call(ul.querySelectorAll("li"), function (el) { el.classList.remove("sel"); });
    document.removeEventListener("keydown", ripKey, true);
  }
  function selectRipBlocker(net, li) {
    ripPick = net;
    var ul = $("rs-blockers"); if (ul) Array.prototype.forEach.call(ul.querySelectorAll("li"), function (el) { el.classList.remove("sel"); });
    if (li) li.classList.add("sel");
    var b = $("rs-rip"); if (b) b.textContent = "Confirm rip: " + net;
    rsHint("Ready to rip " + net + ". Click 'Confirm rip', or another row to change.");
  }
  function ripClick() {
    if (!isStuck()) return;
    if (ripArmed && ripPick) { var net = ripPick; disarmRip(); sendHint({ action: "rip", nets: [net] }, "rip " + net); return; }
    if (ripArmed) { disarmRip(); rsHint("Rip cancelled."); return; }
    armRip();
  }

  // ── Layers popover ───────────────────────────────────────────────────────
  function buildLayersList() {
    var box = $("rs-layers-list"); if (!box) return; box.textContent = "";
    // The ROUTABLE rows of the blob's one layer table, in signal-index order —
    // the same derivation pcb_board.js makes (a plane-claimed inner has no
    // routable index, so the router can never be asked to free it).
    // Bare lexical `PCB` (see startSession) — gating this on `window.PCB` pinned
    // every board to the two-layer fallback below, hiding its inner signal layers.
    var table = (typeof PCB !== "undefined" && PCB.layer_table && PCB.layer_table.length) ? PCB.layer_table : null;
    var layers = table
      ? table.filter(function (r) { return typeof r.l === "number"; })
          .sort(function (a, b) { return a.l - b.l; })
      : [{ name: LN.f_cu }, { name: LN.b_cu }];
    layers.forEach(function (L) {
      var lab = document.createElement("label");
      var cb = document.createElement("input"); cb.type = "checkbox"; cb.checked = true; cb.value = L.name;
      var sp = document.createElement("span"); sp.textContent = L.name;
      lab.appendChild(cb); lab.appendChild(sp); box.appendChild(lab);
    });
  }
  function toggleLayers() {
    if (!isStuck()) return;
    var pop = $("rs-layers-pop"); if (!pop) return;
    if (!pop.hidden) { pop.hidden = true; return; }
    disarmCorridor(); disarmRip();
    buildLayersList();
    pop.hidden = false;
  }
  function applyLayers() {
    var box = $("rs-layers-list"); if (!box) return;
    var allowed = [];
    Array.prototype.forEach.call(box.querySelectorAll("input:checked"), function (cb) { allowed.push(cb.value); });
    if (!allowed.length) { rsHint("Select at least one layer.", "err"); return; }
    show("rs-layers-pop", false);
    sendHint({ action: "layers", net: stuckNet(), allowed: allowed }, "layers [" + allowed.join(", ") + "] on " + stuckNet());
  }

  // ── Retry / abandon ──────────────────────────────────────────────────────
  function retryNet() { if (!isStuck()) return; sendHint({ action: "route_now", net: stuckNet() }, "retry " + stuckNet()); }
  function abandonNet() { if (!isStuck()) return; sendHint({ action: "abandon", net: stuckNet() }, "skip " + stuckNet()); }

  // ── Distill + copy ───────────────────────────────────────────────────────
  function distill() {
    var d = $("rs-distill"); if (d) d.disabled = true;
    status("distilling…", "running");
    fetch(url("/distill"))
      .then(function (r) {
        return r.text().then(function (t) {
          var j; try { j = JSON.parse(t); } catch (e) { throw new Error("the server returned an invalid distill response"); }
          if (!r.ok || j.ok === false) throw new Error(j.error || ("distill failed (HTTP " + r.status + ")"));
          return j;
        });
      })
      .then(function (j) {
        setText("rs-fragment", j.fragment || "");
        var hn = (j.hints != null) ? j.hints : 0;
        setText("rs-frag-note", hn + " hint" + (hn === 1 ? "" : "s") + " accepted");
        show("rs-frag-wrap", true);
        status("distilled " + hn + " hint" + (hn === 1 ? "" : "s"), "ok");
      })
      .catch(function (err) { status((err && err.message) || "distill failed", "error"); })
      .finally(function () { if (d) d.disabled = false; });
  }
  function copyFragment() {
    var pre = $("rs-fragment"); if (!pre) return;
    var txt = pre.textContent || "";
    var done = function () { var b = $("rs-copy"); if (!b) return; var o = b.textContent; b.textContent = "Copied!"; setTimeout(function () { b.textContent = o; }, 1200); };
    var fallback = function () {
      try {
        var ta = document.createElement("textarea"); ta.value = txt;
        ta.style.position = "fixed"; ta.style.opacity = "0"; document.body.appendChild(ta);
        ta.select(); document.execCommand("copy"); document.body.removeChild(ta); done();
      } catch (e) { }
    };
    if (navigator.clipboard && navigator.clipboard.writeText) navigator.clipboard.writeText(txt).then(done, fallback);
    else fallback();
  }

  // ── Wiring ───────────────────────────────────────────────────────────────
  function onClick(id, fn) { var e = $(id); if (e) e.addEventListener("click", fn); }
  onClick("rp-session", onSessionBtn);
  onClick("rs-corridor", corridorClick);
  onClick("rs-rip", ripClick);
  onClick("rs-layers", toggleLayers);
  onClick("rs-layers-apply", applyLayers);
  onClick("rs-layers-cancel", function () { show("rs-layers-pop", false); });
  onClick("rs-retry", retryNet);
  onClick("rs-abandon", abandonNet);
  onClick("rs-distill", distill);
  onClick("rs-copy", copyFragment);
  onClick("rs-close", endSession);
  onClick("rs-resume-btn", resumeSession);
  // Ghost toggle also drives the session overlay (shared with pcb_replay.js).
  var ghostCb = $("rp-ghost");
  if (ghostCb) ghostCb.addEventListener("change", function () {
    if (active && window.PCBOverlay) { window.PCBOverlay.ghost = this.checked; repaint(); }
  });

  checkResume();
})();
