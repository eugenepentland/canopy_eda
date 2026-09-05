# Auth

netlisp is a **local tool**. It has no user database, no session store, no
passwords or passkeys, and no external auth service. The entire model is three
rules in `src/serve/auth.zig`, and `authMiddleware` there is the single seam
every request passes through before dispatch.

## The model

1. **A loopback, unproxied request is an admin.** Locality is derived from the
   *TCP peer address* (`127.0.0.0/8` or `::1`), never from a request header — a
   header is fully attacker-controlled, and deriving "am I local?" from `Host`
   once bought unauthenticated admin here. A request carrying any of
   `Forwarded`, `X-Forwarded-For`, `X-Forwarded-Host`, `X-Forwarded-Proto`,
   `X-Forwarded-Port` or `X-Real-IP` was relayed by a reverse proxy and is
   **not** local, however loopback its peer looks: a same-host proxy delivers
   internet traffic over loopback.
2. **A plugin bearer token admits the KiCad sync route.** `netlisp_p_*` tokens
   are minted by `netlisp mint-plugin-token`, hashed into `plugin_tokens.json`
   under the auth dir, and checked on `POST /api/sync-kicad-pcb/:name` only.
   That route rewrites the board file in place, so treat the token as
   board-write capability that never expires; revoke by removing its hash from
   `plugin_tokens.json`.
3. **Everything else is refused `403`** — JSON on an `/api/` path, plain text
   elsewhere — with a body naming `--allow-remote`.

`GET /healthz` and `/static/*` are the only unauthenticated routes. `/healthz`
answers a fixed `{"status":"ok"}` and touches no design, so a deployment health
check measures the process rather than the slowest page.

## Serving to more than localhost

Two independent flags, meant to move together:

| Flag | Env | Default | Effect |
| --- | --- | --- | --- |
| `--bind <addr>` | — | `127.0.0.1` | Interface the listening socket binds to. `--bind 0.0.0.0` makes the server reachable off-host. |
| `--allow-remote` | `NETLISP_ALLOW_REMOTE=1` | off | **Every** request becomes an admin. |

```bash
netlisp serve --project-dir projects/designs                    # local only (the default)
netlisp serve --project-dir projects/designs \
    --bind 127.0.0.1 --allow-remote                             # behind a same-host reverse proxy
```

`--allow-remote` turns netlisp's own gate **off**. It authenticates nobody and
authorizes everything: reads, design edits, board rewrites, release attestation.
Use it only when an authenticating reverse proxy (nginx `auth_request`,
Caddy `forward_auth`, oauth2-proxy, Cloudflare Access, a VPN, an SSH tunnel, …)
sits in front of netlisp and is doing the authentication for you. **Put your own
auth in front — netlisp has none to lend you.**

Widening `--bind` *without* `--allow-remote` is the safe-but-useless
combination: the socket accepts the connection and the middleware refuses every
request on it with a 403 that says so. Setting `--allow-remote` while bound to
loopback is the normal reverse-proxy shape.

Whichever you choose, a request that netlisp admits under `--allow-remote` is
recorded as the identity `remote` (a loopback request records `local`); those
names reach the per-mutation git auto-commit author line
(`<name> <name@netlisp>`) and any review sign-off record.

## Roles

The `Role` enum (`admin` / `writer` / `reader`) survives because the review and
system surfaces gate on `role.canWrite()`. In practice an admitted request is
`admin`; the plugin-token sync path leaves the request at the default `reader`
because that token authorizes a route rather than an identity.

## What used to be here

Up to 2026-09 netlisp delegated auth to an external `ward` server: browser
sessions verified against a `wardd` `GET /verify`, OAuth bearers introspected,
an RFC 9728 `/.well-known/oauth-protected-resource` document, `WARD_*`
configuration, and a `NETLISP_DEV=1` loopback bypass. All of it is gone, along
with the `ward` build dependency — a fresh clone builds with no sibling auth
checkout. `NETLISP_DEV` is replaced by the default (loopback *is* admin), and
the deployment case it never covered is `--allow-remote`.
