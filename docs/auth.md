# Auth

**What this is:** netlisp's complete security model — who is allowed to call
what, and what changes when the server is not on your own machine. Read it
before exposing `netlisp serve` beyond loopback, before minting a token for a
KiCad client, or when a request comes back `403`.

netlisp is a **local tool**. It has no user database, no session store, no
passwords or passkeys. By default it needs no external auth service. Local mode uses three
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
system surfaces gate on `role.canWrite()`. In local mode an admitted request is
`admin`; the plugin-token sync path leaves the request at the default `reader`
because that token authorizes a route rather than an identity.

## Optional Ward hosting

Set `NETLISP_AUTH=ward` to authenticate hosted requests using an existing
Ward server. The default is `NETLISP_AUTH=local`; merely setting `WARD_*`
URLs does not change local mode. An unknown auth mode aborts startup.
The client is bundled under `vendor/ward`, so building netlisp needs neither
a sibling Ward checkout nor a running Ward service.

```dotenv
NETLISP_AUTH=ward
WARD_VERIFY_URL=http://127.0.0.1:9000/verify
WARD_LOGIN_URL=https://ward.example.com/login
WARD_INTROSPECT_URL=http://127.0.0.1:9000/oauth/introspect
WARD_SERVICE_NAME=netlisp
WARD_SERVICE_URL=https://netlisp.example.com
# Optional: otherwise derived from WARD_LOGIN_URL by removing /login.
# WARD_AUTH_SERVER_URL=https://ward.example.com
# Optional successful-verdict cache lifetime (default 30 seconds).
# WARD_CACHE_TTL_SECS=30
```

Ward mode verifies the `ward_session` cookie, redirects unauthenticated page
requests to Ward login with a return URL, and answers unauthenticated API
requests with JSON `401`. Ward must issue its cookie for a parent domain
shared by the login and app hosts. Keep its verify/introspection endpoints
on a trusted network, preferably loopback. Keep netlisp on loopback behind
your HTTPS reverse proxy or tunnel; it must preserve the original Host and
set `X-Forwarded-Proto: https` for correct login return URLs.

Ward `admin` maps to netlisp admin, `member` to writer, and unknown roles to
reader. Mutations require writer access, apart from the existing compute-only
POST routes. KiCad sync accepts its route-scoped plugin token or a valid Ward
bearer with this service's scope and a writer-capable role. The
`/.well-known/oauth-protected-resource` route publishes Ward discovery metadata.
Ward grants for other services cannot authorize sync.

The Ward gate also applies to direct loopback requests. Combining Ward mode
with `--allow-remote` or `NETLISP_ALLOW_REMOTE` aborts startup. Missing Ward
configuration or an unavailable verifier fails closed with `503`; health
probes and static assets remain public. Successful verification is cached for
30 seconds by default, bounding the delay before logout/revocation is seen.

### Keeping one hosted installation public

Use a machine-local systemd drop-in, which deployment's generated base unit
will preserve. See `systemd/netlisp-ward.conf.example`. Copy it to
`~/.config/systemd/user/netlisp.service.d/ward.conf`, customize the URLs, then
run `systemctl --user daemon-reload` and `systemctl --user restart netlisp`.
Do not add `--allow-remote`: Ward performs authentication inside netlisp.
Other installations continue to use the shipped local-only base unit.

### Verification

`zig build test` includes the bundled Ward client tests and
`scripts/test_ward_hosting.py`, which starts disposable loopback services and
checks local defaults, Ward sessions, roles, discovery, startup policy errors,
and backend outages. It never reads production sessions or edits live designs.
