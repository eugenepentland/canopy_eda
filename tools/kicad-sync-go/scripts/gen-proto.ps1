# Regenerate Go bindings for KiCad's IPC API on Windows / PowerShell.
#
# Prerequisites:
#   - Go installed (https://go.dev/dl/)
#   - protoc on PATH (https://github.com/protocolbuffers/protobuf/releases)
#   - protoc-gen-go on PATH:
#       go install google.golang.org/protobuf/cmd/protoc-gen-go@latest
#       (lives in $(go env GOPATH)\bin — make sure that's on PATH)
#   - $env:KICAD_SRC pointing at a clone of https://gitlab.com/kicad/code/kicad
#
# Usage (from tools/kicad-sync-go):
#   $env:KICAD_SRC = 'C:\Users\you\Code\kicad-src'
#   .\scripts\gen-proto.ps1

param()

$ErrorActionPreference = 'Stop'

# Anchor at the script's parent (tools/kicad-sync-go).
Set-Location (Join-Path $PSScriptRoot '..')

if (-not $env:KICAD_SRC) {
    Write-Host 'error: set $env:KICAD_SRC to a path like C:\Users\you\Code\kicad-src first.' -ForegroundColor Red
    Write-Host '  git clone --depth 1 https://gitlab.com/kicad/code/kicad C:\Users\you\Code\kicad-src'
    exit 2
}

$protoRoot = Join-Path $env:KICAD_SRC 'api\proto'
if (-not (Test-Path $protoRoot)) {
    Write-Host ('error: ' + $protoRoot + ' not found - wrong $env:KICAD_SRC?') -ForegroundColor Red
    exit 2
}

if (-not (Get-Command protoc -ErrorAction SilentlyContinue)) {
    Write-Host 'error: protoc not on PATH.' -ForegroundColor Red
    Write-Host 'Install from https://github.com/protocolbuffers/protobuf/releases and add the bin folder to PATH.'
    exit 2
}

if (-not (Get-Command protoc-gen-go -ErrorAction SilentlyContinue)) {
    $goBin = (& go env GOPATH).Trim() + '\bin'
    Write-Host 'error: protoc-gen-go not on PATH.' -ForegroundColor Red
    Write-Host '  go install google.golang.org/protobuf/cmd/protoc-gen-go@latest'
    Write-Host ('  then add ' + $goBin + ' to PATH.')
    exit 2
}

$out = 'internal\kicad\proto'
New-Item -ItemType Directory -Force -Path $out | Out-Null

$protos = Get-ChildItem -Recurse -Filter *.proto -Path $protoRoot | ForEach-Object { $_.FullName }

if ($protos.Count -eq 0) {
    Write-Host ('error: no .proto files found under ' + $protoRoot) -ForegroundColor Red
    exit 2
}

$protocArgs = @(
    ('--proto_path=' + $protoRoot),
    ('--go_out=' + $out),
    '--go_opt=paths=source_relative'
) + $protos

& protoc @protocArgs

$generated = (Get-ChildItem -Recurse -Filter *.pb.go -Path $out | Measure-Object).Count
Write-Host ('Generated ' + $generated + ' .pb.go files in ' + $out)
