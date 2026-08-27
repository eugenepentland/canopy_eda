/* Off-main-thread STEP parser for the PCB 3D preview.
 *
 * OpenCascade's ReadStepFile call is synchronous and vendor models can take
 * several seconds to tessellate. Keeping the kernel in this dedicated worker
 * lets the board, camera, and visibility controls remain usable while bodies
 * stream into the scene. Requests share one kernel instance and the worker's
 * event queue serializes parses, avoiding a burst of large WASM heaps.
 */
"use strict";

var occtReady = null;

function ensureOcct() {
  if (occtReady) return occtReady;
  importScripts("/static/occt-import-js.js");
  occtReady = occtimportjs({ locateFile: function (name) { return "/static/" + name; } });
  return occtReady;
}

self.onmessage = function (event) {
  var message = event.data || {}, id = message.id;
  ensureOcct().then(function (occt) {
    return occt.ReadStepFile(new Uint8Array(message.buffer), null);
  }).then(function (result) {
    self.postMessage({ id: id, result: result });
  }).catch(function (error) {
    self.postMessage({ id: id, error: String(error && error.message || error) });
  });
};
