// Minimal Pixi-mount prototype used by Phase (a) of the SPA port.
//
// The real PCB viewer lives at src/serve/assets/pcb_viewer.js and gets wired
// up via window.EDA_PcbViewer in Phase (e).
// For now this file just proves the keyed-div mount pattern works.

export async function mount_prototype(container_id, label) {
  const el = document.getElementById(container_id);
  if (!el) return null;

  if (!window.PIXI) {
    el.textContent =
      "Pixi.js not loaded (expected <script src=\"https://cdn.jsdelivr.net/npm/pixi.js@8.6.6/dist/pixi.min.js\"> in the shell)";
    return null;
  }

  const app = new window.PIXI.Application();
  await app.init({
    background: "#0d1117",
    resizeTo: el,
    antialias: true,
    resolution: Math.max(window.devicePixelRatio || 1, 2),
    autoDensity: true,
  });
  el.appendChild(app.canvas);

  const g = new window.PIXI.Graphics();
  g.circle(180, 120, 40).fill({ color: 0x4a9eff }).stroke({ width: 2, color: 0x58a6ff });
  app.stage.addChild(g);

  const style = new window.PIXI.TextStyle({
    fill: 0xc9d1d9,
    fontFamily: "system-ui, sans-serif",
    fontSize: 14,
  });
  const t = new window.PIXI.Text({ text: label, style });
  t.x = 16;
  t.y = 16;
  app.stage.addChild(t);

  return app;
}

export function destroy(app) {
  if (app && typeof app.destroy === "function") {
    app.destroy(true, { children: true, texture: true });
  }
}
