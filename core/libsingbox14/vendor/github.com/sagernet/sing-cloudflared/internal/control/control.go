package control

import (
	"context"
	"io"
	"net"
	"runtime"
	"time"

	"github.com/sagernet/sing-cloudflared/internal/protocol"
	"github.com/sagernet/sing-cloudflared/internal/tunnelrpc"
	E "github.com/sagernet/sing/common/exceptions"

	"github.com/google/uuid"
	"zombiezen.com/go/capnproto2/pogs"
	"zombiezen.com/go/capnproto2/rpc"
)

const (
	RPCTimeout = 5 * time.Second
)

var ClientVersion = "sing-cloudflared"

var ErrNonRemoteManagedTunnelUnsupported = E.New("cloudflared only supports remote-managed tunnels")

var NewRegistrationClient = func(ctx context.Context, stream io.ReadWriteCloser) RegistrationRPCClient {
	return CreateRegistrationClient(ctx, stream)
}

type RegistrationClient struct {
	client    tunnelrpc.TunnelServer
	rpcConn   *rpc.Conn
	transport rpc.Transport
}

type RegistrationRPCClient interface {
	RegisterConnection(
		ctx context.Context,
		auth protocol.TunnelAuth,
		tunnelID uuid.UUID,
		connIndex uint8,
		options *protocol.RegistrationConnectionOptions,
	) (*protocol.RegistrationResult, error)
	Unregister(ctx context.Context) error
	Close() error
}

type PermanentRegistrationError struct {
	Err error
}

func (e *PermanentRegistrationError) Error() string {
	if e == nil || e.Err == nil {
		return "permanent registration error"
	}
	return e.Err.Error()
}

func (e *PermanentRegistrationError) Unwrap() error {
	if e == nil {
		return nil
	}
	return e.Err
}

func IsPermanentRegistrationError(err error) bool {
	_, found := E.Cast[*PermanentRegistrationError](err)
	return found
}

func CreateRegistrationClient(ctx context.Context, stream io.ReadWriteCloser) *RegistrationClient {
	transport := SafeTransport(stream)
	conn := NewRPCClientConn(transport)
	return &RegistrationClient{
		client:    tunnelrpc.TunnelServer{Client: conn.Bootstrap(ctx)},
		rpcConn:   conn,
		transport: transport,
	}
}

func (c *RegistrationClient) RegisterConnection(
	ctx context.Context,
	auth protocol.TunnelAuth,
	tunnelID uuid.UUID,
	connIndex uint8,
	options *protocol.RegistrationConnectionOptions,
) (*protocol.RegistrationResult, error) {
	ctx, cancel := context.WithTimeout(ctx, RPCTimeout)
	defer cancel()

	promise := c.client.RegisterConnection(ctx, func(p tunnelrpc.RegistrationServer_registerConnection_Params) error {
		tunnelAuth, err := p.NewAuth()
		if err != nil {
			return err
		}
		authPogs := &protocol.RegistrationTunnelAuth{
			AccountTag:   auth.AccountTag,
			TunnelSecret: auth.TunnelSecret,
		}
		err = pogs.Insert(tunnelrpc.TunnelAuth_TypeID, tunnelAuth.Struct, authPogs)
		if err != nil {
			return err
		}

		err = p.SetTunnelId(tunnelID[:])
		if err != nil {
			return err
		}

		p.SetConnIndex(connIndex)

		connOptions, err := p.NewOptions()
		if err != nil {
			return err
		}
		return pogs.Insert(tunnelrpc.ConnectionOptions_TypeID, connOptions.Struct, options)
	})

	response, err := promise.Result().Struct()
	if err != nil {
		return nil, E.Cause(err, "registration RPC")
	}

	result := response.Result()
	switch result.Which() {
	case tunnelrpc.ConnectionResponse_result_Which_error:
		resultError, err := result.Error()
		if err != nil {
			return nil, E.Cause(err, "read registration error")
		}
		cause, _ := resultError.Cause()
		registrationError := E.New(cause)
		if resultError.ShouldRetry() {
			return nil, &protocol.RetryableError{
				Err:   registrationError,
				Delay: time.Duration(resultError.RetryAfter()),
			}
		}
		return nil, &PermanentRegistrationError{Err: registrationError}

	case tunnelrpc.ConnectionResponse_result_Which_connectionDetails:
		connDetails, err := result.ConnectionDetails()
		if err != nil {
			return nil, E.Cause(err, "read connection details")
		}
		uuidBytes, err := connDetails.Uuid()
		if err != nil {
			return nil, E.Cause(err, "read connection UUID")
		}
		connectionID, err := uuid.FromBytes(uuidBytes)
		if err != nil {
			return nil, E.Cause(err, "parse connection UUID")
		}
		location, _ := connDetails.LocationName()
		return &protocol.RegistrationResult{
			ConnectionID:            connectionID,
			Location:                location,
			TunnelIsRemotelyManaged: connDetails.TunnelIsRemotelyManaged(),
		}, nil

	default:
		return nil, E.New("unexpected registration response type")
	}
}

func (c *RegistrationClient) Unregister(ctx context.Context) error {
	promise := c.client.UnregisterConnection(ctx, nil)
	_, err := promise.Struct()
	return err
}

func (c *RegistrationClient) Close() error {
	return E.Errors(
		c.rpcConn.Close(),
		c.transport.Close(),
	)
}

func ValidateRegistrationResult(result *protocol.RegistrationResult) error {
	if result == nil || result.TunnelIsRemotelyManaged {
		return nil
	}
	return ErrNonRemoteManagedTunnelUnsupported
}

func BuildConnectionOptions(connectorID uuid.UUID, features []string, numPreviousAttempts uint8, originLocalIP net.IP) *protocol.RegistrationConnectionOptions {
	return &protocol.RegistrationConnectionOptions{
		Client: protocol.RegistrationClientInfo{
			ClientID: connectorID[:],
			Features: features,
			Version:  ClientVersion,
			Arch:     runtime.GOOS + "_" + runtime.GOARCH,
		},
		ReplaceExisting:     false,
		CompressionQuality:  0,
		OriginLocalIP:       originLocalIP,
		NumPreviousAttempts: numPreviousAttempts,
	}
}

var (
	defaultFeaturesV2 = []string{
		"serialized_headers",
		"support_datagram_v2",
		"support_quic_eof",
		"allow_remote_config",
	}
	defaultFeaturesV3 = []string{
		"serialized_headers",
		"support_datagram_v2",
		"support_quic_eof",
		"allow_remote_config",
		"support_datagram_v3_2",
	}
)

func DefaultFeatures(datagramVersion string) []string {
	if datagramVersion == protocol.DatagramVersionV3 {
		return append([]string(nil), defaultFeaturesV3...)
	}
	return append([]string(nil), defaultFeaturesV2...)
}
