BINARY := eda-kicad-sync
PKG    := ./cmd/eda-kicad-sync

# KiCad's user plugin folder, per OS. Override on the command line if your
# install puts it somewhere non-standard.
KICAD_PLUGIN_DIR_linux   := $(HOME)/.local/share/kicad/10.0/3rdparty/plugins/eda-sync
KICAD_PLUGIN_DIR_darwin  := $(HOME)/Library/Preferences/kicad/10.0/3rdparty/plugins/eda-sync
KICAD_PLUGIN_DIR ?= $(KICAD_PLUGIN_DIR_$(shell uname -s | tr A-Z a-z))

.PHONY: build install uninstall test proto clean cross

build:
	go build -trimpath -ldflags="-s -w" -o $(BINARY) $(PKG)

# Symlinks the source tree into KiCad's plugin folder so `git pull` updates
# the plugin. The binary lives next to plugin.json so the relative
# `./eda-kicad-sync` command in the manifest resolves.
install: build
	mkdir -p $(dir $(KICAD_PLUGIN_DIR))
	ln -snf $(CURDIR) $(KICAD_PLUGIN_DIR)
	@echo "Installed: $(KICAD_PLUGIN_DIR) -> $(CURDIR)"

uninstall:
	rm -f $(KICAD_PLUGIN_DIR)

test:
	go test ./...

# Regenerate Go bindings from KiCad's protobuf definitions. Requires:
#   - protoc on PATH
#   - protoc-gen-go installed (go install google.golang.org/protobuf/cmd/protoc-gen-go@latest)
#   - KICAD_SRC pointing to a clone of https://gitlab.com/kicad/code/kicad
proto:
	./scripts/gen-proto.sh

clean:
	rm -f $(BINARY)

# Cross-compile binaries for distribution.
cross:
	GOOS=linux   GOARCH=amd64 go build -trimpath -ldflags="-s -w" -o dist/$(BINARY)-linux-amd64   $(PKG)
	GOOS=darwin  GOARCH=amd64 go build -trimpath -ldflags="-s -w" -o dist/$(BINARY)-darwin-amd64  $(PKG)
	GOOS=darwin  GOARCH=arm64 go build -trimpath -ldflags="-s -w" -o dist/$(BINARY)-darwin-arm64  $(PKG)
	GOOS=windows GOARCH=amd64 go build -trimpath -ldflags="-s -w" -o dist/$(BINARY)-windows-amd64.exe $(PKG)
