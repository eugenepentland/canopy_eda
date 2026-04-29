# Regenerate Go bindings for KiCad's IPC API on Windows / PowerShell.
#
# Prerequisites:
#   - Go installed (https://go.dev/dl/)
#   - protoc installed (https://github.com/protocolbuffers/protobuf/releases),
#     with protoc.exe on PATH.
#   - protoc-gen-go installed:
#       go install google.golang.org/protobuf/cmd/protoc-gen-go@latest
#     The above puts protoc-gen-go.exe in $env:GOPATH\bin; make sure that's
#     on PATH (or run `go env GOPATH` and add it).
#   - $env:KICAD_SRC pointing at a clone of https://gitlab.com/kicad/code/kicad
#
# Usage (from tools/kicad-sync-go):
#   $env:KICAD_SRC = "C:\Users\you\Code\kicad-src"
#   .\scripts\gen-proto.ps1

param()

$ErrorActionPreference = 'Stop'

# Anchor at the script's parent (tools/kicad-sync-go).
Set-Location (Join-Path $PSScriptRoot '..')

if (-not $env:KICAD_SRC) {
    Write-Error "Set `$env:KICAD_SRC to a path like C:\Users\you\Code\kicad-src first.`n  e.g. git clone --depth 1 https://gitlab.com/kicad/code/kicad C:\Users\you\Code\kicad-src"
    exit 2
}

$protoRoot = Join-Path $env:KICAD_SRC 'api\proto'
if (-not (Test-Path $protoRoot)) {
    Write-Error "$protoRoot not found — wrong `$env:KICAD_SRC?"
    exit 2
}

# Verify protoc is available.
if (-not (Get-Command protoc -ErrorAction SilentlyContinue)) {
    Write-Error "protoc not on PATH. Install from https://github.com/protocolbuffers/protobuf/releases and add the bin/ folder to PATH."
    exit 2
}

# Verify protoc-gen-go is on PATH.
if (-not (Get-Command protoc-gen-go -ErrorAction SilentlyContinue)) {
    $goPath = (& go env GOPATH).Trim()
    Write-Error "protoc-gen-go not on PATH.`n  go install google.golang.org/protobuf/cmd/protoc-gen-go@latest`n  then add $goPath\bin to PATH."
    exit 2
}

$out = 'internal\kicad\proto'
New-Item -ItemType Directory -Force -Path $out | Out-Null

$protos = Get-ChildItem -Recurse -Filter *.proto -Path $protoRoot | ForEach-Object { $_.FullName }

if ($protos.Count -eq 0) {
    Write-Error "No .proto files found under $protoRoot"
    exit 2
}

$protocArgs = @(
    "--proto_path=$protoRoot",
    "--go_out=$out",
    "--go_opt=paths=source_relative"
) + $protos

& protoc @protocArgs

$generated = (Get-ChildItem -Recurse -Filter *.pb.go -Path $out | Measure-Object).Count
Write-Host "Generated $generated .pb.go files in $out"
