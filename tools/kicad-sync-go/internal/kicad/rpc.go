package kicad

import (
	"errors"
	"fmt"

	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/types/known/anypb"

	envelope "github.com/eugenepentland/canvas_eda/tools/kicad-sync-go/internal/kicad/proto/common/envelope"
)

// clientName goes in every ApiRequestHeader so KiCad's debug logs can tell
// us apart from other plugins.
const clientName = "com.canopy.eda-sync.go-agent"

// rpc sends `inner` wrapped in an ApiRequest envelope, waits for an
// ApiResponse, and either returns the response payload (still wrapped in
// anypb.Any so the caller can unpack the expected type) or an error.
//
// The token is left empty — KiCad only enforces token matching when it's
// non-empty, and we don't have a reliable way to obtain it from a legacy
// ActionPlugin parent process. For Linux/macOS sockets and Windows named
// pipes, mere ability to dial the IPC endpoint is the security boundary.
func (c *realClient) rpc(inner proto.Message) (*anypb.Any, error) {
	if c.sock == nil {
		return nil, errors.New("kicad client closed")
	}
	any, err := anypb.New(inner)
	if err != nil {
		return nil, fmt.Errorf("wrap %T in Any: %w", inner, err)
	}
	req := &envelope.ApiRequest{
		Header: &envelope.ApiRequestHeader{
			KicadToken: c.token,
			ClientName: clientName,
		},
		Message: any,
	}
	body, err := proto.Marshal(req)
	if err != nil {
		return nil, fmt.Errorf("marshal request: %w", err)
	}
	if err := c.sock.Send(body); err != nil {
		return nil, fmt.Errorf("nng send: %w", err)
	}
	respBytes, err := c.sock.Recv()
	if err != nil {
		return nil, fmt.Errorf("nng recv: %w", err)
	}
	var resp envelope.ApiResponse
	if err := proto.Unmarshal(respBytes, &resp); err != nil {
		return nil, fmt.Errorf("unmarshal response: %w", err)
	}
	if s := resp.GetStatus(); s != nil && s.GetStatus() != envelope.ApiStatusCode_AS_OK {
		return nil, fmt.Errorf("kicad %s: %s", s.GetStatus().String(), s.GetErrorMessage())
	}
	return resp.GetMessage(), nil
}

