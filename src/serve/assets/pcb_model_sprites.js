/* Persistent assembly model sprites.
 *
 * Each unique footprint first asks the server for its cached transparent PNG.
 * Only a missing or stale picture lazy-loads Three.js + OpenCASCADE, parses the
 * STEP model, renders it once, and POSTs the PNG and calibrated bounds into
 * lib/models/.sprites. Later assembly loads decode those small files directly;
 * if every footprint is cached, no WebGL or STEP runtime is loaded at all.
 */
(function () {
  "use strict";

  var DATA = (typeof PCB !== "undefined") ? PCB : {};
  var models = DATA.models || {};
  if (!Object.keys(models).length || !window.PCBSetAssemblySprite) return;

  function loadScript(src) {
    return new Promise(function (resolve, reject) {
      var script = document.createElement("script");
      script.src = src;
      script.onload = resolve;
      script.onerror = function () { reject(new Error("load " + src)); };
      document.head.appendChild(script);
    });
  }

  function loadStack() {
    var chain = Promise.resolve();
    if (!window.THREE) chain = chain.then(function () { return loadScript("/static/three.min.js"); });
    if (!window.occtimportjs) chain = chain.then(function () { return loadScript("/static/occt-import-js.js"); });
    return chain.then(function () {
      return window.occtimportjs({ locateFile: function (name) { return "/static/" + name; } });
    });
  }

  function kicadView(rotation, offset) {
    return {
      rot: [-rotation[0], rotation[1], rotation[2]],
      off: [-offset[0], -offset[1], -offset[2]]
    };
  }

  function meshGroup(THREE, parsed, transform) {
    var group = new THREE.Group();
    (parsed.meshes || []).forEach(function (mesh) {
      var positions = mesh.attributes && mesh.attributes.position && mesh.attributes.position.array;
      if (!positions) return;
      var geometry = new THREE.BufferGeometry();
      geometry.setAttribute("position", new THREE.Float32BufferAttribute(positions, 3));
      if (mesh.attributes.normal && mesh.attributes.normal.array) {
        geometry.setAttribute("normal", new THREE.Float32BufferAttribute(mesh.attributes.normal.array, 3));
      } else {
        geometry.computeVertexNormals();
      }
      if (mesh.index && mesh.index.array) geometry.setIndex(mesh.index.array);
      var color = mesh.color && mesh.color.length >= 3
        ? new THREE.Color(mesh.color[0], mesh.color[1], mesh.color[2])
        : new THREE.Color(0x9aa4ad);
      group.add(new THREE.Mesh(geometry, new THREE.MeshStandardMaterial({
        color: color, metalness: 0.34, roughness: 0.58
      })));
    });
    var view = kicadView(transform.r || [0, 0, 0], transform.o || [0, 0, 0]);
    var rad = Math.PI / 180;
    group.rotation.set(-view.rot[0] * rad, -view.rot[1] * rad, -view.rot[2] * rad, "ZYX");
    group.position.set(view.off[0], view.off[1], view.off[2]);
    group.updateMatrixWorld(true);
    return group;
  }

  function blobImage(blob) {
    if (window.createImageBitmap) return window.createImageBitmap(blob);
    return new Promise(function (resolve, reject) {
      var image = new Image();
      var url = URL.createObjectURL(blob);
      image.onload = function () { URL.revokeObjectURL(url); resolve(image); };
      image.onerror = function () { URL.revokeObjectURL(url); reject(new Error("sprite image failed")); };
      image.src = url;
    });
  }

  function canvasBitmap(canvas) {
    return new Promise(function (resolve, reject) {
      canvas.toBlob(function (blob) {
        if (!blob) { reject(new Error("sprite encoding failed")); return; }
        blobImage(blob).then(function (image) {
          resolve({ image: image, blob: blob });
        }, reject);
      }, "image/png");
    });
  }

  function renderSprite(THREE, renderer, scene, root) {
    var box = new THREE.Box3().setFromObject(root);
    if (box.isEmpty()) return Promise.reject(new Error("empty model"));
    var width = Math.max(box.max.x - box.min.x, 0.05);
    var height = Math.max(box.max.y - box.min.y, 0.05);
    var padding = Math.max(Math.min(Math.max(width, height) * 0.035, 0.35), 0.04);
    var x = box.min.x - padding;
    // Scene +Y is footprint -Y. The bitmap's top edge therefore maps to the
    // footprint's smallest canvas-Y coordinate.
    var y = -box.max.y - padding;
    width += padding * 2;
    height += padding * 2;

    var pixelsPerMm = Math.min(32, 1024 / width, 1024 / height);
    var pixelWidth = Math.max(8, Math.round(width * pixelsPerMm));
    var pixelHeight = Math.max(8, Math.round(height * pixelsPerMm));
    renderer.setSize(pixelWidth, pixelHeight, false);
    renderer.setClearColor(0x000000, 0);

    var cx = (box.min.x + box.max.x) / 2;
    var cy = (box.min.y + box.max.y) / 2;
    var cz = (box.min.z + box.max.z) / 2;
    var camera = new THREE.OrthographicCamera(
      -width / 2, width / 2, height / 2, -height / 2, 0.01,
      Math.max(box.max.z - box.min.z, width, height) * 6 + 20
    );
    camera.position.set(cx, cy, box.max.z + Math.max(width, height) * 2 + 2);
    camera.up.set(0, 1, 0);
    camera.lookAt(cx, cy, cz);
    camera.updateProjectionMatrix();
    renderer.render(scene, camera);
    function release() {
      root.traverse(function (node) {
        if (node.geometry) node.geometry.dispose();
        if (node.material) node.material.dispose();
      });
    }
    return canvasBitmap(renderer.domElement).then(function (encoded) {
      release();
      return { image: encoded.image, blob: encoded.blob, x: x, y: y, w: width, h: height };
    }, function (error) {
      release();
      throw error;
    });
  }

  function parseModel(occt, footprint) {
    return fetch("/api/model-file/" + encodeURIComponent(footprint))
      .then(function (response) {
        if (!response.ok) throw new Error("model " + response.status);
        return response.arrayBuffer();
      })
      .then(function (buffer) {
        var parsed = occt.ReadStepFile(new Uint8Array(buffer), null);
        if (!parsed || !parsed.success || !parsed.meshes || !parsed.meshes.length) {
          throw new Error("STEP parse produced no geometry");
        }
        return parsed;
      });
  }

  function vectorHeader(response, name, fallback) {
    var raw = response.headers.get(name);
    if (!raw) return fallback;
    var values = raw.split(",").map(Number);
    if (values.length !== 3 || values.some(function (value) { return !Number.isFinite(value); })) return fallback;
    return values;
  }

  function boundsFromHeaders(response) {
    var bounds = {
      x: Number(response.headers.get("X-Netlisp-Sprite-X")),
      y: Number(response.headers.get("X-Netlisp-Sprite-Y")),
      w: Number(response.headers.get("X-Netlisp-Sprite-W")),
      h: Number(response.headers.get("X-Netlisp-Sprite-H"))
    };
    if (![bounds.x, bounds.y, bounds.w, bounds.h].every(Number.isFinite) || bounds.w <= 0 || bounds.h <= 0) {
      throw new Error("invalid cached sprite bounds");
    }
    return bounds;
  }

  function cachedSprite(footprint, fallbackTransform) {
    var url = "/api/model-sprite/" + encodeURIComponent(footprint);
    return fetch(url, { cache: "no-store" }).then(function (response) {
      var source = {
        key: response.headers.get("X-Netlisp-Sprite-Key"),
        transform: {
          o: vectorHeader(response, "X-Netlisp-Model-Offset", fallbackTransform.o || [0, 0, 0]),
          r: vectorHeader(response, "X-Netlisp-Model-Rotation", fallbackTransform.r || [0, 0, 0])
        }
      };
      if (response.status === 404) {
        if (!source.key) throw new Error("model sprite source unavailable");
        return { source: source, sprite: null };
      }
      if (!response.ok) throw new Error("sprite " + response.status);
      var bounds;
      try { bounds = boundsFromHeaders(response); }
      catch (_) { return { source: source, sprite: null }; }
      return response.blob().then(blobImage).then(function (image) {
        bounds.image = image;
        return { source: source, sprite: bounds };
      }, function () {
        // A truncated cache entry self-heals through the ordinary STEP miss
        // path and is atomically replaced after the fresh render.
        return { source: source, sprite: null };
      });
    });
  }

  function persistSprite(footprint, source, sprite) {
    var params = new URLSearchParams({
      key: source.key,
      x: String(sprite.x), y: String(sprite.y),
      w: String(sprite.w), h: String(sprite.h)
    });
    return fetch("/api/model-sprite/" + encodeURIComponent(footprint) + "?" + params.toString(), {
      method: "POST", headers: { "Content-Type": "image/png" }, body: sprite.blob
    }).then(function (response) {
      if (!response.ok) throw new Error("store sprite " + response.status);
    });
  }

  function idleNext(fn) {
    if (window.requestIdleCallback) window.requestIdleCallback(fn, { timeout: 120 });
    else setTimeout(fn, 0);
  }

  function start() {
    var renderStack = null;
    function renderer() {
      if (renderStack) return renderStack;
      renderStack = loadStack().then(function (occt) {
        var THREE = window.THREE;
        var canvas = document.createElement("canvas");
        var webgl = new THREE.WebGLRenderer({
          canvas: canvas, alpha: true, antialias: true, preserveDrawingBuffer: true
        });
        webgl.setPixelRatio(1);
        if (THREE.sRGBEncoding) webgl.outputEncoding = THREE.sRGBEncoding;
        return { THREE: THREE, occt: occt, renderer: webgl };
      });
      return renderStack;
    }

    // Most-used footprints populate the board first, maximizing useful visual
    // progress whether each item comes from disk or needs a one-time STEP pass.
    var counts = {};
    (DATA.parts || []).forEach(function (part) { counts[part.fp] = (counts[part.fp] || 0) + 1; });
    var queue = Object.keys(models).sort(function (a, b) { return (counts[b] || 0) - (counts[a] || 0); });
    var total = queue.length;
    var done = 0;

    function next() {
      if (!queue.length) {
        if (renderStack) renderStack.then(function (stack) { stack.renderer.dispose(); }, function () {});
        try { window.parent.postMessage({ type: "netlisp-pcb-sprite-progress", done: done, total: total }, window.location.origin); } catch (_) {}
        return;
      }
      var footprint = queue.shift();
      cachedSprite(footprint, models[footprint]).then(function (loaded) {
        if (loaded.sprite) {
          window.PCBSetAssemblySprite(footprint, loaded.sprite);
          return null;
        }
        return renderer().then(function (stack) {
          return parseModel(stack.occt, footprint).then(function (parsed) {
            var scene = new stack.THREE.Scene();
            scene.add(new stack.THREE.HemisphereLight(0xffffff, 0x48535d, 1.15));
            var key = new stack.THREE.DirectionalLight(0xffffff, 0.9); key.position.set(-3, -4, 9); scene.add(key);
            var fill = new stack.THREE.DirectionalLight(0xffffff, 0.45); fill.position.set(5, 2, 5); scene.add(fill);
            var root = meshGroup(stack.THREE, parsed, loaded.source.transform);
            scene.add(root);
            return renderSprite(stack.THREE, stack.renderer, scene, root);
          });
        }).then(function (sprite) {
          window.PCBSetAssemblySprite(footprint, sprite);
          return persistSprite(footprint, loaded.source, sprite);
        });
      }).catch(function (error) {
        console.warn("Assembly sprite failed for " + footprint, error);
      }).then(function () {
        done++;
        try {
          window.parent.postMessage({
            type: "netlisp-pcb-sprite-progress", done: done,
            total: total, footprint: footprint
          }, window.location.origin);
        } catch (_) {}
        idleNext(next);
      });
    }
    idleNext(next);
  }

  // Let HTML parsing, board initialization, and at least one bare-board paint
  // complete before reading the lightweight filesystem cache.
  requestAnimationFrame(function () { requestAnimationFrame(start); });
})();
