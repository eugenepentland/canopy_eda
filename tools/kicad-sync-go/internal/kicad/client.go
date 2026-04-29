package kicad

import (
	"errors"
	"fmt"
	"os"

	"go.nanomsg.org/mangos/v3"
	"go.nanomsg.org/mangos/v3/protocol/req"
	_ "go.nanomsg.org/mangos/v3/transport/ipc" // unix socket
	_ "go.nanomsg.org/mangos/v3/transport/tcp" // some KiCad builds use TCP
)

// Connect opens an NNG REQ socket against KiCad's IPC endpoint. KiCad sets
// the socket path in KICAD_API_SOCKET when it spawns a registered plugin.
//
// The returned Client buffers mutations and only flushes on Push so KiCad
// records each sync as a single undo step.
func Connect() (Client, error) {
	socketPath := os.Getenv("KICAD_API_SOCKET")
	if socketPath == "" {
		return nil, errors.New("KICAD_API_SOCKET is not set — run from KiCad's plugin button or export it manually")
	}
	token := os.Getenv("KICAD_API_TOKEN")

	sock, err := req.NewSocket()
	if err != nil {
		return nil, fmt.Errorf("nng socket: %w", err)
	}
	dialURL := socketPath
	if !looksLikeURL(dialURL) {
		// KiCad usually advertises a Unix socket path; mangos's IPC
		// transport wants the `ipc://` scheme.
		dialURL = "ipc://" + socketPath
	}
	if err := sock.Dial(dialURL); err != nil {
		_ = sock.Close()
		return nil, fmt.Errorf("dial %s: %w", dialURL, err)
	}
	return &realClient{sock: sock, token: token}, nil
}

func looksLikeURL(s string) bool {
	for _, p := range []string{"ipc://", "tcp://", "unix://"} {
		if len(s) >= len(p) && s[:len(p)] == p {
			return true
		}
	}
	return false
}

type realClient struct {
	sock  mangos.Socket
	token string

	pendingMessage string
	pending        []pendingOp
}

type pendingOp struct {
	kind  string
	uuid  string
	field string
	value string
	pad   string
	net   string
	ref   string
	mod   string
	pads  [][2]string
}

// ─────────────────────────────────────────────────────────────────────
// PROTO WIRE FORMAT — hand-stubbed for v1.
//
// The real implementation marshals KiCad's protobuf request envelope
// (api/proto/{base_types,common,board}.proto). Until scripts/gen-proto.sh
// has been run on a machine with KiCad's source tree, the methods below
// return errors instructing the user to populate internal/kicad/proto/
// with generated *.pb.go files. Once those exist, replace the stubbed
// callRaw with marshalled protobuf envelope + dispatch on the inner
// message type.
//
// See README.md "Building from source" for the one-time codegen step.

var errProtoStub = errors.New(
	"kicad/client.go: protobuf wire format not generated yet — " +
		"run `make proto` after cloning KiCad's repo (see README)")

func (c *realClient) BoardPath() (string, error)              { return "", errProtoStub }
func (c *realClient) ListFootprints() ([]Footprint, error)    { return nil, errProtoStub }
func (c *realClient) Begin(message string) error              { c.pendingMessage = message; c.pending = nil; return nil }

func (c *realClient) SetField(uuid, field, value string) error {
	c.pending = append(c.pending, pendingOp{kind: "set_field", uuid: uuid, field: field, value: value})
	return nil
}

func (c *realClient) SetPadNet(uuid, pad, net string) error {
	c.pending = append(c.pending, pendingOp{kind: "set_pad_net", uuid: uuid, pad: pad, net: net})
	return nil
}

func (c *realClient) AddFootprint(mod, uuid, ref, value string, padNets [][2]string) error {
	c.pending = append(c.pending, pendingOp{kind: "add", uuid: uuid, ref: ref, value: value, mod: mod, pads: padNets})
	return nil
}

func (c *realClient) SwapFootprint(uuid, mod string, padNets [][2]string) error {
	c.pending = append(c.pending, pendingOp{kind: "swap", uuid: uuid, mod: mod, pads: padNets})
	return nil
}

func (c *realClient) Remove(uuid string) error {
	c.pending = append(c.pending, pendingOp{kind: "remove", uuid: uuid})
	return nil
}

func (c *realClient) Push() error {
	// Once protos exist, this is where we marshal a transaction envelope
	// containing all `pending` ops, send it via c.sock.Send, await reply.
	if len(c.pending) == 0 {
		return nil
	}
	return errProtoStub
}

func (c *realClient) Close() error {
	if c.sock == nil {
		return nil
	}
	err := c.sock.Close()
	c.sock = nil
	return err
}
