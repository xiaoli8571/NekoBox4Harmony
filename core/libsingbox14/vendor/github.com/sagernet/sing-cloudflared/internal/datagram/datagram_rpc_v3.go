package datagram

import (
	"context"
	"io"

	"github.com/sagernet/sing-cloudflared/internal/control"
	"github.com/sagernet/sing-cloudflared/internal/tunnelrpc"
	E "github.com/sagernet/sing/common/exceptions"
	"github.com/sagernet/sing/common/logger"
)

var (
	ErrUnsupportedDatagramV3UDPRegistration   = E.New("datagram v3 does not support RegisterUdpSession RPC")
	ErrUnsupportedDatagramV3UDPUnregistration = E.New("datagram v3 does not support UnregisterUdpSession RPC")
)

type CloudflaredV3Server struct {
	applyConfig control.ConfigApplier
	logger      logger.ContextLogger
}

func (s *CloudflaredV3Server) RegisterUdpSession(call tunnelrpc.SessionManager_registerUdpSession) error {
	result, err := call.Results.NewResult()
	if err != nil {
		return err
	}
	err = result.SetErr(ErrUnsupportedDatagramV3UDPRegistration.Error())
	if err != nil {
		return err
	}
	return result.SetSpans([]byte{})
}

func (s *CloudflaredV3Server) UnregisterUdpSession(call tunnelrpc.SessionManager_unregisterUdpSession) error {
	return ErrUnsupportedDatagramV3UDPUnregistration
}

func (s *CloudflaredV3Server) UpdateConfiguration(call tunnelrpc.ConfigurationManager_updateConfiguration) error {
	return control.HandleUpdateConfiguration(s.applyConfig, call)
}

func ServeV3RPCStream(ctx context.Context, stream io.ReadWriteCloser, applyConfig control.ConfigApplier, log logger.ContextLogger) {
	srv := &CloudflaredV3Server{
		applyConfig: applyConfig,
		logger:      log,
	}
	client := tunnelrpc.CloudflaredServer_ServerToClient(srv)
	control.ServeRPCConn(ctx, stream, client.Client)
}
