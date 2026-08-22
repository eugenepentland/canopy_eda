// pcb_stuck.js — the Stuck-nets panel of the /pcb-layout sidebar.
//
// Renders the `stuck[]` block that POST /api/pcb-route returns beside the
// copper (route_diagnose.capture, serialized by serve/stuck_json.zig): one
// card per net the router could not connect, carrying its inferred failure
// mode, the foreign copper ringing its search frontier, and the ranked
// remedies — each tagged `dsl` (a paste-ready constraint-DSL snippet) or
// `code` (a router limitation no DSL edit will fix).
//
// It NEVER routes: a full board is minutes of work, so the panel is a pure
// consumer of the response the Route button already paid for, handed over by
// pcb_board.js through window.PCBStuckUpdate.
//
// Contract marker strings (grepped by tests): panel-stuck PCBStuckUpdate
// PCBSelNet sk-copy sk-target-code
(function () {
  "use strict";

  var panel = document.getElementById("panel-stuck");
  if (!panel) return;

  var $ = function (id) { return document.getElementById(id); };
  var list = $("sk-list"), empty = $("sk-empty"), count = $("sk-count");

  // Human wording for the failure_mode tag route_diagnose emits. Unknown tags
  // fall through to the raw tag, so a new router mode still renders.
  var MODE_TITLE = {
    order_congestion: "Routed too late — the copper in its way arrived first",
    blocked_by_higher: "Walled in by copper the router will not rip up",
    search_budget: "The maze search ran out of budget before it connected",
    escape_blocked: "The net cannot escape its own pad/footprint",
    grid_quantization: "A corridor exists but is narrower than the routing grid"
  };

  function el(tag, cls, text) {
    var e = document.createElement(tag);
    if (cls) e.className = cls;
    if (text !== undefined && text !== null) e.textContent = String(text);
    return e;
  }

  // Board highlight seam — the idempotent select pcb_board.js publishes for
  // panels (selNet() itself toggles, which would flicker on re-click).
  function flashNet(net) {
    if (net && window.PCBSelNet) window.PCBSelNet(net);
  }

  function copyBtn(text) {
    var b = el("button", "sk-copy", "Copy");
    b.title = "Copy this snippet to the clipboard";
    b.addEventListener("click", function () {
      var done = function () {
        b.textContent = "Copied ✓"; b.classList.add("done");
        setTimeout(function () { b.textContent = "Copy"; b.classList.remove("done"); }, 1400);
      };
      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(text).then(done, function () { b.textContent = "Copy failed"; });
        return;
      }
      // http:// origins and old browsers have no async clipboard — fall back
      // to a throwaway textarea so the snippet is still one click away.
      var ta = document.createElement("textarea");
      ta.value = text; ta.setAttribute("readonly", "");
      ta.style.position = "fixed"; ta.style.left = "-9999px";
      document.body.appendChild(ta); ta.select();
      try { document.execCommand("copy"); done(); } catch (e) { b.textContent = "Copy failed"; }
      document.body.removeChild(ta);
    });
    return b;
  }

  function blockerChip(b) {
    var net = b && b.net ? String(b.net) : "?";
    var lyr = b && b.layer ? String(b.layer) : "?";
    var rippable = !(b && b.rippable === false);
    var chip = el("button", "sk-bl" + (rippable ? "" : " sk-locked"));
    chip.setAttribute("data-sk-net", net);
    chip.appendChild(document.createTextNode((rippable ? "" : "🔒 ") + net + "@" + lyr + " "));
    chip.appendChild(el("span", "sh", "(" + Math.round((+b.share || 0) * 100) + "%)"));
    chip.title = (rippable
      ? "Rippable — the router may tear this up and re-route it"
      : "Protected — a plane/pour or higher-priority net the router will not move") +
      "\nCentroid " + (+b.x || 0).toFixed(1) + ", " + (+b.y || 0).toFixed(1) + " mm" +
      "\nClick to highlight this net on the board";
    chip.addEventListener("click", function () { flashNet(net); });
    return chip;
  }

  function remedyItem(rm) {
    var li = document.createElement("li");
    var head = el("div", "sk-rem-h");
    head.appendChild(el("span", "sk-rem-n"));
    head.appendChild(el("span", "sk-kind", String(rm.kind || "fix").replace(/_/g, " ")));
    var code = rm.target === "code";
    head.appendChild(el("span", "sk-target" + (code ? " sk-target-code" : ""), code ? "code" : "dsl"));
    if (rm.confidence) head.appendChild(el("span", "sk-conf", rm.confidence + " confidence"));
    li.appendChild(head);
    if (rm.rationale) li.appendChild(el("p", "sk-rat", rm.rationale));
    if (rm.dsl) {
      var row = el("div", "sk-code");
      row.appendChild(el("pre", null, rm.dsl));
      row.appendChild(copyBtn(rm.dsl));
      li.appendChild(row);
    } else {
      li.appendChild(el("p", "sk-nodsl",
        code ? "Router limitation — needs a code change, no DSL edit will help."
          : "No DSL snippet for this remedy."));
    }
    return li;
  }

  function card(d) {
    var li = el("li", "sk-card");
    var head = el("div", "sk-head");
    var net = String(d.net || "?");
    var nb = el("button", "sk-net", net);
    nb.title = "Highlight " + net + " on the board";
    nb.addEventListener("click", function () { flashNet(net); });
    head.appendChild(nb);
    var mode = String(d.failure_mode || "unknown");
    var badge = el("span", "sk-mode sk-mode-" + mode, mode.replace(/_/g, " "));
    badge.title = MODE_TITLE[mode] || mode;
    head.appendChild(badge);
    li.appendChild(head);
    if (d.why) li.appendChild(el("p", "sk-why", d.why));

    var blockers = d.blockers || [];
    if (blockers.length) {
      li.appendChild(el("span", "sk-k", "In the way"));
      var row = el("div", "sk-blockers");
      blockers.forEach(function (b) { row.appendChild(blockerChip(b)); });
      li.appendChild(row);
    }
    var remedies = d.remedies || [];
    if (remedies.length) {
      li.appendChild(el("span", "sk-k", "Try this"));
      var ol = el("ol", "sk-rem");
      remedies.forEach(function (rm) { ol.appendChild(remedyItem(rm)); });
      li.appendChild(ol);
    }
    return li;
  }

  // Chip label mirror — the accordion chip carries the same count so the panel
  // advertises itself without being opened.
  function chipCount(n, routed) {
    var chip = document.querySelector('.tab-chip[data-panel="panel-stuck"]');
    if (!chip) return;
    chip.textContent = routed ? ("Stuck · " + n) : "Stuck";
    chip.classList.toggle("sk-chip-hot", n > 0);
  }

  // Public seam pcb_board.js calls with the route response's stuck[] (an empty
  // array after a clean route, so the panel can say so).
  window.PCBStuckUpdate = function (stuck) {
    var arr = stuck && stuck.length ? stuck : [];
    list.innerHTML = "";
    count.textContent = arr.length ? "· " + arr.length : "· 0";
    count.className = "sk-count" + (arr.length ? "" : " ok");
    empty.hidden = arr.length > 0;
    if (!arr.length) empty.innerHTML = "No stuck nets — everything routed.";
    arr.forEach(function (d) { list.appendChild(card(d)); });
    chipCount(arr.length, true);
  };
})();
