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
$goBase = 'github.com/canopy/eda/tools/kicad-sync-go/internal/kicad/proto'
New-Item -ItemType Directory -Force -Path $out | Out-Null

# Collect proto paths relative to $protoRoot, normalized to forward slashes
# (protoc expects forward slashes in M-mappings even on Windows).
$relProtos = Get-ChildItem -Recurse -Filter *.proto -Path $protoRoot | ForEach-Object {
    $rel = $_.FullName.Substring($protoRoot.Length).TrimStart('\','/')
    $rel -replace '\\','/'
}

if ($relProtos.Count -eq 0) {
    Write-Host ('error: no .proto files found under ' + $protoRoot) -ForegroundColor Red
    exit 2
}

# KiCad's .proto files do not carry `option go_package`; map each to its
# own Go package (named after the file stem) to avoid import cycles —
# multiple .proto files in the same directory can import across
# directories, which collapses into a circular Go dependency if they
# share a Go package.
$mArgs = @()
foreach ($p in $relProtos) {
    $dir = (Split-Path $p -Parent) -replace '\\','/'
    $base = [System.IO.Path]::GetFileNameWithoutExtension($p)
    if ([string]::IsNullOrEmpty($dir)) {
        $pkgDir = $base
    } else {
        $pkgDir = $dir + '/' + $base
    }
    $mArgs += ('--go_opt=M' + $p + '=' + $goBase + '/' + $pkgDir)
}

# --go_opt=module strips the GO_BASE prefix, so files land at
# $out/<dir>/<stem>/<stem>.pb.go matching the M-args. One package per
# .proto file, no conflicts.
$protocArgs = @(
    ('--proto_path=' + $protoRoot),
    ('--go_out=' + $out),
    ('--go_opt=module=' + $goBase)
) + $mArgs + $relProtos

& protoc @protocArgs

$generated = (Get-ChildItem -Recurse -Filter *.pb.go -Path $out | Measure-Object).Count
Write-Host ('Generated ' + $generated + ' .pb.go files in ' + $out)
