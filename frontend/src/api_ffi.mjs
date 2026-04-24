// Thin wrapper around browser fetch. The Gleam side wraps these in
// Promise(Result(String, ApiError)). These helpers throw on non-2xx so the
// Gleam side can use .then/.catch cleanly without needing to hand-roll a
// Result shim.

export function get_text(url) {
  return fetch(url, {
    method: "GET",
    credentials: "same-origin",
    headers: { Accept: "application/json" },
  }).then(handle);
}

export function post_text(url, body, contentType) {
  return fetch(url, {
    method: "POST",
    credentials: "same-origin",
    headers: {
      Accept: "application/json",
      "Content-Type": contentType || "application/json",
    },
    body: body,
  }).then(handle);
}

async function handle(r) {
  const body = await r.text();
  if (r.ok) return body;
  const err = new Error(r.status + ": " + (body || r.statusText));
  err.http_status = r.status;
  throw err;
}
