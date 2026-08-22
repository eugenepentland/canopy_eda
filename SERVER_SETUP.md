# Fresh Linux development and production server

This is the migration runbook for moving the Netlisp EDA development environment
and production service from the current `aibox` host to a fresh Linux server on
the LAN. It is written so that a human performs only the operating-system,
account-login, and Cloudflare-dashboard work; after SSH and Codex are available,
an agent can perform the remaining user-level work.

The safest migration is not a blind copy of the old home directory. Clone what
is reproducible, copy the small set of local-only source and state explicitly,
verify every pinned binary, bring the new services up locally, and only then
move public traffic.

## Non-negotiable choices

- Use the Linux user **`epentland`**, with home **`/home/epentland`**, on the new
  host. The approved production Zig path is deliberately pinned as an absolute
  path in `.githooks/prepare-release.sh`; changing the username or layout is a
  source change requiring a new release gate.
- Use an x86-64 Linux host. Both approved Zig packages below are x86-64.
- Keep the old host intact until the new local and public acceptance checks pass.
- Never commit `.env`, Cloudflare tunnel tokens/credential JSON, Codex auth
  files, GitHub tokens, SSH private keys, or the Ward database.
- Do not copy build caches or old EDA worktrees. They are reproducible and are
  the main reason the old 1.8 TB filesystem is full.
- Do not disable the old host's shared `cloudflared.service` during the EDA
  cutover. Its `Ep-home-server` tunnel also serves unrelated LAN applications.

## What is and is not recoverable from GitHub

Audited on 2026-08-22:

| Asset | Current source | Migration method |
| --- | --- | --- |
| Netlisp/EDA | `github.com/eugenepentland/netlisp` | Fresh GitHub clone |
| Guardian | `github.com/eugenepentland/guardian-zig` | Fresh GitHub clone, then build it |
| Live designs | 2.9 GB Git repo with **no remote** | Final checkpoint, then `rsync` including `.git` |
| Ward | Git repo with **no remote** and uncommitted changes | `rsync` including `.git`, excluding build caches |
| Ward identity/session state | SQLite DB under `~/.local/share/wardd` | SQLite online backup during cutover |
| Official Zig | Published archive with a pinned SHA-256 | Download and verify |
| Approved production Zig | Local 269 MB binary + complete `lib/` package | `rsync` exact directory and verify compiler SHA-256 |
| Custom Zig source | Local repos whose remotes point at an old local path | `rsync` source repos including `.git`, excluding build outputs |
| Netlisp API credentials | Untracked `eda/.env` | Secure copy, mode `0600` |
| Codex | Official installer + fresh login | Install and use device-code login |
| Cloudflare | New dedicated remotely-managed tunnel | Create in dashboard; install its service token on new host |

At the time of the audit, the Ward checkout has tracked uncommitted changes and
the custom Zig checkout has untracked compiler artifacts. Do not assume a clean
GitHub clone can replace either checkout.

## Capacity and host assumptions

The current host has 12 CPUs and 64 GiB RAM. A clean custom Zig compiler build
has a documented peak near 9.3 GiB RSS, while EDA release preparation runs the
Debug test suite and production build concurrently. Practical targets:

- x86-64 Ubuntu 22.04 or newer;
- 16 GiB RAM minimum, 32 GiB or more preferred;
- 100 GB free disk minimum, 500 GB preferred for many concurrent worktrees;
- reliable LAN address or DHCP reservation;
- outbound HTTPS/DNS/NTP; no inbound WAN port is needed for Cloudflare Tunnel.

The old host is full because it contains roughly 443 GB of EDA worktrees, 40 GB
of EDA Git/release caches, 243 GB of user caches, and 354 GB under `/tmp`. Copy
source and state only. Never migrate `.claude/worktrees`, `.zig-cache`,
`zig-out`, `.git/release-cache`, `.git/release-failures`,
`.git/release-candidates`, `.git/deploy-zig-cache`, or old `/tmp` contents.

## Roles in this runbook

- **ADMIN** means a human with `sudo` on the new server.
- **HUMAN** means an interactive account/Cloudflare action that must not be
  delegated with a secret pasted into chat.
- **AGENT** means Codex can perform it as `epentland` without admin access.
- **OLD** and **NEW** identify the host on which a command runs.

Choose the new hostname and record both LAN addresses before starting. The
examples use `aibox` for the old SSH host and `eda-prod` for the new one.

## Phase 1: ADMIN bootstrap on the new server

Create the `epentland` account with `/home/epentland`, install SSH first, and
confirm key-based login before changing a firewall. Then install the base tools:

```bash
sudo apt-get update
sudo apt-get install -y \
  binutils ca-certificates curl ghostscript git gh jq libsqlite3-dev \
  openssh-client python3 rsync sqlite3 util-linux xz-utils
```

`util-linux` supplies `flock` and `setsid`; `binutils` supplies `strip` and
`readelf`; Ward needs the SQLite headers/library and `sqlite3` is also used for
safe database backups. Netlisp uses Ghostscript's `ps2ascii` at runtime for
datasheet text extraction.

Optional development tools are deliberately separate from the production
minimum:

- Node.js 22 runs the checked-in JavaScript parity/performance harnesses under
  `scripts/`; Codex's standalone installer does not require Node.
- `kicad-cli` runs `scripts/verify_kicad_sch.sh` and other KiCad round-trip
  acceptance work. Install the KiCad version used for design review (KiCad 10
  on the old host), not an arbitrary older distro package.
- `python3-cairosvg` plus `libcairo2` supports `scripts/diagram_png.py`.
- `valgrind` and the kernel-matching `linux-tools`/`perf` packages are useful
  for profiling, but are not needed to build, test, or serve EDA.

Enable user services to run after logout and at boot:

```bash
sudo loginctl enable-linger epentland
loginctl show-user epentland -p Linger
```

Install `cloudflared` from Cloudflare's APT repository, but do not install a
tunnel service yet:

```bash
sudo install -d -m 0755 /usr/share/keyrings
curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg \
  | sudo tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null
echo 'deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main' \
  | sudo tee /etc/apt/sources.list.d/cloudflared.list >/dev/null
sudo apt-get update
sudo apt-get install -y cloudflared
cloudflared --version
```

Firewall/router requirements:

- allow SSH from the trusted LAN before enabling a firewall;
- do not forward 7050 or 9000 from the router to the new host;
- Ward binds to `127.0.0.1:9000`;
- Netlisp currently binds 7050 on all interfaces, so restrict 7050 to LAN or
  loopback with the host firewall if untrusted devices share the network;
- Cloudflare Tunnel uses outbound connections and needs no inbound WAN rule.

Reboot once if the OS was substantially updated, then verify SSH login as
`epentland` and `systemctl --user status` without `sudo`.

## Phase 2: HUMAN account setup over SSH

### GitHub SSH and CLI

Create a new per-host SSH key rather than copying a private key from `aibox`:

```bash
ssh-keygen -t ed25519 -C 'epentland@eda-prod'
eval "$(ssh-agent -s)"
ssh-add /home/epentland/.ssh/id_ed25519
```

Authenticate GitHub CLI interactively, upload the public key, and test SSH:

```bash
gh auth login --git-protocol ssh --web
gh ssh-key add /home/epentland/.ssh/id_ed25519.pub \
  --type authentication --title 'eda-prod'
ssh -T git@github.com
gh auth status
```

If `gh ssh-key add` requests an extra scope, approve it interactively or add the
public key in GitHub's SSH-key settings. Configure commit identity:

```bash
git config --global user.name 'Eugene Pentland'
git config --global user.email 'epentland@2yfv.com'
git config --global init.defaultBranch main
```

### Codex on a headless server

Install Codex as the normal user using the current official standalone
installer:

```bash
curl -fsSL https://chatgpt.com/codex/install.sh | sh
codex --version
```

For an SSH/headless login, use device-code authentication:

```bash
codex login --device-auth
```

Open the displayed URL on a trusted browser and enter the one-time code. If
device authentication is unavailable, use an SSH callback forward from the
local workstation (`ssh -L 1455:localhost:1455 epentland@eda-prod`) and run
`codex login` in that session.

Do **not** copy all of `/home/epentland/.codex`. In particular, `auth.json`,
`.credentials.json`, SQLite state, sessions, attachments, logs, and shell
snapshots are credentials or machine-specific history. The only useful file to
copy from the old host is the non-secret global instruction file:

```bash
mkdir -p /home/epentland/.codex
scp epentland@aibox:/home/epentland/.codex/AGENTS.md \
  /home/epentland/.codex/AGENTS.md
chmod 600 /home/epentland/.codex/AGENTS.md
```

Start with Codex's normal safe defaults. If a user config is needed, put it at
`/home/epentland/.codex/config.toml`; use `approval_policy = "on-request"` and
`sandbox_mode = "workspace-write"`. Do not copy the old host's broad trust and
`danger-full-access` settings as part of a server migration.

## Phase 3: AGENT source layout

Create the exact directory layout and clone the two GitHub-backed repositories:

```bash
mkdir -p /home/epentland/ai/canopy /home/epentland/ai
cd /home/epentland/ai/canopy
git clone git@github.com:eugenepentland/guardian-zig.git guardian-zig
git clone git@github.com:eugenepentland/netlisp.git eda
```

Confirm both are on `main`, clean, and have the expected remotes:

```bash
git -C /home/epentland/ai/canopy/guardian-zig status --short --branch
git -C /home/epentland/ai/canopy/eda status --short --branch
git -C /home/epentland/ai/canopy/guardian-zig remote -v
git -C /home/epentland/ai/canopy/eda remote -v
```

### Copy the local-only Ward checkout

Ward currently has no remote and has uncommitted tracked work. Copy the
worktree and `.git`, but leave reproducible output behind:

```bash
rsync -a --info=progress2 \
  --exclude='.zig-cache/' --exclude='zig-out/' \
  epentland@aibox:/home/epentland/ai/ward/ \
  /home/epentland/ai/ward/

git -C /home/epentland/ai/ward status --short --branch
```

The expected committed base at the 2026-08-22 audit was
`6d6c7c5d73cbc3b2322efed69862b45bbaca35a9`. Preserve any newer commits and
working-tree changes found during the actual migration.

### Copy the live designs repository

`projects/designs` is a separate, clean Git repository with no remote. Copy it
including `.git`; exclude only the deployed-binary cache, which the Netlisp
deploy recreates:

```bash
mkdir -p /home/epentland/ai/canopy/eda/projects/designs
rsync -a --info=progress2 --exclude='.netlisp-bin/' \
  epentland@aibox:/home/epentland/ai/canopy/eda/projects/designs/ \
  /home/epentland/ai/canopy/eda/projects/designs/

git -C /home/epentland/ai/canopy/eda/projects/designs status --short --branch
git -C /home/epentland/ai/canopy/eda/projects/designs log -1 --oneline
```

This is the preliminary copy. Repeat it after freezing production during the
cutover so no live design commit is missed.

### Copy Netlisp's secret environment file

The current `.env` contains Component Search Engine/Nexar, DigiKey, and Ward
configuration. Transfer it directly over SSH; never display it or put it in a
prompt/log:

```bash
scp epentland@aibox:/home/epentland/ai/canopy/eda/.env \
  /home/epentland/ai/canopy/eda/.env
chmod 600 /home/epentland/ai/canopy/eda/.env
```

The production Ward entries should include these non-secret endpoints:

```dotenv
WARD_VERIFY_URL=http://127.0.0.1:9000/verify
WARD_LOGIN_URL=https://ward.eugenepentland.dev/login
WARD_INTROSPECT_URL=http://127.0.0.1:9000/oauth/introspect
WARD_SERVICE_NAME=eda
WARD_SERVICE_URL=https://co-circuit.eugenepentland.dev
WARD_CACHE_TTL_SECS=30
```

Confirm required variable **names**, not values:

```bash
sed -n -E 's/^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=.*/\2/p' \
  /home/epentland/ai/canopy/eda/.env | sort
```

## Phase 4: AGENT pinned Zig toolchains

Normal Debug development uses the official Zig snapshot. Production
ReleaseSafe uses the approved custom compiler package. Both report the same
version, so the binary SHA-256 is part of the identity.

### Official development compiler

```bash
mkdir -p /home/epentland/zig-toolchains /home/epentland/.local/bin
cd /tmp
curl -fLO \
  https://ziglang.org/builds/zig-x86_64-linux-0.17.0-dev.1683+5ceec001b.tar.xz
printf '%s  %s\n' \
  e6e5c7e0834626bded90cd786d148bebf211dc80b013afefd631472b57b41f77 \
  zig-x86_64-linux-0.17.0-dev.1683+5ceec001b.tar.xz \
  | sha256sum --check
tar -xJf zig-x86_64-linux-0.17.0-dev.1683+5ceec001b.tar.xz
mv zig-x86_64-linux-0.17.0-dev.1683+5ceec001b \
  /home/epentland/zig-toolchains/0.17.0-dev.1683+5ceec001b
ln -sfn /home/epentland/zig-toolchains/0.17.0-dev.1683+5ceec001b/zig \
  /home/epentland/.local/bin/zig
```

Ensure `/home/epentland/.local/bin` is on `PATH`, start a new login shell, then
verify:

```bash
command -v zig
zig version
sha256sum /home/epentland/zig-toolchains/0.17.0-dev.1683+5ceec001b/zig
```

Expected version: `0.17.0-dev.1683+5ceec001b`. The extracted compiler binary's
expected SHA-256 is
`1d314883fd8cf4490c1c29dd73ad8b64e319a8a53c4d9087d1135b52977df37f`.

### Approved production compiler package

Copy the exact binary **and its complete matching `lib/` tree**:

```bash
rsync -a --info=progress2 \
  epentland@aibox:/home/epentland/zig-toolchains/0.17.0-dev.1683+5ceec001b-eda-286f77f2-8f4af965/ \
  /home/epentland/zig-toolchains/0.17.0-dev.1683+5ceec001b-eda-286f77f2-8f4af965/
```

Verify the exact production identity:

```bash
test -d /home/epentland/zig-toolchains/0.17.0-dev.1683+5ceec001b-eda-286f77f2-8f4af965/lib
/home/epentland/zig-toolchains/0.17.0-dev.1683+5ceec001b-eda-286f77f2-8f4af965/zig version
sha256sum /home/epentland/zig-toolchains/0.17.0-dev.1683+5ceec001b-eda-286f77f2-8f4af965/zig
```

Expected SHA-256:
`8f4af9650b5358abcdd8a283976d30b5dcdca2b400e44af25953b2e34101e7d4`.
`scripts/zig-prod` and the release/deploy scripts independently reject any
other compiler.

### Preserve the custom compiler sources

Copy both local source repositories so compiler development can continue. The
approved package came from source commit
`286f77f28ed9609c50a1e0f543ce2fe74f9c1186` in
`zig-eda-candidate-auto-inline`.

```bash
rsync -a --info=progress2 \
  --exclude='.zig-cache/' --exclude='zig-out/' --exclude='stage3-*' \
  --exclude='*.o' \
  epentland@aibox:/home/epentland/ai/canopy/zig-eda-candidate-auto-inline/ \
  /home/epentland/ai/canopy/zig-eda-candidate-auto-inline/

rsync -a --info=progress2 \
  --exclude='.zig-cache/' --exclude='zig-out/' --exclude='stage3-*' \
  epentland@aibox:/home/epentland/ai/canopy/zig-eda-private/ \
  /home/epentland/ai/canopy/zig-eda-private/

git -C /home/epentland/ai/canopy/zig-eda-candidate-auto-inline \
  cat-file -e 286f77f28ed9609c50a1e0f543ce2fe74f9c1186^{commit}
```

These source checkouts do not have portable remotes. Publishing them to a
private GitHub repository later would remove this recovery risk; do not make
that an unreviewed part of the server cutover.

## Phase 5: AGENT build Guardian and verify development

Guardian is a relative-path dependency of both Ward and EDA. Build it first so
consumer worktrees can reuse the checked `guardian-check` binary:

```bash
cd /home/epentland/ai/canopy/guardian-zig
zig build --seed=1
test -x zig-out/bin/guardian-check
ln -sfn /home/epentland/ai/canopy/guardian-zig/zig-out/bin/guardian-check \
  /home/epentland/.local/bin/guardian-check
guardian-check version
```

Install the tracked EDA hooks, then run the normal Debug verification:

```bash
cd /home/epentland/ai/canopy/eda
mkdir -p .claude
ln -sfn /home/epentland/ai/canopy .claude/canopy
ln -sfn /home/epentland/ai/ward .claude/ward
.githooks/install.sh
.githooks/install.sh --check
zig build --seed=1 -Doptimize=debug
zig build --seed=1 test-compile
```

The two `.claude` links are ignored machine-local plumbing. Main-checkout
dependencies resolve directly, while a linked worktree under
`.claude/worktrees/<task>` reaches Guardian through `../../canopy/guardian-zig`
and Ward through `../../ward`.

Do not use PATH Zig with `-Doptimize=safe`. Normal development is Debug;
`.githooks/prepare-release.sh` alone owns the production ReleaseSafe build.

## Phase 6: AGENT prepare Ward on the new host

Build Ward's committed checkout. The current working changes remain preserved,
but its tracked deploy script builds the committed tip of `main` in a detached
worktree:

```bash
cd /home/epentland/ai/ward
zig build --seed=1
```

Copy the existing user-unit definitions from the old host; they contain the
correct production domain/path values but no tokens:

```bash
mkdir -p /home/epentland/.config/systemd/user
rsync -a \
  epentland@aibox:/home/epentland/.config/systemd/user/wardd.service \
  epentland@aibox:/home/epentland/.config/systemd/user/wardd-deploy.service \
  epentland@aibox:/home/epentland/.config/systemd/user/wardd-deploy.path \
  /home/epentland/.config/systemd/user/
chmod 600 /home/epentland/.config/systemd/user/wardd*.service \
  /home/epentland/.config/systemd/user/wardd*.path
systemctl --user daemon-reload
```

Before starting Ward, inspect `wardd.service` and confirm these values:

```text
WARD_DB_PATH=/home/epentland/.local/share/wardd/ward.db
WARD_LISTEN_ADDR=127.0.0.1:9000
WARD_RP_ID=eugenepentland.dev
WARD_ORIGINS=https://ward.eugenepentland.dev
WARD_COOKIE_DOMAIN=.eugenepentland.dev
```

Do not enable/start Ward until its consistent database copy arrives in the
cutover phase.

## Phase 7: HUMAN Cloudflare preparation

### Current-state warning

The old `cloudflared.service` runs the locally-managed shared tunnel
`Ep-home-server` (`5bea975f-9049-4191-ba83-f3ece5cf4faa`). Its config routes
many unrelated hostnames. `ward.eugenepentland.dev` is one of them, but
`co-circuit.eugenepentland.dev` is not.

As audited on 2026-08-22, `co-circuit.eugenepentland.dev` resolves directly to
the old residential public IP and responds without Cloudflare proxy headers.
The migration should therefore put both EDA hostnames behind a **new dedicated
remotely-managed tunnel**, not copy or take over the shared old tunnel.

### Create the dedicated tunnel

In the Cloudflare Zero Trust dashboard:

1. Create a remotely-managed tunnel named `eda-prod`.
2. Record the intended routes, but **do not add/activate their public hostnames
   yet**: `co-circuit.eugenepentland.dev` -> `http://localhost:7050` and
   `ward.eugenepentland.dev` -> `http://localhost:9000`. Saving a public
   hostname can modify DNS immediately.
3. Save the generated Linux service-install command/token in a password manager
   or use it immediately. The token is a secret; never put it in this repo,
   `.env`, a Codex prompt, or shell history shared with others.
4. Do not switch/delete the existing DNS records until both local services on
   the new host pass their health checks.

Cloudflare currently recommends remotely-managed tunnels for most deployments.
They keep ingress configuration in Cloudflare and require only the tunnel token
on the origin. A locally-managed tunnel is still possible, but then copy only
the dedicated tunnel's credential JSON (not account-wide `cert.pem`), set it to
mode `0600`, include a final catch-all ingress rule, and validate with
`cloudflared tunnel ingress validate`.

The final `sudo cloudflared service install <TUNNEL_TOKEN>` is an **ADMIN**
step and occurs after local acceptance below.

## Phase 8: production cutover

Perform this in a quiet window. Keep two SSH sessions open, one to each host.

### 8.1 OLD: freeze Netlisp writes and checkpoint designs

```bash
cd /home/epentland/ai/canopy/eda
systemctl --user stop netlisp.service
python3 scripts/checkpoint-designs.py \
  --project-dir projects/designs --quiet-seconds 0 --force --verbose
git -C projects/designs status --short --branch
```

Do not continue until the designs repo is clean or every remaining path is
understood and intentionally preserved.

### 8.2 NEW: make the final designs copy

```bash
rsync -a --info=progress2 --exclude='.netlisp-bin/' \
  epentland@aibox:/home/epentland/ai/canopy/eda/projects/designs/ \
  /home/epentland/ai/canopy/eda/projects/designs/

git -C /home/epentland/ai/canopy/eda/projects/designs fsck --full
git -C /home/epentland/ai/canopy/eda/projects/designs status --short --branch
```

### 8.3 OLD: stop Ward and create a consistent SQLite backup

```bash
systemctl --user stop wardd.service
mkdir -p /home/epentland/.local/share/wardd/migration
sqlite3 /home/epentland/.local/share/wardd/ward.db \
  ".backup '/home/epentland/.local/share/wardd/migration/ward.db'"
chmod 600 /home/epentland/.local/share/wardd/migration/ward.db
```

The SQLite backup API includes committed WAL data in one consistent file. Do
not copy only `ward.db` while the old service is running.

### 8.4 NEW: restore and start Ward

```bash
mkdir -p /home/epentland/.local/share/wardd/backups
scp epentland@aibox:/home/epentland/.local/share/wardd/migration/ward.db \
  /home/epentland/.local/share/wardd/ward.db
chmod 600 /home/epentland/.local/share/wardd/ward.db

cd /home/epentland/ai/ward
deploy/deploy.sh
systemctl --user enable --now wardd.service wardd-deploy.path
systemctl --user is-active wardd.service wardd-deploy.path
curl -fsS -o /dev/null http://127.0.0.1:9000/login
```

If Ward fails, inspect `journalctl --user -u wardd.service -n 200 --no-pager`
and restart the old Ward service while correcting the new host.

### 8.5 NEW: install and deploy Netlisp production

Run the install script only from the main checkout, not a linked worktree:

```bash
cd /home/epentland/ai/canopy/eda
.githooks/install.sh --deploy
.githooks/install.sh --check
.githooks/prepare-release.sh
DEPLOY_RUN_NOW=1 .githooks/deploy-prod.sh
```

The release step verifies Guardian, all Debug tests, the exact custom compiler
SHA, and the stripped ReleaseSafe binary before deployment. Deployment performs
local health checks and rolls back automatically if the new binary is
unhealthy.

Verify the new local services:

```bash
systemctl --user is-active netlisp.service wardd.service
curl -fsS http://127.0.0.1:7050/.well-known/oauth-protected-resource
curl -sS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:7050/
.githooks/install.sh --check
```

Expected: metadata returns 200 JSON naming
`https://ward.eugenepentland.dev`; `/` returns `302` to Ward login.

### 8.6 ADMIN/HUMAN: enable the new tunnel and switch DNS

On the new host, run the exact token command generated by the Cloudflare
dashboard:

```bash
sudo cloudflared service install <TUNNEL_TOKEN>
sudo systemctl enable --now cloudflared.service
sudo systemctl status cloudflared.service --no-pager
```

Then activate the two dedicated public-hostname routes in Cloudflare. Replace
the old direct `co-circuit` A/AAAA record with the tunnel route, and move the
existing `ward` hostname from the old shared tunnel to the new dedicated one.
Do not leave a direct origin record or router port-forward as a bypass around
Cloudflare.

Public acceptance:

```bash
curl -fsS https://co-circuit.eugenepentland.dev/.well-known/oauth-protected-resource
curl -sS -o /dev/null -w '%{http_code} %{redirect_url}\n' \
  https://co-circuit.eugenepentland.dev/
curl -fsS -o /dev/null https://ward.eugenepentland.dev/login
```

Also test from a phone on cellular:

- Ward passkey login;
- unauthenticated EDA URL -> Ward -> return to original EDA URL;
- an authenticated schematic page;
- Codex/CLI MCP connection to `https://co-circuit.eugenepentland.dev/mcp`;
- logout/revocation within `WARD_CACHE_TTL_SECS` (currently 30 seconds).

### 8.7 OLD: retire only the old EDA/Ward services

After public acceptance passes:

```bash
cd /home/epentland/ai/canopy/eda
.githooks/install.sh --uninstall-deploy
systemctl --user disable --now \
  netlisp.service \
  netlisp-designs-checkpoint.timer \
  netlisp-deploy-debounce.timer \
  netlisp-guardian-nightly.timer \
  wardd.service \
  wardd-deploy.path
```

Leave the old system `cloudflared.service` running because its shared tunnel
still serves unrelated hostnames. Remove only the obsolete `ward` ingress/DNS
association later, after checking every hostname in the old config.

## Phase 9: AGENT development and automation completion

Install the tracked nightly Guardian units on the new host:

```bash
ln -sfn /home/epentland/ai/canopy/eda/systemd/netlisp-guardian-nightly.service \
  /home/epentland/.config/systemd/user/netlisp-guardian-nightly.service
ln -sfn /home/epentland/ai/canopy/eda/systemd/netlisp-guardian-nightly.timer \
  /home/epentland/.config/systemd/user/netlisp-guardian-nightly.timer
systemctl --user daemon-reload
systemctl --user enable --now netlisp-guardian-nightly.timer
systemctl --user list-timers --all | grep -E 'netlisp|ward'
```

Confirm normal feature work creates isolated worktrees and that the post-
checkout hook supplies its dependency symlinks:

```bash
cd /home/epentland/ai/canopy/eda
git branch --show-current
git status --short
git worktree list
git worktree add .claude/worktrees/setup-smoke -b codex/setup-smoke main
test -e /home/epentland/ai/canopy/eda/.claude/canopy/guardian-zig
test -e /home/epentland/ai/canopy/eda/.claude/ward
test -d .claude/worktrees/setup-smoke/.zig-cache
git worktree remove .claude/worktrees/setup-smoke
git branch -d codex/setup-smoke
```

The last two commands intentionally remove only the known clean smoke-test
worktree/branch. Never script broad worktree deletion.

Run the complete final inventory:

```bash
command -v git gh zig guardian-check codex cloudflared python3 sqlite3
zig version
codex --version
cloudflared --version
gh auth status

git -C /home/epentland/ai/canopy/eda status --short --branch
git -C /home/epentland/ai/canopy/guardian-zig status --short --branch
git -C /home/epentland/ai/ward status --short --branch
git -C /home/epentland/ai/canopy/eda/projects/designs status --short --branch

/home/epentland/ai/canopy/eda/.githooks/install.sh --check
systemctl --user is-active \
  netlisp.service wardd.service \
  netlisp-designs-checkpoint.timer netlisp-deploy-debounce.timer \
  netlisp-guardian-nightly.timer wardd-deploy.path
systemctl is-active cloudflared.service
```

Ward and custom Zig may intentionally show the preserved work noted earlier;
EDA, Guardian, and designs should be clean unless newer deliberate work exists.

## Rollback

Until the migration is accepted, rollback is intentionally simple:

1. Disable the new dedicated tunnel service or route.
2. Restore the old `co-circuit` DNS record/router path if it was replaced.
3. Start old `wardd.service` and `netlisp.service`.
4. Re-enable the old EDA timers only if writes will resume there.
5. Do not allow both servers to accept design mutations at the same time.

Commands on OLD:

```bash
systemctl --user enable --now wardd.service netlisp.service
systemctl --user enable --now \
  netlisp-designs-checkpoint.timer netlisp-deploy-debounce.timer
```

If the new server accepted any design writes before rollback, stop it and sync
the designs repository back deliberately; inspect both Git histories first.
Never use `rsync --delete` or a forced Git reset as a rollback shortcut.

## Backups and ongoing maintenance

- Put `projects/designs` on a private remote or schedule encrypted backups. It
  currently has no remote and is the canonical live design history.
- Put Ward and the custom Zig branches on private remotes. Today their local
  repositories are single-host recovery dependencies.
- Back up Ward daily with `deploy/backup.sh`; test a restore periodically.
- Back up `.env` and the Cloudflare tunnel configuration/token in a secrets
  manager, not Git.
- Keep the official/custom Zig package directories immutable. Any compiler
  update must change the pinned path/SHA in a reviewed EDA branch and pass
  `.githooks/prepare-release.sh` plus production canary checks.
- Monitor disk use. Remove only known-idle derived caches; do not bulk-delete
  worktrees because they may contain another agent's uncommitted changes.
- Update Codex by rerunning the official installer. Reauthenticate rather than
  copying an entire `.codex` directory.
- Inspect service logs with:

```bash
journalctl --user -u netlisp.service -n 200 --no-pager
journalctl --user -u wardd.service -n 200 --no-pager
journalctl --user -u netlisp-guardian-nightly.service -n 200 --no-pager
sudo journalctl -u cloudflared.service -n 200 --no-pager
```

## Suggested first prompt for the new Codex agent

After ADMIN and HUMAN phases are complete, start Codex in
`/home/epentland/ai/canopy/eda` and give it this prompt:

> Follow `SERVER_SETUP.md` from Phase 3 through the pre-cutover local checks.
> Treat `aibox` as the old host and this machine as the new host. Do not run
> sudo, change Cloudflare/DNS, stop old production, delete caches/worktrees, or
> begin Phase 8. Complete Phases 3-7, report the verification and any drift from
> the audited inventory, then wait for explicit cutover approval. Never print
> or copy secret contents into chat.

## Primary external references

- [OpenAI Codex CLI install and quickstart](https://learn.chatgpt.com/docs/codex/cli)
- [OpenAI Codex authentication, including headless/device-code login](https://learn.chatgpt.com/docs/auth)
- [OpenAI Codex configuration precedence and safe local config](https://learn.chatgpt.com/docs/config-file/config-basic)
- [GitHub: add and test an SSH key](https://docs.github.com/en/authentication/connecting-to-github-with-ssh/adding-a-new-ssh-key-to-your-github-account)
- [Cloudflare: create a tunnel](https://developers.cloudflare.com/tunnel/setup/)
- [Cloudflare: install `cloudflared` as a Linux service](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/do-more-with-tunnels/local-management/as-a-service/linux/)
- [Cloudflare: locally-managed tunnel credential permissions](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/do-more-with-tunnels/local-management/tunnel-permissions/)
- Project-specific compiler identity and rationale: `ZIG_TOOLCHAIN.md`
- Project-specific deploy behavior and rollback: `.githooks/README.md`
- Build/test policy: `docs/build-system.md` and `docs/testing-guide.md`
