#!/usr/bin/env bash
# Regenerate Go bindings for KiCad's IPC API from the upstream .proto files.
#
# Prerequisites:
#   - protoc on PATH                (apt: protobuf-compiler  / brew: protobuf)
#   - protoc-gen-go installed       (go install google.golang.org/protobuf/cmd/protoc-gen-go@latest)
#   - KICAD_SRC pointing at a clone of https://gitlab.com/kicad/code/kicad
#
# Output goes to internal/kicad/proto/. Generated files are committed so
# downstream users don't need protoc to install the agent.

set -euo pipefail

cd "$(dirname "$0")/.."

if [[ -z "${KICAD_SRC:-}" ]]; then
  echo "error: set KICAD_SRC=<path-to-kicad-source-clone>" >&2
  echo "       e.g. git clone --depth 1 https://gitlab.com/kicad/code/kicad ~/src/kicad" >&2
  exit 2
fi

if [[ ! -d "$KICAD_SRC/api/proto" ]]; then
  echo "error: $KICAD_SRC/api/proto not found — wrong KICAD_SRC?" >&2
  exit 2
fi

OUT=internal/kicad/proto
GO_BASE=github.com/canopy/eda/tools/kicad-sync-go/internal/kicad/proto
mkdir -p "$OUT"

# All proto files KiCad ships, recursively. The IPC surface lives across
# several: base_types.proto, common/, board/, schematic/, etc.
mapfile -t PROTOS < <(cd "$KICAD_SRC/api/proto" && find . -name '*.proto' | sed 's|^\./||' | sort)

# KiCad's .proto files do not carry `option go_package`, so we map every
# file to a Go import path on the command line. We put each .proto in its
# own Go package (named after the file stem) to avoid import cycles —
# multiple .proto files in the same directory can import each other across
# directories, which collapses into a circular Go dependency if they share
# a package.
M_ARGS=()
for p in "${PROTOS[@]}"; do
  dir=$(dirname "$p")
  base=$(basename "$p" .proto)
  if [[ "$dir" == "." ]]; then
    pkg_dir="$base"
  else
    pkg_dir="${dir}/${base}"
  fi
  M_ARGS+=("--go_opt=M${p}=${GO_BASE}/${pkg_dir}")
done

# `paths=import` lays files out at their go_package path (one subdir per
# .proto file, matching the M-args above). Combined with --go_out=$OUT
# and the GO_BASE prefix in the M-args, this puts every generated .pb.go
# at internal/kicad/proto/<dir>/<stem>/<stem>.pb.go in its own package.
protoc \
  --proto_path="$KICAD_SRC/api/proto" \
  --go_out="$OUT" \
  --go_opt=module="$GO_BASE" \
  "${M_ARGS[@]}" \
  "${PROTOS[@]}"

echo "Generated $(find "$OUT" -name '*.pb.go' | wc -l) .pb.go files in $OUT"
