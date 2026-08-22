// Web Worker for the client-side WASM DRC (wave 2). Loads /static/drc.wasm
// (the server's placement/drc.zig engine compiled to wasm32-freestanding) and
// drives its two-call C ABI off the main thread, so a DRC never blocks the UI.
//
// Protocol with the main thread (pcb_board.js):
//   ← {type:"ready"}                 once the wasm instantiates
//   ← {type:"error", error}          instantiate failed → main thread falls back
//   → {type:"check", seq, input}     `input` is the JSON string built by
//                                    drc_marshal.js `buildDrcInput` on the main
//                                    thread (sent as a string to avoid a
//                                    structured-clone of the whole PCB blob)
//   ← {type:"result", seq, resp}     `resp` is the parsed {drc:[…],n:N}
//   ← {type:"result", seq, error}    this check threw (kept non-fatal)
//
// WASM ABI: p = wasm_alloc(len) → write UTF-8 JSON at memory[p..p+len] →
// outLen = drc_check(p, len) → read memory[drc_output_ptr()..+outLen].

var wasm = null;      // WebAssembly.Instance
var mem = null;       // its exported memory
var ready = false;
var initErr = null;

// drc.wasm is freestanding with zero imports (see build.zig wasm-drc) — an
// empty import object is all instantiate needs; no streaming-compile required.
fetch("/static/drc.wasm")
  .then(function (r) { if (!r.ok) throw new Error("fetch " + r.status); return r.arrayBuffer(); })
  .then(function (buf) { return WebAssembly.instantiate(buf, {}); })
  .then(function (res) {
    wasm = res.instance;
    mem = wasm.exports.memory;
    ready = true;
    postMessage({ type: "ready" });
  })
  .catch(function (e) {
    initErr = String((e && e.message) || e);
    postMessage({ type: "error", error: initErr });
  });

function runCheck(input) {
  var ex = wasm.exports;
  var bytes = new TextEncoder().encode(input);
  var p = ex.wasm_alloc(bytes.length);
  // Take a fresh Uint8Array view each time — the wasm allocator can grow the
  // memory (detaching any earlier ArrayBuffer view) inside wasm_alloc.
  new Uint8Array(mem.buffer).set(bytes, p);
  var outLen = ex.drc_check(p, bytes.length);
  var outPtr = ex.drc_output_ptr();
  var json = new TextDecoder().decode(new Uint8Array(mem.buffer, outPtr, outLen));
  return JSON.parse(json);
}

onmessage = function (ev) {
  var d = ev.data || {};
  if (d.type !== "check") return;
  if (!ready) { postMessage({ type: "result", seq: d.seq, error: initErr || "wasm not ready" }); return; }
  try {
    postMessage({ type: "result", seq: d.seq, resp: runCheck(d.input) });
  } catch (e) {
    postMessage({ type: "result", seq: d.seq, error: String((e && e.message) || e) });
  }
};
