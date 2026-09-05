#!/usr/bin/env bash
# Install the exact Zig toolchain this repository is pinned to.
#
#   scripts/install-zig.sh            # install, then print the export line
#   scripts/install-zig.sh --link     # also symlink ~/.local/bin/zig at it
#   scripts/install-zig.sh --print    # print the install path and exit
#
# The version comes from .zigversion, the archive checksum from
# scripts/zig-toolchain.sha256, and the archive itself from the repository's
# GitHub release mirror first, ziglang.org second (that directory rotates
# nightly builds out). Idempotent: an already-extracted, correct-version
# install is left alone and reported.
#
# Environment:
#   ZIG_INSTALL_DIR   root for installs (default ~/.local/share/netlisp/zig)
#   ZIG_MIRROR_URL    base URL tried first (default: the GitHub release below)
#   ZIG_UPSTREAM_URL  base URL tried second (default https://ziglang.org/builds)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(tr -d '[:space:]' <"$ROOT/.zigversion")"
SUMS="$ROOT/scripts/zig-toolchain.sha256"
INSTALL_ROOT="${ZIG_INSTALL_DIR:-$HOME/.local/share/netlisp/zig}"
# The mirror tag is derived from the pin: 0.17.0-dev.1683+5ceec001b lives under
# the `toolchain-0.17.0-dev.1683` release, so a pin bump needs no edit here —
# only a new release carrying that version's archives.
MIRROR_URL="${ZIG_MIRROR_URL:-https://github.com/eugenepentland/netlisp/releases/download/toolchain-${VERSION%%+*}}"
UPSTREAM_URL="${ZIG_UPSTREAM_URL:-https://ziglang.org/builds}"

link=0
print_only=0
for arg in "$@"; do
  case "$arg" in
    --link) link=1 ;;
    --print) print_only=1 ;;
    -h | --help)
      cat <<'USAGE'
scripts/install-zig.sh — install the Zig toolchain pinned in .zigversion

  scripts/install-zig.sh            install, then print the export line
  scripts/install-zig.sh --link     also symlink ~/.local/bin/zig at it
  scripts/install-zig.sh --print    print the install path and exit

Environment:
  ZIG_INSTALL_DIR   root for installs (default ~/.local/share/netlisp/zig)
  ZIG_MIRROR_URL    base URL tried first (the repository's GitHub release)
  ZIG_UPSTREAM_URL  base URL tried second (default https://ziglang.org/builds)
USAGE
      exit 0
      ;;
    *)
      echo "install-zig: unknown option '$arg' (try --help)" >&2
      exit 2
      ;;
  esac
done

die() {
  echo "install-zig: $1" >&2
  exit 1
}

[ -n "$VERSION" ] || die "no version in $ROOT/.zigversion"
[ -f "$SUMS" ] || die "missing checksum table $SUMS"

# --- host detection ----------------------------------------------------------
# Zig names its archives zig-<arch>-<os>-<version>; both halves are its own
# spelling, not uname's, so map rather than interpolate.
case "$(uname -s)" in
  Linux) os=linux ;;
  Darwin) os=macos ;;
  *) die "unsupported OS '$(uname -s)' — install Zig $VERSION by hand (see ZIG_TOOLCHAIN.md)" ;;
esac
case "$(uname -m)" in
  x86_64 | amd64) arch=x86_64 ;;
  arm64 | aarch64) arch=aarch64 ;;
  *) die "unsupported CPU '$(uname -m)' — install Zig $VERSION by hand (see ZIG_TOOLCHAIN.md)" ;;
esac

archive="zig-$arch-$os-$VERSION.tar.xz"
dest="$INSTALL_ROOT/$VERSION"
zig_bin="$dest/zig"

if [ "$print_only" = 1 ]; then
  printf '%s\n' "$zig_bin"
  exit 0
fi

expected="$(awk -v want="$archive" '$2 == want { print $1 }' "$SUMS")"
[ -n "$expected" ] || die "no checksum for $archive in $SUMS (unsupported platform for this pin)"

link_zig() {
  [ "$link" = 1 ] || return 0
  mkdir -p "$HOME/.local/bin"
  ln -sfn "$zig_bin" "$HOME/.local/bin/zig"
  echo "install-zig: linked $HOME/.local/bin/zig -> $zig_bin"
  case ":$PATH:" in
    *":$HOME/.local/bin:"*) ;;
    *) echo "install-zig: NOTE — $HOME/.local/bin is not on PATH; add it to your shell profile" ;;
  esac
}

# --- idempotence -------------------------------------------------------------
# A correct install is a no-op. Checking the reported version (not just the
# path) is what makes a half-extracted or hand-edited directory re-install.
if [ -x "$zig_bin" ] && [ "$("$zig_bin" version 2>/dev/null || true)" = "$VERSION" ]; then
  echo "install-zig: Zig $VERSION already installed at $zig_bin"
  link_zig
  [ "$link" = 1 ] || echo "export PATH=\"$dest:\$PATH\""
  exit 0
fi

command -v curl >/dev/null 2>&1 || die "curl is required"
command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1 ||
  die "sha256sum (or shasum) is required"
command -v tar >/dev/null 2>&1 || die "tar is required"

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

# Download into the install root, not /tmp: the archive is ~57 MB, /tmp is a
# small tmpfs or a quota'd share on plenty of machines, and staging on the
# destination filesystem makes the final rename atomic.
mkdir -p "$INSTALL_ROOT"
tmp="$(mktemp -d "$INSTALL_ROOT/.download.XXXXXX")"
trap 'rm -rf -- "$tmp"' EXIT

# --- download ----------------------------------------------------------------
# The mirror is first because ziglang.org/builds is a rotating nightly
# directory: this exact snapshot can disappear from it at any time, and a
# pinned toolchain whose only source can vanish is not pinned.
downloaded=""
for base in "$MIRROR_URL" "$UPSTREAM_URL"; do
  [ -n "$base" ] || continue
  url="$base/$archive"
  echo "install-zig: fetching $url"
  if curl -fL --progress-bar --retry 3 --retry-delay 2 --connect-timeout 20 -o "$tmp/$archive" "$url"; then
    downloaded="$url"
    break
  fi
  echo "install-zig: $url unavailable, trying the next source" >&2
done
[ -n "$downloaded" ] || die "could not download $archive from the mirror or upstream"

actual="$(sha256_of "$tmp/$archive")"
if [ "$actual" != "$expected" ]; then
  echo "install-zig: SHA-256 mismatch for $archive (from $downloaded)" >&2
  echo "  expected: $expected" >&2
  echo "  got:      $actual" >&2
  exit 1
fi
echo "install-zig: SHA-256 verified ($expected)"

# --- extract -----------------------------------------------------------------
# Unpack beside the target and rename, so an interrupted run never leaves a
# partial tree that the idempotence check above would have to reason about.
staging="$(mktemp -d "$INSTALL_ROOT/.staging.XXXXXX")"
trap 'rm -rf -- "$tmp" "$staging"' EXIT
tar -xJf "$tmp/$archive" -C "$staging"
inner="$(find "$staging" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
[ -n "$inner" ] && [ -x "$inner/zig" ] || die "unexpected archive layout in $archive"

got="$("$inner/zig" version 2>/dev/null || true)"
[ "$got" = "$VERSION" ] || die "extracted compiler reports '$got', expected '$VERSION'"

rm -rf -- "$dest"
mkdir -p "$(dirname "$dest")"
mv "$inner" "$dest"
echo "install-zig: installed Zig $VERSION at $dest"

link_zig
if [ "$link" != 1 ]; then
  echo
  echo "Add it to your PATH:"
  echo "  export PATH=\"$dest:\$PATH\""
  echo "(or re-run with --link to symlink $HOME/.local/bin/zig)"
fi
