package control

import (
	"context"
	"io"
	"time"

	"github.com/sagernet/sing-cloudflared/internal/config"
	"github.com/sagernet/sing-cloudflared/internal/tunnelrpc"
	E "github.com/sagernet/sing/common/exceptions"

	capnp "zombiezen.com/go/capnproto2"
	"zombiezen.com/go/capnproto2/rpc"
	"zombiezen.com/go/capnproto2/server"
)

const (
	safeTransportMaxRetries    = 3
	safeTransportRetryInterval = 500 * time.Millisecond
)

type safeReadWriteCloser struct {
	io.ReadWriteCloser
	retries int
}

func (s *safeReadWriteCloser) Read(p []byte) (int, error) {
	n, err := s.ReadWriteCloser.Read(p)
	if n == 0 && err != nil && isTemporaryError(err) {
		if s.retries >= safeTransportMaxRetries {
			return 0, E.Cause(err, "read capnproto transport after multiple temporary errors")
		}
		s.retries++
		time.Sleep(safeTransportRetryInterval)
		return n, err
	}
	if err == nil {
		s.retries = 0
	}
	return n, err
}

func isTemporaryError(err error) bool {
	type temporary interface{ Temporary() bool }
	t, ok := err.(temporary)
	return ok && t.Temporary()
}

func SafeTransport(stream io.ReadWriteCloser) rpc.Transport {
	return rpc.StreamTransport(&safeReadWriteCloser{ReadWriteCloser: stream})
}

type noopCapnpLogger struct{}

func (noopCapnpLogger) Infof(ctx context.Context, format string, args ...interface{})  {}
func (noopCapnpLogger) Errorf(ctx context.Context, format string, args ...interface{}) {}

func NewRPCClientConn(transport rpc.Transport) *rpc.Conn {
	return rpc.NewConn(transport, rpc.ConnLog(noopCapnpLogger{}))
}

func NewRPCServerConn(transport rpc.Transport, client capnp.Client) *rpc.Conn {
	return rpc.NewConn(transport, rpc.MainInterface(client), rpc.ConnLog(noopCapnpLogger{}))
}

func ServeRPCConn(ctx context.Context, stream io.ReadWriteCloser, client capnp.Client) {
	transport := SafeTransport(stream)
	rpcConn := NewRPCServerConn(transport, client)
	rpcCtx, cancel := context.WithTimeout(ctx, RPCTimeout)
	defer cancel()
	select {
	case <-rpcConn.Done():
	case <-rpcCtx.Done():
	}
	_ = E.Errors(
		rpcConn.Close(),
		transport.Close(),
	)
}

type ConfigApplier func(version int32, config []byte) config.UpdateResult

func HandleUpdateConfiguration(applyConfig ConfigApplier, call tunnelrpc.ConfigurationManager_updateConfiguration) error {
	server.Ack(call.Options)
	version := call.Params.Version()
	configData, _ := call.Params.Config()
	updateResult := applyConfig(version, configData)
	result, err := call.Results.NewResult()
	if err != nil {
		return err
	}
	result.SetLatestAppliedVersion(updateResult.LastAppliedVersion)
	if updateResult.Err != nil {
		result.SetErr(updateResult.Err.Error())
	} else {
		result.SetErr("")
	}
	return nil
}
