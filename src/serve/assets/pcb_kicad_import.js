(function () {
  "use strict";

  // Whole-design pages only: the import reads the design's own .kicad_pcb, so
  // it has nothing to say on a module page or a ?sub scoped sub circuit.
  if (typeof PCB === "undefined" || !PCB.top_design) return;
  // Layer spellings come from the blob (PCB.layer_names, emitted out of
  // src/board_layers.zig) — this panel names no KiCad layer of its own.
  var LN = PCB.layer_names || {};
  var settings = document.getElementById("pcb-settings");
  if (!settings) return;

  function make(tag, id, className, text) {
    var node = document.createElement(tag);
    if (id) node.id = id;
    if (className) node.className = className;
    if (text) node.textContent = text;
    return node;
  }

  // The full editor supplies these inside its Fabrication menu; editable
  // embeds retain the classic behavior and let this script create them beside
  // Settings.  Reusing existing controls avoids duplicate ids and lets the
  // page shell decide their visual hierarchy without duplicating this modal.
  var trigger = document.getElementById("pcb-kicad-import");
  var triggerCreated = !trigger;
  if (!trigger) trigger = make("button", "pcb-kicad-import", "btn", "⇣ Sync from KiCad");
  trigger.title = "Preview and import placement, routed copper, vias, and " + LN.edge_cuts +
    " from this design's read-only KiCad PCB";
  if (triggerCreated) settings.insertAdjacentElement("afterend", trigger);
  var pushTrigger = document.getElementById("pcb-kicad-push");
  var pushCreated = !pushTrigger;
  if (!pushTrigger) pushTrigger = make("button", "pcb-kicad-push", "btn", "⇡ Push to KiCad");
  pushTrigger.title = "Preview and push this saved netlisp layout's placement, routed copper, vias, and " +
    LN.edge_cuts + " into KiCad";
  if (pushCreated) trigger.insertAdjacentElement("afterend", pushTrigger);

  var modal = make("div", "kicad-import-modal", "court-modal");
  modal.hidden = true;
  var dialog = make("div", null, "court-dialog fab-dialog");
  var head = make("div", null, "court-h");
  var title = make("span", "kicad-import-title", null, "Sync from KiCad");
  var close = make("button", "kicad-import-x", "court-x", "×");
  close.title = "Close";
  var body = make("div", "kicad-import-body", "fab-body");
  var actions = make("div", null, "court-actions");
  var go = make("button", "kicad-import-go", "btn", "Import into netlisp");
  var cancel = make("button", "kicad-import-cancel", "btn", "Cancel");
  head.appendChild(title);
  head.appendChild(close);
  actions.appendChild(go);
  actions.appendChild(cancel);
  dialog.appendChild(head);
  dialog.appendChild(body);
  dialog.appendChild(actions);
  modal.appendChild(dialog);
  document.body.appendChild(modal);
  var preview = null;

  function endpoint(dryRun) {
    return "/api/import-kicad-layout/" + encodeURIComponent(PCB.name) +
      (dryRun ? "?dry_run=1" : "");
  }

  function request(dryRun) {
    var options = { method: "POST", headers: { "Content-Type": "application/json" } };
    if (!dryRun) options.body = JSON.stringify({ rev: PCB.rev || 0 });
    return fetch(endpoint(dryRun), options).then(function (response) {
      return response.text().then(function (text) {
        var data = null;
        try { data = JSON.parse(text); } catch (_) {}
        if (!response.ok) {
          var err = new Error((data && data.error) || text || "KiCad import failed");
          err.status = response.status;
          err.data = data;
          throw err;
        }
        return data;
      });
    });
  }

  function flushEditor() {
    if (typeof window.PCBFlushLayout !== "function") return Promise.resolve("clean");
    return window.PCBFlushLayout().then(function (result) {
      if (result === "failed" || result === "conflict" || result === "invalid" || result === "skipped") {
        // "skipped" = dirty edits held back by the unplaced-parts autosave
        // gate — an explicit Save (which accepts the staging) clears it.
        throw new Error("Save the current netlisp layout before syncing from KiCad.");
      }
      return result;
    });
  }

  function addText(className, text) {
    var row = document.createElement("div");
    row.className = className;
    row.textContent = text;
    body.appendChild(row);
  }

  function addList(label, items, formatter) {
    if (!items || !items.length) return;
    addText("fab-sec warn", label + " (" + items.length + ")");
    var list = document.createElement("ul");
    items.forEach(function (item) {
      var li = document.createElement("li");
      li.textContent = formatter ? formatter(item) : String(item);
      list.appendChild(li);
    });
    body.appendChild(list);
  }

  function renderReport(data) {
    body.textContent = "";
    var report = data.report || {};
    var match = report.match || {};
    var netMap = report.net_map || {};
    var copper = report.copper || {};
    var zones = report.zones || {};
    var stats = data.stats || {};
    var matched = (match.by_uuid || 0) + (match.by_ref || 0);

    addText("fab-sec ok", "Ready to inspect in the netlisp PCB editor");
    addText("fab-stats", (stats.parts || 0) + " parts · " +
      (stats.tracks || 0) + " tracks · " + (stats.vias || 0) + " vias · " +
      (stats.outline_points || 0) + " outline points");
    addText("court-note", "Source: " + (data.board_path || "declared KiCad PCB") +
      ". The KiCad file stays read-only. Import replaces the netlisp tool's starred layout; the previous netlisp layout is kept in layout history.");
    addText("fab-sec", "Identity and net mapping");
    addText("fab-stats", matched + " footprints matched (" + (match.by_uuid || 0) +
      " by stable ID, " + (match.by_ref || 0) + " by reference) · " +
      (netMap.identical || 0) + " nets unchanged · " + (netMap.renamed || 0) + " renamed");

    addList("KiCad footprints with no design instance", match.unmatched_board);
    addList("Design instances absent from the KiCad board", match.unmatched_design);
    addList("Ambiguous KiCad nets kept under their original name", netMap.ambiguous,
      function (item) { return item.board + " → " + (item.candidates || []).join(", "); });
    addList("KiCad nets with no matching design pads", netMap.unmatched);
    addList("Copper dropped from non-signal layers", copper.dropped,
      function (item) { return item.layer + " · " + item.net + " · " + Number(item.length_mm || 0).toFixed(2) + " mm"; });

    if (copper.non_through_vias) addText("fab-sec warn",
      copper.non_through_vias + " blind/buried or unusual-span vias are displayed as through vias");
    if ((zones.zones || []).length) addText("fab-sec warn",
      zones.zones.length + " KiCad zones/keepouts are reported but not rendered as imported copper");
    addList("Pour-fed nets need their KiCad zones for connectivity", zones.pour_fed);
    if (report.outline && report.outline.fallback) addText("fab-sec warn",
      LN.edge_cuts + " did not form one closed loop; the importer will display its bounding rectangle.");
  }

  function showError(error) {
    body.textContent = "";
    addText("fab-sec err", "Could not sync from KiCad");
    addText("court-note", error && error.message ? error.message : "Unknown import error");
    go.disabled = true;
    title.textContent = "Sync from KiCad — error";
    modal.hidden = false;
  }

  function setBusy(on, label) {
    trigger.disabled = on;
    if (on) go.disabled = true;
    if (label) trigger.textContent = label;
    else trigger.textContent = "⇣ Sync from KiCad";
  }

  function dismiss() {
    modal.hidden = true;
    preview = null;
    go.disabled = false;
    title.textContent = "Sync from KiCad";
  }

  trigger.addEventListener("click", function () {
    setBusy(true, "Reading KiCad…");
    flushEditor().then(function () { return request(true); }).then(function (data) {
      preview = data;
      renderReport(data);
      modal.hidden = false;
      go.disabled = false;
      title.textContent = "Sync from KiCad — preview";
    }).catch(showError).then(function () { setBusy(false); });
  });

  go.addEventListener("click", function () {
    if (!preview) return;
    setBusy(true, "Importing…");
    go.textContent = "Importing…";
    flushEditor().then(function () { return request(false); }).then(function (data) {
      if (typeof data.rev === "number") PCB.rev = data.rev;
      body.textContent = "";
      addText("fab-sec ok", "KiCad layout imported. Reloading the PCB review…");
      go.hidden = true;
      cancel.hidden = true;
      window.setTimeout(function () { window.location.assign(window.location.pathname); }, 450);
    }).catch(function (error) {
      showError(error);
      if (error && error.status === 409) addText("court-note", "Reload the PCB editor, then preview the KiCad board again.");
      go.textContent = "Import into netlisp";
      setBusy(false);
    });
  });

  close.addEventListener("click", dismiss);
  cancel.addEventListener("click", dismiss);
  modal.addEventListener("click", function (event) { if (event.target === modal) dismiss(); });

  // ---- Authoritative netlisp layout → KiCad handoff ----
  // This is intentionally separate from the schematic page's conservative
  // netlist sync: the latter never moves a placed part; this explicit action
  // replaces layout geometry after a dry-run preview.
  var pushModal = make("div", "kicad-push-modal", "court-modal");
  pushModal.hidden = true;
  var pushDialog = make("div", null, "court-dialog fab-dialog");
  var pushHead = make("div", null, "court-h");
  var pushTitle = make("span", null, null, "Push layout to KiCad");
  var pushClose = make("button", null, "court-x", "×");
  var pushBody = make("div", null, "fab-body");
  var pushActions = make("div", null, "court-actions");
  var pushGo = make("button", null, "btn", "Replace KiCad layout");
  var pushCancel = make("button", null, "btn", "Cancel");
  pushHead.appendChild(pushTitle); pushHead.appendChild(pushClose);
  pushActions.appendChild(pushGo); pushActions.appendChild(pushCancel);
  pushDialog.appendChild(pushHead); pushDialog.appendChild(pushBody); pushDialog.appendChild(pushActions);
  pushModal.appendChild(pushDialog); document.body.appendChild(pushModal);
  var pushPreview = null;
  var pushLayoutName = null;

  function activeLayoutName() {
    return typeof window.PCBActiveLayoutName === "function" ? window.PCBActiveLayoutName() : null;
  }

  function pushRequest(dryRun, layoutName) {
    var query = "?push_layout=1&prune=1&layout=" + encodeURIComponent(layoutName);
    if (dryRun) query += "&dry_run=1";
    return fetch("/api/sync-kicad-pcb/" + encodeURIComponent(PCB.name) + query, {
      method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ rev: PCB.rev || 0 })
    }).then(function (response) {
      return response.text().then(function (text) {
        var data = null;
        try { data = JSON.parse(text); } catch (_) {}
        if (!response.ok) {
          var error = new Error((data && data.error) || text || "KiCad push failed");
          error.status = response.status;
          throw error;
        }
        return data || {};
      });
    });
  }

  function pushText(className, text) {
    var row = make("div", null, className, text);
    pushBody.appendChild(row);
  }

  function renderPushPreview(data) {
    var summary = data.summary || {};
    pushBody.textContent = "";
    pushText("fab-sec ok", "Ready to mirror saved layout “" + pushLayoutName + "” into KiCad");
    pushText("fab-stats", (summary.layout_parts || 0) + " existing footprints moved · " +
      (summary.swapped || 0) + " footprints refreshed · " + (summary.added || 0) + " added · " +
      (summary.removed || 0) + " stale removed · " + (summary.tracks || 0) + " tracks · " +
      (summary.vias || 0) + " vias · " + (summary.outline_edges || 0) + " " + LN.edge_cuts + " segments");
    pushText("fab-sec warn", "This replaces every KiCad track, via, " + LN.edge_cuts + " item, and group. " +
      "Current design footprints are moved/refreshed and stale board footprints are removed. " +
      "Zones, setup/rules, and unrelated drawings are preserved. A timestamped board backup is created first.");
    if (summary.layout_zones) pushText("court-note", summary.layout_zones +
      " netlisp copper pour zone(s), and any netlisp board text, are not exported yet. Existing KiCad zones/text are preserved; refill zones before DRC/Gerber generation.");
    else pushText("court-note", "netlisp board text is not exported yet. Existing KiCad zones/text are preserved; refill zones before DRC/Gerber generation.");
  }

  function dismissPush() {
    pushModal.hidden = true; pushPreview = null; pushLayoutName = null;
    pushGo.hidden = false; pushGo.disabled = false; pushGo.textContent = "Replace KiCad layout";
    pushCancel.textContent = "Cancel";
  }

  pushTrigger.addEventListener("click", function () {
    pushTrigger.disabled = true; pushTrigger.textContent = "Saving layout…";
    flushEditor().then(function () {
      pushLayoutName = activeLayoutName();
      if (!pushLayoutName) throw new Error("Save or load a named netlisp layout before pushing it to KiCad.");
      pushTrigger.textContent = "Previewing…";
      return pushRequest(true, pushLayoutName);
    }).then(function (data) {
      pushPreview = data; renderPushPreview(data); pushModal.hidden = false;
    }).catch(function (error) {
      window.alert(error && error.message ? error.message : "Could not preview the KiCad push.");
    }).then(function () {
      pushTrigger.disabled = false; pushTrigger.textContent = "⇡ Push to KiCad";
    });
  });

  pushGo.addEventListener("click", function () {
    if (!pushPreview || !pushLayoutName) return;
    pushGo.disabled = true; pushGo.textContent = "Writing KiCad…";
    flushEditor().then(function () { return pushRequest(false, pushLayoutName); }).then(function (data) {
      var applied = data.applied || {};
      pushBody.textContent = "";
      pushText("fab-sec ok", data.wrote === false ? "KiCad already matches this layout." : "KiCad layout updated.");
      if (data.wrote === false) pushText("fab-stats", "No board-file write was needed.");
      else pushText("fab-stats", (applied.footprints_moved || 0) + " footprints moved · " +
          (applied.swapped || 0) + " refreshed · " + (applied.added || 0) + " added · " +
          (applied.removed || 0) + " stale removed · " + (applied.tracks_added || 0) + " tracks · " +
          (applied.vias_added || 0) + " vias · " +
          (applied.edge_cuts_added || 0) + " " + LN.edge_cuts + " segments");
      if (data.warning) pushText("fab-sec warn", data.warning);
      pushGo.hidden = true; pushCancel.textContent = "Close";
    }).catch(function (error) {
      pushGo.disabled = false; pushGo.textContent = "Replace KiCad layout";
      pushText("fab-sec err", error && error.message ? error.message : "KiCad push failed");
    });
  });
  pushClose.addEventListener("click", dismissPush);
  pushCancel.addEventListener("click", dismissPush);
  pushModal.addEventListener("click", function (event) { if (event.target === pushModal) dismissPush(); });
})();
