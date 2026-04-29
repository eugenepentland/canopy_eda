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
mkdir -p "$OUT"

# All proto files KiCad ships, recursively. The IPC surface lives across
# several: base_types.proto, common/, board/, schematic/, etc.
mapfile -t PROTOS < <(find "$KICAD_SRC/api/proto" -name '*.proto')

protoc \
  --proto_path="$KICAD_SRC/api/proto" \
  --go_out="$OUT" \
  --go_opt=paths=source_relative \
  "${PROTOS[@]}"

echo "Generated $(find "$OUT" -name '*.pb.go' | wc -l) .pb.go files in $OUT"
