package protocol

import (
	"io"
	"net"
	"time"

	"github.com/sagernet/sing-cloudflared/internal/tunnelrpc"
	E "github.com/sagernet/sing/common/exceptions"

	"github.com/google/uuid"
	capnp "zombiezen.com/go/capnproto2"
	"zombiezen.com/go/capnproto2/pogs"
)

var (
	DataStreamSignature = [6]byte{0x0A, 0x36, 0xCD, 0x12, 0xA1, 0x3E}
	RPCStreamSignature  = [6]byte{0x52, 0xBB, 0x82, 0x5C, 0xDB, 0x65}
)

const ProtocolVersion = "01"

type StreamType int

const (
	StreamTypeData StreamType = iota
	StreamTypeRPC
)

const MetadataFlowConnectRateLimited = "FlowConnectRateLimited"

type ConnectionType uint16

const (
	ConnectionTypeHTTP ConnectionType = iota
	ConnectionTypeWebsocket
	ConnectionTypeTCP
)

func (c ConnectionType) String() string {
	switch c {
	case ConnectionTypeHTTP:
		return "http"
	case ConnectionTypeWebsocket:
		return "websocket"
	case ConnectionTypeTCP:
		return "tcp"
	default:
		return "unknown"
	}
}

type Metadata struct {
	Key string `capnp:"key"`
	Val string `capnp:"val"`
}

func FlowConnectRateLimitedMetadata() []Metadata {
	return []Metadata{{
		Key: MetadataFlowConnectRateLimited,
		Val: "true",
	}}
}

func HasFlowConnectRateLimited(metadata []Metadata) bool {
	for _, entry := range metadata {
		if entry.Key == MetadataFlowConnectRateLimited && entry.Val == "true" {
			return true
		}
	}
	return false
}

type ConnectRequest struct {
	Dest     string         `capnp:"dest"`
	Type     ConnectionType `capnp:"type"`
	Metadata []Metadata     `capnp:"metadata"`
}

func (r *ConnectRequest) MetadataMap() map[string]string {
	result := make(map[string]string, len(r.Metadata))
	for _, m := range r.Metadata {
		result[m.Key] = m.Val
	}
	return result
}

func (r *ConnectRequest) FromCapnp(msg *capnp.Message) error {
	root, err := tunnelrpc.ReadRootConnectRequest(msg)
	if err != nil {
		return err
	}
	return pogs.Extract(r, tunnelrpc.ConnectRequest_TypeID, root.Struct)
}

type ConnectResponse struct {
	Error    string     `capnp:"error"`
	Metadata []Metadata `capnp:"metadata"`
}

func (r *ConnectResponse) ToCapnp() (*capnp.Message, error) {
	msg, seg, err := capnp.NewMessage(capnp.SingleSegment(nil))
	if err != nil {
		return nil, err
	}
	root, err := tunnelrpc.NewRootConnectResponse(seg)
	if err != nil {
		return nil, err
	}
	err = pogs.Insert(tunnelrpc.ConnectResponse_TypeID, root.Struct, r)
	if err != nil {
		return nil, err
	}
	return msg, nil
}

func ReadStreamSignature(r io.Reader) (StreamType, error) {
	var signature [6]byte
	_, err := io.ReadFull(r, signature[:])
	if err != nil {
		return 0, err
	}
	switch signature {
	case DataStreamSignature:
		return StreamTypeData, nil
	case RPCStreamSignature:
		return StreamTypeRPC, nil
	default:
		return 0, E.New("unknown stream signature")
	}
}

func ReadConnectRequest(r io.Reader) (*ConnectRequest, error) {
	version := make([]byte, 2)
	_, err := io.ReadFull(r, version)
	if err != nil {
		return nil, E.Cause(err, "read version")
	}

	msg, err := capnp.NewDecoder(r).Decode()
	if err != nil {
		return nil, E.Cause(err, "decode connect request")
	}

	request := &ConnectRequest{}
	err = request.FromCapnp(msg)
	if err != nil {
		return nil, E.Cause(err, "extract connect request")
	}
	return request, nil
}

func WriteConnectResponse(w io.Writer, responseError error, metadata ...Metadata) error {
	response := &ConnectResponse{
		Metadata: metadata,
	}
	if responseError != nil {
		response.Error = responseError.Error()
	}

	msg, err := response.ToCapnp()
	if err != nil {
		return E.Cause(err, "encode connect response")
	}

	_, err = w.Write(DataStreamSignature[:])
	if err != nil {
		return err
	}
	_, err = w.Write([]byte(ProtocolVersion))
	if err != nil {
		return err
	}
	return capnp.NewEncoder(w).Encode(msg)
}

func WriteRPCStreamSignature(w io.Writer) error {
	_, err := w.Write(RPCStreamSignature[:])
	return err
}

type RegistrationTunnelAuth struct {
	AccountTag   string `capnp:"accountTag"`
	TunnelSecret []byte `capnp:"tunnelSecret"`
}

type RegistrationClientInfo struct {
	ClientID []byte   `capnp:"clientId"`
	Features []string `capnp:"features"`
	Version  string   `capnp:"version"`
	Arch     string   `capnp:"arch"`
}

type RegistrationConnectionOptions struct {
	Client              RegistrationClientInfo `capnp:"client"`
	OriginLocalIP       net.IP                 `capnp:"originLocalIp"`
	ReplaceExisting     bool                   `capnp:"replaceExisting"`
	CompressionQuality  uint8                  `capnp:"compressionQuality"`
	NumPreviousAttempts uint8                  `capnp:"numPreviousAttempts"`
}

type RegistrationResult struct {
	ConnectionID            uuid.UUID
	Location                string
	TunnelIsRemotelyManaged bool
}

type RetryableError struct {
	Err   error
	Delay time.Duration
}

func (e *RetryableError) Error() string {
	return e.Err.Error()
}

func (e *RetryableError) Unwrap() error {
	return e.Err
}
