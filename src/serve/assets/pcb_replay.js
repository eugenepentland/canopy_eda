// pcb_replay.js — design-route-review replay panel for the /pcb-layout page.
//
// Ports the standalone route_review.js player (scrubber, autoplay, grouped
// decision log, per-frame deltas) into the #panel-replay accordion panel of
// the live board editor. The old player drew onto its own canvas; here the
// REAL board renders the replay copper through the pcb_board.js overlay seam
// (window.PCBOverlay), so this file never draws a board of its own.
//
// It only ever mutates board state (PCB.tracks/PCB.vias/PCB.drc) through the
// explicit Adopt action, via window.PCBAdoptCopper — the same application path
// the Route button uses. Everything else is a transient overlay.
//
// It also drives the live autoroute: the merged Route panel's Route button
// (pcb_board.js) POSTs /api/route-live/<name>/start and hands the background job
// to window.PCBLiveRoute.begin here — we poll the growing event stream into the
// SAME player structures, grow the scrubber, follow the head, and reattach to a
// job still running on page load.
//
// Contract marker strings (grepped by tests): panel-replay
// PCBOverlay PCBOverlay.exclusive rp-slider rp-ghost
// route-live PCBLiveRoute follow reattach
(function () {
  "use strict";

  // Tolerate the panel being absent (module / RO / non-replay pages), the way
  // pcb_kicad_import.js guards on its trigger element.
  var panel = document.getElementById("panel-replay");
  if (!panel) return;
  if (typeof PCB === "undefined") return;
  // Layer spellings come from the blob (PCB.layer_names, emitted out of
  // src/board_layers.zig), the fallback rows below included.
  var LN = PCB.layer_names || {};

  var $ = function (id) { return document.getElementById(id); };
  function revealReplay() { var d = $("route-replay"); if (d) d.open = true; }

  // ── World-coordinate helpers ──────────────────────────────────────────
  // Reconstructed from the same PCB blob pcb_board.js reads at its IIFE top
  // (S=scale, MX/MY=min, M=margin). The overlay is invoked under the canvas
  // transform paintTracks uses, so X()/Y() map mm→svg-units and widths scale
  // by S — copied verbatim from paintTracks so the overlay lands pixel-exact.
  var S = PCB.scale || 1, MX = PCB.minx || 0, MY = PCB.miny || 0, M = PCB.margin || 0;
  function X(mm) { return (mm - MX + M) * S; }
  function Y(mm) { return (mm - MY + M) * S; }

  // Layer colour table, derived from the blob's one layer table exactly as
  // pcb_board.js does: the ROUTABLE rows (numeric `l`) in signal-index order,
  // with the classic two-layer fallback. Track/via layer ints in the replay
  // tuples are the SAME router.Track.layer values PCB.tracks[].l carries
  // (0=F.Cu, 1=B.Cu, 2+=inner) — verified against writeTimeline vs
  // writeRoutedArrays — so no remapping is needed for drawing or adoption.
  var LYR = (PCB.layer_table && PCB.layer_table.length)
    ? PCB.layer_table.filter(function (r) { return typeof r.l === "number"; })
        .sort(function (a, b) { return a.l - b.l; })
        .map(function (r) { return { l: r.l, name: r.name, c: r.c }; })
    : [{ l: 0, name: LN.f_cu, c: "#C83434" }, { l: 1, name: LN.b_cu, c: "#4D7FC4" }];
  function layerColor(l) {
    for (var i = 0; i < LYR.length; i++) if (LYR[i].l === l) return LYR[i].c;
    return "#8b949e";
  }
  // Via colours come from the server's ONE board theme (PCB.theme, emitted out
  // of src/board_theme.zig) exactly as pcb_board.js's TH does; the literals are
  // the no-blob fallback and are the same values.
  var THEME = PCB.theme || {};
  var VIA_FILL = THEME.via || "#B2B27A", VIA_HOLE = THEME.viaHole || "#001023";
  var ACTIVE = "#ffd166", HALO = "#ffe08a";        // amber emphasis (as route_review.js)

  // ── Shared copper painter (reused by pcb_route_session.js) ─────────────
  // Draws ONE timeline event's copper straight onto the (already world-
  // transformed) canvas context: non-active copper dimmed, the active event's
  // net (+related) emphasized, the primary net haloed amber, and — when
  // opts.drc is supplied — the run's DRC markers as distinct crosses. Pure of
  // module state so the interactive-route view can paint the same copper. Args:
  //   ev   — a timeline event {net,related,tracks:[[x1,y1,x2,y2,l,w,netIdx]…],vias:[[x,y,dia,drill,netIdx]…]}
  //   nets — the review's net-index → name table (ev tuples carry indices)
  //   opts — {exclusive?:bool (default: PCBOverlay.exclusive), drc?:[{x,y,severity}…]}
  function paintFrame(ctx, ev, nets, opts) {
    if (!ev) return;
    opts = opts || {}; nets = nets || [];
    function nmL(idx) { return (idx >= 0 && idx < nets.length) ? nets[idx] : ""; }
    var excl = (opts.exclusive !== undefined)
      ? opts.exclusive : !!(window.PCBOverlay && window.PCBOverlay.exclusive);
    var baseA = excl ? 0.9 : 0.26;
    var activeNet = ev.net || null;
    var emph = {};
    if (activeNet) emph[activeNet] = 1;
    (ev.related || []).forEach(function (n) { emph[n] = 1; });
    ctx.save();
    ctx.lineCap = "round";
    // base pass — copper outside the active transaction
    (ev.tracks || []).forEach(function (t) {
      if (emph[nmL(t[6])]) return;
      ctx.globalAlpha = baseA; ctx.strokeStyle = layerColor(t[4]);
      ctx.lineWidth = Math.max(t[5] * S, 1.2);
      ctx.beginPath(); ctx.moveTo(X(t[0]), Y(t[1])); ctx.lineTo(X(t[2]), Y(t[3])); ctx.stroke();
    });
    // halo pass — the primary net, under its core
    if (activeNet) {
      ctx.globalAlpha = 0.5; ctx.strokeStyle = HALO;
      (ev.tracks || []).forEach(function (t) {
        if (nmL(t[6]) !== activeNet) return;
        ctx.lineWidth = Math.max(t[5] * S, 1.2) + 3;
        ctx.beginPath(); ctx.moveTo(X(t[0]), Y(t[1])); ctx.lineTo(X(t[2]), Y(t[3])); ctx.stroke();
      });
    }
    // emphasized core pass — active + related nets, full alpha, layer colour
    (ev.tracks || []).forEach(function (t) {
      if (!emph[nmL(t[6])]) return;
      ctx.globalAlpha = 0.95; ctx.strokeStyle = layerColor(t[4]);
      ctx.lineWidth = Math.max(t[5] * S, 1.2);
      ctx.beginPath(); ctx.moveTo(X(t[0]), Y(t[1])); ctx.lineTo(X(t[2]), Y(t[3])); ctx.stroke();
    });
    ctx.lineCap = "butt";
    // vias (annuli), matching paintTracks' via geometry
    (ev.vias || []).forEach(function (v) {
      var net = nmL(v[4]), isEmph = !!emph[net];
      var rr = Math.max(v[2] / 2 * S, 2.5);
      var dr = (v[3] > 0) ? v[3] : 0.3;
      var rh = Math.min(Math.max(dr / 2 * S, 1), rr * 0.7);
      ctx.globalAlpha = isEmph ? 0.95 : baseA;
      ctx.fillStyle = (net === activeNet) ? ACTIVE : VIA_FILL;
      ctx.beginPath(); ctx.arc(X(v[0]), Y(v[1]), rr, 0, 6.2832); ctx.fill();
      ctx.fillStyle = VIA_HOLE;
      ctx.beginPath(); ctx.arc(X(v[0]), Y(v[1]), rh, 0, 6.2832); ctx.fill();
    });
    ctx.globalAlpha = 1;
    // DRC markers (distinct crosses; never written to PCB.drc)
    if (opts.drc && opts.drc.length) {
      opts.drc.forEach(function (d) {
        var x = X(d.x), y = Y(d.y), r = 6;
        ctx.strokeStyle = (d.severity === "err") ? "#ff4d9d" : "#ffbd5c";
        ctx.globalAlpha = 0.85; ctx.lineWidth = 1.6;
        ctx.beginPath(); ctx.arc(x, y, r, 0, 6.2832); ctx.stroke();
        ctx.beginPath();
        ctx.moveTo(x - r * 1.4, y); ctx.lineTo(x + r * 1.4, y);
        ctx.moveTo(x, y - r * 1.4); ctx.lineTo(x, y + r * 1.4); ctx.stroke();
      });
      ctx.globalAlpha = 1;
    }
    ctx.restore();
  }

  // Screen (clientX/clientY) → world mm, replicating pcb_board.js's private
  // mm(ev): getScreenCTM().inverse() → svg-unit, then svg-unit → mm. Used by
  // the interactive-route corridor tool to place waypoints on the real board.
  function screenToWorld(cx, cy) {
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
  var data = null;          // last loaded review JSON (or the live stream's timeline)
  var frame = 0;            // current timeline index
  var playing = false, timer = null;
  var overlayOn = false;    // is the transient overlay currently shown
  var adopted = false;      // has the current result been adopted
  // Live-route streaming state (Phase 3): the Route button hands a background
  // job here (window.PCBLiveRoute.begin); we poll its growing event stream into
  // the SAME `data.timeline` the replay player reads, following the head until
  // the user scrubs back.
  var live = { on: false, gen: 0, attempt: 0, since: 0, misses: 0,
               follow: true, onFinal: null, logSeq: 0, seq: 0 };

  // ── Small formatters ──────────────────────────────────────────────────
  function nm(idx) {
    var nets = (data && data.nets) || [];
    return (idx >= 0 && idx < nets.length) ? nets[idx] : "";
  }
  function signed(n, digits) {
    if (Math.abs(n) < Math.pow(10, -digits)) return "0";
    return (n > 0 ? "+" : "") + n.toFixed(digits);
  }
  function status(msg, kind) {
    var s = $("rp-status"); if (!s) return;
    s.textContent = msg || "";
    s.className = "rp-status" + (kind ? (" " + kind) : "");
  }

  // ── Human-readable event labels (ported from route_review.js) ─────────
  var labels = {
    initial: ["Setup", "Reference copper removed", "The fixed footprints, pads, zones, and outline are retained. The trace and via field starts empty."],
    plane_routed: ["Plane pass", "Plane connection added", "A plane-backed net was connected by its pour or by a legal via drop."],
    plane_failed: ["Plane pass", "Plane connection failed", "The router could not find a legal plane connection for this net."],
    net_routed: ["Greedy pass", "Net routed", "This net claimed a legal path in priority order."],
    net_failed: ["Greedy pass", "Net failed", "No legal path was found with the copper already on the board."],
    ripup: ["Rip-up", "Blocking copper removed", "The failed net and its eligible blockers were removed for a bounded retry."],
    reroute_candidate: ["Rip-up", "Candidate reroute evaluated", "The target was routed first, followed by the displaced nets. The next step records whether this board state was kept."],
    reroute_accepted: ["Rip-up", "Candidate accepted", "The speculative route connected more nets or shortened copper without reducing the connected count."],
    reroute_rejected: ["Rollback", "Candidate rejected", "The retry did not improve the board, so the exact pre-rip-up state was restored."],
    escape_stubs: ["Post-pass", "Escape stubs added", "Authored pad escape stubs were added after the net routing passes."],
    return_stitching: ["Post-pass", "Return paths stitched", "Ground stitching vias were added near signal layer changes where legal."],
    bend_smoothing: ["RF discipline", "RF bends smoothed", "This max-freq net's corners were reshaped into tangent arcs the moment it routed — aiming for the largest radius that fits (minimum 3x the trace width), holding the straight pad-escape reserve, so later nets route around the real arc copper. Corners that missed the minimum radius are flagged by the sharp_bend DRC check."],
    complete: ["Complete", "Routing run complete", "This is the final copper state produced by the run."],
    // Interactive-route-session event kinds (emitted by the live router loop).
    stuck: ["Stuck", "Router stuck", "The router exhausted its legal options for this net and paused for a hint — draw a corridor, rip a blocker, free layers, or skip."],
    hint_applied: ["Hint", "Hint applied", "Your guidance was applied and the router resumed from the paused state."]
  };
  // opts (optional) lets a caller that isn't the replay module — the interactive
  // route session — supply its own final/search_limited context; replay calls
  // with no opts and falls back to its module `data`.
  function eventText(ev, opts) {
    opts = opts || {};
    var base = labels[ev.kind] || ["Router", (ev.kind || "").replace(/_/g, " "), ""];
    var title = base[1] + (ev.net ? ": " + ev.net : "");
    var detail = base[2];
    var searchLimited = opts.search_limited ||
      (opts.final && opts.final.search_limited) ||
      (data && data.final && data.final.search_limited) || [];
    if (ev.kind === "net_failed" && ev.net && searchLimited.indexOf(ev.net) >= 0)
      detail = "The route search reached its expansion budget — an algorithm/search-limit failure, not proof that no legal path exists.";
    if (ev.related && ev.related.length)
      detail += " Nets in this transaction: " + ev.related.join(", ") + ".";
    if (ev.round) detail += " Rip-up round " + ev.round + ".";
    return [base[0], title, detail];
  }
  function dotClass(kind) {
    kind = kind || "";
    if (kind.indexOf("failed") >= 0 || kind === "reroute_rejected") return "fail";
    if (kind === "ripup" || kind === "reroute_candidate") return "rip";
    if (kind === "complete") return "end";
    if (kind.indexOf("routed") >= 0 || kind === "reroute_accepted") return "ok";
    return "";
  }
  function groupKeyOf(ev) {
    var phase = (labels[ev.kind] || ["Router"])[0];
    if (phase === "Rip-up" || phase === "Rollback") return "Rip-up round " + (ev.round || 1);
    if (ev.kind === "net_routed" || ev.kind === "net_failed" || (ev.kind === "bend_smoothing" && ev.net)) {
      if (data.net_class) {
        var ni = data.nets.indexOf(ev.net), nc = ni >= 0 ? data.net_class[ni] : null;
        return "Net routing — " + (nc && nc.name ? nc.name : "default") + " class";
      }
      return "Net routing";
    }
    return phase;
  }

  // ── Collapsible decision log (#rp-log) ────────────────────────────────
  var collapsed = {};
  function applyCollapse() {
    var log = $("rp-log"); if (!log) return;
    Array.prototype.forEach.call(log.querySelectorAll("li"), function (el) {
      var g = el.getAttribute("data-group");
      if (el.classList.contains("group-head")) el.classList.toggle("closed", !!collapsed[g]);
      else el.hidden = !!collapsed[g];
    });
  }
  function expandGroupOf(el) {
    var g = el.getAttribute("data-group");
    if (collapsed[g]) { delete collapsed[g]; applyCollapse(); }
  }
  function buildList() {
    var log = $("rp-log"); if (!log) return;
    log.textContent = ""; collapsed = {};
    var frag = document.createDocumentFragment();
    var lastKey = null, gi = -1, headMeta = null, count = 0, startRouted = 0;
    data.timeline.forEach(function (ev, i) {
      var key = groupKeyOf(ev);
      if (key !== lastKey) {
        lastKey = key; gi++; count = 0;
        startRouted = i ? (data.timeline[i - 1].routed || 0) : 0;
        var head = document.createElement("li");
        head.className = "group-head"; head.setAttribute("data-group", String(gi));
        var chev = document.createElement("span"); chev.className = "chev"; chev.textContent = "▸";
        var ttl = document.createElement("span"); ttl.className = "group-title"; ttl.textContent = key;
        headMeta = document.createElement("span"); headMeta.className = "group-meta";
        head.appendChild(chev); head.appendChild(ttl); head.appendChild(headMeta);
        head.addEventListener("click", function () {
          var g = head.getAttribute("data-group");
          if (collapsed[g]) delete collapsed[g]; else collapsed[g] = 1;
          applyCollapse();
        });
        frag.appendChild(head);
      }
      count++;
      var gained = (ev.routed || 0) - startRouted;
      headMeta.textContent = count + (count === 1 ? " step" : " steps") +
        (gained > 0 ? (" · +" + gained + (gained === 1 ? " net" : " nets")) : "");
      var li = document.createElement("li");
      li.setAttribute("data-step", String(i)); li.setAttribute("data-group", String(gi));
      var t = eventText(ev);
      var seq = document.createElement("span"); seq.className = "seq"; seq.textContent = String(i + 1);
      var dotEl = document.createElement("span"); dotEl.className = "dot " + dotClass(ev.kind);
      var name = document.createElement("span"); name.className = "event-name"; name.textContent = t[1];
      var meta = document.createElement("span"); meta.className = "event-meta";
      meta.textContent = (ev.routed || 0) + "/" + (ev.total || 0);
      li.appendChild(seq); li.appendChild(dotEl); li.appendChild(name); li.appendChild(meta);
      li.addEventListener("click", function () { stop(); ensureArmed(); setFrame(i, false); });
      frag.appendChild(li);
    });
    log.appendChild(frag);
  }

  // ── Summary + deltas ──────────────────────────────────────────────────
  function renderSummary(ev) {
    var sum = $("rp-summary"); if (!sum) return;
    sum.textContent = "";
    var t = eventText(ev);
    var head = document.createElement("div"); head.className = "rp-sum-head";
    head.textContent = t[0] + " — " + t[1];
    var stats = document.createElement("div"); stats.className = "rp-sum-stats";
    stats.textContent = (ev.routed || 0) + "/" + (ev.total || 0) + " nets · " +
      (ev.trace_mm || 0).toFixed(1) + " mm · " + (ev.tracks || []).length + " tracks · " +
      (ev.vias || []).length + " vias · step " + (frame + 1) + "/" + data.timeline.length;
    sum.appendChild(head); sum.appendChild(stats);
    if (t[2]) {
      var det = document.createElement("div"); det.className = "rp-sum-detail"; det.textContent = t[2];
      sum.appendChild(det);
    }
  }
  function renderDeltas(ev, prev) {
    var box = $("rp-deltas"); if (!box) return;
    box.textContent = "";
    var values = prev ? [
      ["nets", (ev.routed || 0) - (prev.routed || 0), 0],
      ["tracks", (ev.tracks || []).length - (prev.tracks || []).length, 0],
      ["vias", (ev.vias || []).length - (prev.vias || []).length, 0],
      ["trace mm", (ev.trace_mm || 0) - (prev.trace_mm || 0), 1]
    ] : [
      ["tracks", (ev.tracks || []).length, 0],
      ["vias", (ev.vias || []).length, 0],
      ["trace mm", ev.trace_mm || 0, 1]
    ];
    values.forEach(function (v) {
      var s = document.createElement("span");
      s.textContent = v[0] + " " + signed(v[1], v[2]);
      if (v[1] > 0) s.className = "pos"; else if (v[1] < 0) s.className = "neg";
      box.appendChild(s);
    });
  }

  // ── Overlay rendering (drawn by pcb_board.js under the world transform) ─
  // Draws the CURRENT frame's copper straight onto the canvas: non-active
  // copper dimmed, the active event's net (+related) emphasized, the primary
  // net haloed amber; on the final frame the replay's final.drc markers too.
  // NEVER writes PCB.tracks/PCB.vias/PCB.drc.
  // ── Router vision: the free space the maze itself saw, at THIS step ──────
  // The finished board shows where copper ended up; it cannot show how much
  // room the router had when it drew a given trace, because every later net
  // narrowed the board. The server replays the maze's own `blocked` predicate
  // against this event's copper snapshot (POST /api/route-vision) and returns
  // one run-length-encoded mask per signal layer: 0 blocked, 1 free, 2 free
  // AND reachable from the net's seed pad.
  //
  // Modes: 1 = free space (any passable node), 2 = reach (free-but-sealed
  // shown separately, which is what makes a failed net's stranded pads legible).
  var vision = { mode: 0, pass: null, cache: {}, order: [], gen: 0, timer: null, pads: null };
  // Each cached frame holds two full-grid canvases per signal layer. On a
  // 346x308 board that is ~1.7 MB a frame, so an unbounded cache would run to
  // hundreds of MB over a scrub through a long timeline. Keep a small window —
  // re-fetching an evicted frame costs one ~0.5 s request.
  var VISION_CACHE_MAX = 12;

  function visionCachePut(i, built) {
    vision.cache[i] = built;
    vision.order.push(i);
    while (vision.order.length > VISION_CACHE_MAX) delete vision.cache[vision.order.shift()];
  }

  function visionNote(txt) { var e = $("rp-vision-note"); if (e) e.textContent = txt || ""; }

  // Drop everything keyed to the previous attempt. Called on a fresh replay
  // load and on the second `.initial` (a finer-grid restart re-lattices the
  // board, so every cached mask describes a grid that no longer exists).
  function visionReset() {
    vision.pass = null; vision.cache = {}; vision.order = []; vision.pads = null; vision.gen++;
    visionNote("");
  }

  // Latch the attempt's lattice off the `.initial` event. Its absence is a real
  // state, not an error: replays cached before pass recording existed carry no
  // lattice, and guessing one would draw a mask of a board that never was.
  function visionLatch(ev) {
    if (!ev || ev.kind !== "initial") return;
    visionReset();
    vision.pass = ev.pass || null;
    if (vision.mode && !vision.pass) visionNote("— re-run Route to record the grid");
  }

  // Expand one layer's base64 run-length mask into a Uint8Array of cells.
  function visionDecode(b64, cells) {
    var bin = atob(b64), out = new Uint8Array(cells), at = 0;
    for (var i = 0; i + 2 < bin.length; i += 3) {
      var v = bin.charCodeAt(i), n = bin.charCodeAt(i + 1) | (bin.charCodeAt(i + 2) << 8);
      for (var k = 0; k <= n && at < cells; k++) out[at++] = v;
    }
    return out;
  }

  // Build the per-layer offscreen bitmaps once per fetched frame — one canvas
  // at GRID resolution, blitted unsmoothed at draw time, so pan/zoom costs
  // nothing and the cell lattice stays visible as the lattice it is.
  function visionBitmaps(res) {
    var g = res.grid, out = [];
    for (var l = 0; l < res.n_signal; l++) {
      var cells = visionDecode(res.layers[l], g.nx * g.ny);
      var cv = document.createElement("canvas"); cv.width = g.nx; cv.height = g.ny;
      var img = cv.getContext("2d").createImageData(g.nx, g.ny), d = img.data;
      for (var i = 0; i < cells.length; i++) {
        var o = i * 4;
        if (cells[i] === 0) continue;                       // blocked: leave the copper visible
        if (cells[i] === 2) { d[o] = 63; d[o + 1] = 185; d[o + 2] = 80; d[o + 3] = 64; }   // reachable
        else { d[o] = 248; d[o + 1] = 81; d[o + 2] = 73; d[o + 3] = 74; }                  // free but sealed off
      }
      cv.getContext("2d").putImageData(img, 0, 0);
      // FREE mode wants one flat wash: repaint the sealed cells in the same
      // green so the two modes differ only in whether reach is called out.
      var flat = document.createElement("canvas"); flat.width = g.nx; flat.height = g.ny;
      var fimg = flat.getContext("2d").createImageData(g.nx, g.ny), fd = fimg.data;
      for (var j = 0; j < cells.length; j++) {
        if (!cells[j]) continue;
        var fo = j * 4; fd[fo] = 63; fd[fo + 1] = 185; fd[fo + 2] = 80; fd[fo + 3] = 60;
      }
      flat.getContext("2d").putImageData(fimg, 0, 0);
      out.push({ reach: cv, free: flat });
    }
    return { grid: g, layers: out, pads: res.pads || [] };
  }

  // Ask the server for the mask at frame `i`. Debounced and generation-guarded:
  // a scrub storm collapses to one request, and a reply for a superseded
  // attempt or frame is dropped rather than painted over the current one.
  function visionFetch(i) {
    if (!vision.mode || !vision.pass || !data || !data.timeline[i]) return;
    if (vision.cache[i]) return;
    var ev = data.timeline[i];
    if (!ev.net) { visionNote("— this step routes no single net"); return; }
    if (!window.PCBBoardBody) return;
    var gen = vision.gen;
    var body = window.PCBBoardBody();
    body.net = ev.net;
    body.pass = vision.pass;
    body.event_tracks = ev.tracks || [];
    body.event_vias = ev.vias || [];
    visionNote("— reading the grid…");
    fetch("/api/route-vision/" + encodeURIComponent(PCB.name), {
      method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body)
    }).then(function (r) {
      if (!r.ok) return r.text().then(function (t) { throw new Error(t || ("HTTP " + r.status)); });
      return r.json();
    }).then(function (j) {
      if (gen !== vision.gen) return;   // a reset (new attempt / new load) raced us
      visionCachePut(i, visionBitmaps(j));
      visionNote("");
      if (frame === i && window.PCBRepaint) window.PCBRepaint();
    }).catch(function (e) {
      if (gen !== vision.gen) return;
      visionNote("— " + (e && e.message ? String(e.message).slice(0, 60) : "unavailable"));
    });
  }

  function visionSchedule() {
    if (vision.timer) clearTimeout(vision.timer);
    vision.timer = setTimeout(function () { vision.timer = null; visionFetch(frame); }, 180);
  }

  // Wash the current frame's mask under the replay copper.
  function visionPaint(ctx) {
    if (!vision.mode) return;
    var got = vision.cache[frame]; if (!got) return;
    var layer = window.PCBActiveLayer ? window.PCBActiveLayer() : 0;
    var bmp = got.layers[Math.min(layer, got.layers.length - 1)]; if (!bmp) return;
    var g = got.grid, half = g.g / 2;
    ctx.save();
    ctx.imageSmoothingEnabled = false;   // a grid node is a cell, not a gradient
    ctx.drawImage(vision.mode === 2 ? bmp.reach : bmp.free,
      X(g.ox - half), Y(g.oy - half), g.nx * g.g * S, g.ny * g.g * S);
    // In reach mode, ring the net's own pads the flood never got to: those are
    // stranded by geometry, which no amount of re-running the router will fix.
    if (vision.mode === 2) {
      ctx.lineWidth = 2; ctx.strokeStyle = "#f85149";
      got.pads.forEach(function (p) {
        if (p.reached) return;
        ctx.beginPath(); ctx.arc(X(p.x), Y(p.y), Math.max(0.5 * S, 4), 0, 6.2832); ctx.stroke();
      });
    }
    ctx.restore();
  }

  var visionSel = $("rp-vision");
  if (visionSel) visionSel.addEventListener("change", function () {
    vision.mode = parseInt(visionSel.value, 10) || 0;
    if (!vision.mode) { visionNote(""); if (window.PCBRepaint) window.PCBRepaint(); return; }
    if (!vision.pass) { visionNote("— re-run Route to record the grid"); return; }
    visionFetch(frame);
    if (window.PCBRepaint) window.PCBRepaint();
  });

  function overlayPaint(ctx) {
    if (!overlayOn || !data || !data.timeline.length) return;
    var ev = data.timeline[frame]; if (!ev) return;
    visionPaint(ctx);   // the router's view sits UNDER the copper it produced
    // In exclusive view the replay copper is the ONLY copper on the board, so the
    // base (non-active) tracks/vias come up to normal layer alpha — reading like a
    // real board — instead of the 0.26 dim used when the overlay sat on top of the
    // board's own copper. The active-net amber emphasis stays layered on top. The
    // final-frame DRC markers (never written to PCB.drc) draw only on the last step.
    var drc = (frame === data.timeline.length - 1 && data.final && data.final.drc)
      ? data.final.drc : null;
    paintFrame(ctx, ev, (data && data.nets) || [], { drc: drc });
  }
  // ── Exclusive view mode (enter on a loaded replay, exit on Clear/Adopt) ──
  // While active the board's own copper rendering is hidden (PCBOverlay.exclusive)
  // so only the replay frame shows; a chip announces the mode and the tools that
  // would fight the overlay for the board's copper are disabled.

  // Tool gating: Route, pour-refill, the ✎ Draw toggle, and Save/Update. Each
  // button's prior disabled state is remembered so exit restores it exactly.
  var GATED = ["r-go", "pcb-pour", "pcb-draw", "pcb-saveas", "pcb-update"];
  var gatePrev = {};
  function gateTools(on) {
    if (on) {
      // Force-exit an in-flight Draw session before disabling its toggle, else
      // the board is left in draw mode with no button to leave it.
      var db = $("pcb-draw");
      if (db && db.classList.contains("on") && !db.disabled) db.click();
      GATED.forEach(function (id) {
        var e = $(id); if (!e) return;
        if (!(id in gatePrev)) gatePrev[id] = e.disabled;
        e.disabled = true;
      });
    } else {
      GATED.forEach(function (id) {
        var e = $(id); if (e && (id in gatePrev)) e.disabled = gatePrev[id];
      });
      gatePrev = {};
    }
  }

  // Mode chip — an amber "REPLAY · frame N/M · R/T routed" badge docked in the
  // scorebar (.pcb-bar) alongside the source/score chips; falls back to the
  // panel head when the bar is absent (embed). Removed (hidden) on exit.
  var chip = null;
  function ensureChip() {
    if (chip) return chip;
    chip = document.createElement("span");
    chip.id = "rp-mode-chip"; chip.className = "rp-mode-chip";
    var bar = document.querySelector(".pcb-bar");
    if (bar) bar.insertBefore(chip, bar.firstChild);
    else panel.insertBefore(chip, panel.firstChild);
    return chip;
  }
  function updateChip() {
    if (!overlayOn || !data || !data.timeline.length) return;
    var ev = data.timeline[frame] || {};
    ensureChip().textContent = (live.on ? "LIVE ROUTE" : "REPLAY") + " · frame " + (frame + 1) + "/" +
      data.timeline.length + " · " + (ev.routed || 0) + "/" + (ev.total || 0) + " routed";
    chip.hidden = false;
  }
  function hideChip() { if (chip) chip.hidden = true; }

  function enterMode() {
    if (!data) return;
    overlayOn = true;
    window.PCBOverlay = window.PCBOverlay || { paint: null };
    window.PCBOverlay.paint = overlayPaint;
    window.PCBOverlay.exclusive = true;
    var gc = $("rp-ghost"); window.PCBOverlay.ghost = !!(gc && gc.checked);
    gateTools(true);
    updateChip();
    if (window.PCBRepaint) window.PCBRepaint();
  }
  function exitMode() {
    overlayOn = false;
    if (window.PCBOverlay) {
      window.PCBOverlay.paint = null;
      window.PCBOverlay.exclusive = false;
      window.PCBOverlay.ghost = false;
    }
    gateTools(false);
    hideChip();
    if (window.PCBSelNet) window.PCBSelNet(null);
    if (window.PCBRepaint) window.PCBRepaint();
  }
  // Re-enter the mode when the user scrubs/plays after a Clear (data kept).
  function ensureArmed() { if (data && !overlayOn) enterMode(); }

  // ── Playback ──────────────────────────────────────────────────────────
  function setFrame(i, autoScroll) {
    if (!data || !data.timeline.length) return;
    frame = Math.max(0, Math.min(data.timeline.length - 1, i));
    var ev = data.timeline[frame], prev = frame ? data.timeline[frame - 1] : null;
    var sl = $("rp-slider"); if (sl) sl.value = String(frame);
    renderSummary(ev);
    renderDeltas(ev, prev);
    var log = $("rp-log");
    if (log) {
      Array.prototype.forEach.call(log.querySelectorAll("li.active"), function (el) {
        el.classList.remove("active"); el.style.background = "";
      });
      var active = log.querySelector('[data-step="' + frame + '"]');
      if (active) {
        expandGroupOf(active);
        active.classList.add("active");
        active.style.background = "rgba(240,183,47,0.14)"; // visible even without panel CSS
        if (autoScroll) active.scrollIntoView({ block: "nearest" });
      }
    }
    visionSchedule();
    // Track the ratsnest/board highlight to the log's active net.
    if (ev.net && window.PCBSelNet) window.PCBSelNet(ev.net);
    updateChip();
    if (window.PCBRepaint) window.PCBRepaint();
    if (playing && frame === data.timeline.length - 1) stop();
  }
  function play() {
    if (!data) return;
    ensureArmed();
    if (frame >= data.timeline.length - 1) setFrame(0, true);
    playing = true;
    var pb = $("rp-play"); if (pb) pb.textContent = "Pause";
    timer = setInterval(function () { setFrame(frame + 1, true); }, 650);
  }
  function stop() {
    playing = false;
    var pb = $("rp-play"); if (pb) pb.textContent = "Play";
    if (timer) { clearInterval(timer); timer = null; }
  }

  // ── Load a review result (from Run or from cache) ─────────────────────
  function loadReview(j) {
    stop();
    revealReplay();
    data = j;
    visionReset();
    visionLatch(data.timeline && data.timeline[0]);
    if (!Array.isArray(data.timeline) || !data.timeline.length) {
      data.timeline = [{
        seq: 0, kind: "complete", net: null, related: [], round: 0,
        routed: (data.final && data.final.routed) || 0,
        total: (data.final && data.final.total) || 0,
        trace_mm: 0, tracks: [], vias: []
      }];
    }
    adopted = false;
    var ad = $("rp-adopt"); if (ad) ad.disabled = false;
    var sl = $("rp-slider"); if (sl) { sl.max = String(data.timeline.length - 1); sl.value = "0"; }
    enterMode(); // enter exclusive view: hide the board's own copper, gate tools, show the chip
    buildList();
    setFrame(0, false); // paints the overlay + selects the first frame's net
  }

  // ── Network ───────────────────────────────────────────────────────────
  // ── Adopt: land the replayed final copper on the board ────────────────
  // The ONLY path that touches PCB state — converts the last frame's tuples to
  // PCB-native objects (netIdx→name via nets[]; layer int is already native)
  // and hands them to PCBAdoptCopper, the shared Route-button application path.
  function adopt() {
    if (!data || !data.timeline.length) return;
    if (!window.PCBAdoptCopper) { status("adopt unavailable (editor not ready)", "error"); return; }
    var ev = data.timeline[data.timeline.length - 1];
    var tracks = (ev.tracks || []).map(function (t) {
      return { x1: t[0], y1: t[1], x2: t[2], y2: t[3], l: t[4], w: t[5], net: nm(t[6]) };
    });
    var vias = (ev.vias || []).map(function (v) {
      return { x: v[0], y: v[1], d: v[2], drill: v[3], net: nm(v[4]) };
    });
    var drc = (data.final && data.final.drc)
      ? data.final.drc.map(function (d) {
          return { kind: d.kind, severity: d.severity, x: d.x, y: d.y, gap: d.gap, clearance: d.clearance };
        })
      : [];
    var rfPaths = (data.final && data.final.rf_paths) ? data.final.rf_paths : [];
    // Exit exclusive view FIRST (restore the board's own copper rendering + tools),
    // THEN land the replayed copper so it shows immediately as real board copper.
    exitMode();
    window.PCBAdoptCopper(tracks, vias, drc, rfPaths);
    adopted = true;
    var ad = $("rp-adopt"); if (ad) ad.disabled = true;
    status("adopted " + tracks.length + " tracks / " + vias.length + " vias — Save to persist", "ok");
  }

  // ── Clear: hide the overlay (keeps the fetched data for re-showing) ────
  function clearReplay() {
    stop();
    exitMode(); // leave exclusive view: restore the board's own copper + tools, drop the chip
    status(data ? "replay hidden — scrub or Play to show again" : "", "");
  }

  // ── Live route streaming (Phase 3: merged Route panel) ────────────────────
  // The Route button POSTs /api/route-live/<name>/start and hands the job here.
  // We poll the growing event stream into the SAME player structures (data.timeline
  // + the start response's net table), grow the scrubber, and follow the head until
  // the user scrubs back. On an uncancelled finish we exit the overlay and hand the
  // byte-exact `final` to pcb_board.js (window.PCBApplyRouteResult, via onFinal); a
  // cancelled finish keeps the partial overlay + timeline and enables Adopt.

  // Dock controls that must NOT fire mid-stream (they'd load a different run or
  // start an interactive session) — the scrubber (prev/play/next/slider) stays
  // live so the user can scrub back. Prior disabled state is restored on finish.
  var LIVE_LOCK = ["rp-clear", "rp-adopt"];
  var liveLockPrev = {};
  function liveLock(on) {
    if (on) LIVE_LOCK.forEach(function (id) { var e = $(id); if (!e) return; if (!(id in liveLockPrev)) liveLockPrev[id] = e.disabled; e.disabled = true; });
    else { LIVE_LOCK.forEach(function (id) { var e = $(id); if (e && (id in liveLockPrev)) e.disabled = liveLockPrev[id]; }); liveLockPrev = {}; }
  }
  function showStop(on) { var b = $("r-stop"); if (!b) return; b.hidden = !on; b.disabled = !on; }
  // The Route panel's own status span (pcb_board.js's setStat is private to its
  // IIFE, so replicate its `route-stat` class contract here).
  function routeStat(cls, txt) { var e = $("r-stat"); if (e) { e.className = "route-stat" + (cls ? (" " + cls) : ""); e.textContent = txt; } }

  function liveResetTimeline(nets) {
    data = { ok: true, mode: "design", nets: nets || [], timeline: [], final: null };
    frame = 0; live.logSeq = 0;
    visionReset();
    var sl = $("rp-slider"); if (sl) { sl.max = "0"; sl.value = "0"; }
    var log = $("rp-log"); if (log) log.textContent = "";
    var sum = $("rp-summary"); if (sum) sum.textContent = "";
    var del = $("rp-deltas"); if (del) del.textContent = "";
    var ad = $("rp-adopt"); if (ad) ad.disabled = true;
  }
  // Follow-head control: any manual scrub (slider/prev/next) drops follow; the
  // Play button or scrubbing back to the head re-arms it.
  function liveUnfollow() { if (live.on) live.follow = false; }
  function liveRefollowIfHead() { if (live.on && data && frame >= data.timeline.length - 1) live.follow = true; }

  // Begin watching a live-route job — a fresh Route start, a 409 attach (nets
  // null: paint without per-net emphasis), or a page-init reattach.
  function liveBegin(gen, nets, opts) {
    stop();
    // Bump the poll token so any poll loop from an earlier begin (e.g. a reattach
    // followed by a Route click that 409-attaches) stops instead of double-ingesting.
    live.seq++;
    live.on = true; live.gen = gen; live.attempt = 0; live.since = 0;
    live.misses = 0; live.follow = true;
    live.onFinal = (opts && opts.onFinal) || null;
    liveResetTimeline(nets);
    // Reset the Route button's remembered disabled state to enabled so exitMode
    // (which restores gateTools' snapshot) leaves it clickable after the run.
    ["r-go"].forEach(function (id) { var b = $(id); if (b) b.disabled = false; });
    enterMode();          // exclusive overlay (the empty timeline paints nothing yet)
    liveLock(true);
    showStop(true);
    status("streaming live route — scrub to inspect, Stop to halt", "running");
    routeStat("running", "starting the router…");
    livePoll(live.seq);
  }

  function liveGiveUp(msg) {
    live.on = false; live.follow = true;
    showStop(false); liveLock(false);
    routeStat("err", msg);
    ["r-go"].forEach(function (id) { var b = $(id); if (b) b.disabled = false; });
  }

  // ~300ms poll loop (mirrors pcb_board.js's livePoll idiom: give up after N
  // consecutive misses). A full 200-event batch means more is waiting, so re-poll
  // immediately; else back off to ~300ms.
  function livePoll(token) {
    if (!live.on || token !== live.seq) return;
    fetch("/api/route-live/" + encodeURIComponent(PCB.name) +
          "?since=" + live.since + "&attempt=" + live.attempt)
      .then(function (r) { if (r.status === 404) throw new Error("__nojob__"); return r.json(); })
      .then(function (j) { if (token === live.seq) { live.misses = 0; liveIngest(j, token); } })
      .catch(function (e) {
        if (token !== live.seq) return; // a newer begin superseded this loop
        if (e && e.message === "__nojob__") { liveGiveUp("live route job disappeared"); return; }
        live.misses++;
        if (live.misses > 20) { liveGiveUp("lost contact with the live router — press Route to retry"); return; }
        setTimeout(function () { livePoll(token); }, 700);
      });
  }

  function liveIngest(j, token) {
    if (!live.on || token !== live.seq) return;
    live.gen = j.gen;
    // Finer-grid restart: the server bumped the attempt and re-streamed from 0.
    // Discard the local timeline and adopt the new attempt (events below are 0-based).
    if (j.attempt !== live.attempt) { live.attempt = j.attempt; liveResetTimeline(data.nets); }
    if (j.events && j.events.length) {
      for (var i = 0; i < j.events.length; i++) {
        visionLatch(j.events[i]);   // a second `.initial` = finer-grid restart: re-lattice
        data.timeline.push(j.events[i]);
      }
      liveAppendLog();
      var last = data.timeline.length - 1;
      var sl = $("rp-slider"); if (sl) sl.max = String(last < 0 ? 0 : last);
      if (live.follow) setFrame(last, true); else liveRefollowIfHead();
    }
    live.since = j.next;
    liveStatusEnvelope(j);
    if (j.done) { liveFinish(j); return; }
    setTimeout(function () { livePoll(token); }, (j.events && j.events.length >= 200) ? 0 : 300);
  }

  // Incremental FLAT decision-log append while streaming (buildList's grouped
  // view is O(n) and resets collapse/scroll state — too heavy per 200-event burst).
  // Each <li> carries the data-step the active-frame highlight needs; buildList()
  // replaces this with the grouped view once the run finishes.
  function liveAppendLog() {
    var log = $("rp-log"); if (!log) return;
    var frag = document.createDocumentFragment();
    for (; live.logSeq < data.timeline.length; live.logSeq++) {
      var ev = data.timeline[live.logSeq];
      var t = eventText(ev);
      var li = document.createElement("li");
      li.setAttribute("data-step", String(live.logSeq));
      var seq = document.createElement("span"); seq.className = "seq"; seq.textContent = String(live.logSeq + 1);
      var dotEl = document.createElement("span"); dotEl.className = "dot " + dotClass(ev.kind);
      var name = document.createElement("span"); name.className = "event-name"; name.textContent = t[1];
      var meta = document.createElement("span"); meta.className = "event-meta";
      meta.textContent = (ev.routed || 0) + "/" + (ev.total || 0);
      li.appendChild(seq); li.appendChild(dotEl); li.appendChild(name); li.appendChild(meta);
      (function (idx) { li.addEventListener("click", function () { stop(); liveUnfollow(); ensureArmed(); setFrame(idx, false); }); })(live.logSeq);
      frag.appendChild(li);
    }
    log.appendChild(frag);
    if (live.follow) log.scrollTop = log.scrollHeight;
  }

  // Live progress line in the ROUTE panel's status span: newest event's wording +
  // running count + rip-up round + elapsed. `total` stays null until done (the
  // mid-run event total is 0 — never shown). A non-fatal envelope err (sink OOM)
  // shows as a warn note in the dock's own status without stopping the stream.
  function liveStatusEnvelope(j) {
    var ev = data.timeline.length ? data.timeline[data.timeline.length - 1] : null;
    var bits = [];
    if (ev) bits.push(eventText(ev)[1]);
    bits.push((j.routed || 0) + " routed");
    if (ev && ev.round) bits.push("round " + ev.round);
    bits.push(((j.elapsed_ms || 0) / 1000).toFixed(1) + "s");
    routeStat("running", bits.join(" · "));
    if (j.err) status("⚠ " + j.err + " — still routing", "warn");
  }

  function liveFinish(j) {
    live.on = false;
    revealReplay(); // surface Adopt/Clear and the finished route steps
    showStop(false); liveLock(false);
    if (j.final) data.final = j.final;
    buildList(); // final grouped decision log replaces the flat live one
    var routed = (j.final && j.final.routed != null) ? j.final.routed : (j.routed || 0);
    var total = (j.final && j.final.total != null) ? j.final.total : (j.total != null ? j.total : 0);
    if (j.cancelled) {
      // Partial board: keep the overlay + timeline, DON'T auto-apply. Adopt lands
      // the last frame's copper; Route stays gated until Adopt/Clear exits the view.
      if (live.follow) setFrame(data.timeline.length - 1, true);
      var ad = $("rp-adopt"); if (ad) ad.disabled = false;
      routeStat("warn", "cancelled — partial " + routed + "/" + total);
      status("cancelled — Adopt to keep the partial copper, or Clear", "warn");
    } else {
      // Uncancelled: exit the exclusive overlay, then let pcb_board.js land the
      // byte-exact `final` exactly like a blocking Route (copper + DRC + stuck).
      exitMode();
      if (live.onFinal) live.onFinal(j.final || {});
      // Timeline stays loaded: scrubbing re-enters exclusive view (the board copper
      // IS the final anyway), and Adopt/Clear return to the live board.
      var ad2 = $("rp-adopt"); if (ad2) ad2.disabled = false;
      status("live route complete · " + routed + "/" + total + " nets — scrub to review", "ok");
    }
  }

  // Page-init reattach: resume watching a live route still running for this design
  // (a reload mid-run, or another tab driving it). A 404 or a finished/cancelled
  // job does nothing — the board keeps its saved copper.
  function liveReattach() {
    fetch("/api/route-live/" + encodeURIComponent(PCB.name) + "?since=0&attempt=0")
      .then(function (r) { if (r.status === 404) return null; return r.json(); })
      .then(function (j) { if (j && j.running) liveBegin(j.gen, null, { onFinal: window.PCBApplyRouteResult }); })
      .catch(function () { });
  }

  // ── Wiring (no global keyboard bindings — the editor owns the keymap) ──
  function onClick(id, fn) { var e = $(id); if (e) e.addEventListener("click", fn); }
  onClick("rp-adopt", adopt);
  onClick("rp-clear", clearReplay);
  // Scrubbing during a live stream drops follow-head; landing back on the head re-arms it.
  onClick("rp-prev", function () { stop(); liveUnfollow(); ensureArmed(); setFrame(frame - 1, true); liveRefollowIfHead(); });
  onClick("rp-next", function () { stop(); liveUnfollow(); ensureArmed(); setFrame(frame + 1, true); liveRefollowIfHead(); });
  onClick("rp-play", function () {
    if (live.on) { live.follow = true; setFrame(data.timeline.length - 1, true); return; } // re-follow the head
    ensureArmed(); if (playing) stop(); else play();
  });
  var slider = $("rp-slider");
  if (slider) slider.addEventListener("input", function () {
    stop(); liveUnfollow(); ensureArmed(); setFrame(parseInt(this.value, 10) || 0, false); liveRefollowIfHead();
  });
  // Stop: trip the live route's cooperative cancel; the job still finishes to a
  // partial result (done + cancelled), which liveFinish keeps for Adopt.
  onClick("r-stop", function () {
    var b = $("r-stop"); if (b) b.disabled = true; // debounce; keep polling
    status("stopping — finishing the current net…", "running");
    routeStat("running", "stopping…");
    fetch("/api/route-live/" + encodeURIComponent(PCB.name) + "/cancel", { method: "POST" }).catch(function () { });
  });
  // Ghost-saved-copper toggle: only meaningful while exclusive mode is active,
  // but wiring the flag live lets it take effect the instant it's flipped.
  var ghostCb = $("rp-ghost");
  if (ghostCb) ghostCb.addEventListener("change", function () {
    if (window.PCBOverlay) window.PCBOverlay.ghost = this.checked;
    if (window.PCBRepaint) window.PCBRepaint();
  });

  // Adopt starts disabled until a result is loaded.
  var ad0 = $("rp-adopt"); if (ad0) ad0.disabled = true;

  // ── Shared surface for pcb_route_session.js (interactive route view) ──────
  // The route session lives in a sibling IIFE (pcb_route_session.js). Rather
  // than duplicate the copper painter, coordinate math, tool-gating, decision-
  // log text, and the scorebar mode chip, expose them here so both players draw
  // the same board and read as one dock. Everything below is stateless w.r.t.
  // this module's playback state (the chip setter is the only shared UI object,
  // and the two players are mutually exclusive, so one #rp-mode-chip is safe).
  window.PCBReplayShared = {
    S: S, X: X, Y: Y,
    layerColor: layerColor,
    paintFrame: paintFrame,       // (ctx, ev, nets, opts) → draws one copper frame
    screenToWorld: screenToWorld, // (clientX, clientY) → world mm
    gateTools: gateTools,         // (on) → disable/restore the board's copper tools
    eventText: eventText,         // (ev, opts) → [phase, title, detail]
    dotClass: dotClass,           // (kind) → decision-log dot class
    labels: labels,               // event-kind → label table (incl. stuck / hint_applied)
    setModeChip: function (t) { ensureChip().textContent = t; chip.hidden = false; },
    clearModeChip: hideChip
  };

  // ── Live-route driver surface (called by the Route button in pcb_board.js) ──
  window.PCBLiveRoute = {
    begin: liveBegin,                       // (gen, nets|null, {onFinal}) → watch a job
    running: function () { return live.on; } // is a live stream in flight
  };
  // On page load, reattach to a live route still running for this design.
  liveReattach();
})();
