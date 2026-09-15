//go:build linux || (darwin && cgo) || windows

package usbip

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"time"

	E "github.com/sagernet/sing/common/exceptions"
	"github.com/sagernet/sing/common/logger"
	M "github.com/sagernet/sing/common/metadata"
	N "github.com/sagernet/sing/common/network"
)

type ClientService struct {
	ctx        context.Context
	cancel     context.CancelFunc
	logger     logger.ContextLogger
	dialer     N.Dialer
	serverAddr M.Socksaddr
	host       ImportHost

	assignment      *clientAssignment
	workerAccess    sync.Mutex
	assignedWorkers []*clientAssignedWorker
	allWorkers      map[string]*clientRemoteWorker

	workerGroup sync.WaitGroup

	remoteAccess  sync.Mutex
	remoteDevices map[string]ControlDeviceInfo
}

type clientRemoteWorker struct {
	cancel context.CancelFunc
}

func NewClientService(ctx context.Context, options ClientOptions) (*ClientService, error) {
	for i, deviceMatch := range options.Devices {
		if deviceMatch.IsZero() {
			return nil, E.New("devices[", i, "]: at least one of busid/vendor_id/product_id/serial is required")
		}
	}
	if !options.ServerAddress.IsValid() {
		return nil, E.New("missing server address")
	}
	if options.ServerAddress.Port == 0 {
		options.ServerAddress.Port = DefaultPort
	}
	serviceLogger := options.Logger
	if serviceLogger == nil {
		serviceLogger = logger.NOP()
	}
	outboundDialer := options.Dialer
	if outboundDialer == nil {
		outboundDialer = N.SystemDialer
	}
	host, err := newPlatformImportHost(serviceLogger)
	if err != nil {
		return nil, err
	}
	ctx, cancel := context.WithCancel(ctx)
	return &ClientService{
		ctx:        ctx,
		cancel:     cancel,
		logger:     serviceLogger,
		dialer:     outboundDialer,
		serverAddr: options.ServerAddress,
		host:       host,
		assignment: newClientAssignment(options.Devices),
		allWorkers: make(map[string]*clientRemoteWorker),
	}, nil
}

func (c *ClientService) Start() error {
	err := c.host.Start()
	if err != nil {
		return err
	}
	c.initializeWorkers()
	c.workerGroup.Add(1)
	go func() {
		defer c.workerGroup.Done()
		c.run()
	}()
	return nil
}

func (c *ClientService) Close() error {
	if c.cancel != nil {
		c.cancel()
	}
	c.workerGroup.Wait()
	_ = c.host.Close()
	return nil
}

func (c *ClientService) runBusIDLoop(ctx context.Context, busid, description string, expected DeviceMatch) {
	for {
		if ctx.Err() != nil {
			return
		}
		c.assignment.SetActive(busid, true)
		session, err := c.attemptAttach(ctx, busid, expected)
		if err != nil {
			c.assignment.SetActive(busid, false)
			if ctx.Err() != nil {
				return
			}
			c.logger.Error("attach ", description, " (", busid, "): ", err)
			if !errors.Is(err, errDialFailed) && !c.shouldRetryBusID(ctx, busid) {
				c.logger.Info("remote export ", busid, " disappeared; stopping import worker")
				return
			}
			if !sleepCtx(ctx, clientReconnectDelay) {
				return
			}
			continue
		}
		c.logger.Info("attached ", busid, " through ", session.Description())
		select {
		case <-session.Done():
			c.logger.Debug("import session for ", busid, " ended (", session.Description(), ")")
		case <-ctx.Done():
			_ = session.Close()
			<-session.Done()
		}
		_ = session.Close()
		c.assignment.SetActive(busid, false)
		if ctx.Err() != nil {
			return
		}
		if !c.shouldRetryBusID(ctx, busid) {
			c.logger.Info("remote export ", busid, " disappeared; stopping import worker")
			return
		}
		if !sleepCtx(ctx, clientReconnectDelay) {
			return
		}
	}
}

func (c *ClientService) shouldRetryBusID(ctx context.Context, busid string) bool {
	if c.assignment.Matched() {
		return true
	}
	err := c.syncRemoteStateContext(ctx)
	if err != nil {
		c.logger.Warn("refresh remote exports after releasing ", busid, ": ", err)
		return true
	}
	return c.assignment.IsRetryDesired(busid)
}

func (c *ClientService) attemptAttach(ctx context.Context, busid string, expected DeviceMatch) (AttachedSession, error) {
	conn, err := c.dialer.DialContext(ctx, N.NetworkTCP, c.serverAddr)
	if err != nil {
		return nil, E.Cause(errDialFailed, c.serverAddr.String(), ": ", err)
	}
	releaseConn := true
	defer func() {
		if releaseConn {
			_ = conn.Close()
		}
	}()
	stopCloseOnCancel := closeConnOnContextDone(ctx, conn)
	defer stopCloseOnCancel()

	_ = conn.SetWriteDeadline(time.Now().Add(opExchangeWriteTimeout))
	err = WriteOpReqImport(conn, busid)
	_ = conn.SetWriteDeadline(time.Time{})
	if err != nil {
		return nil, E.Cause(err, "write OP_REQ_IMPORT")
	}
	_ = conn.SetReadDeadline(time.Now().Add(opExchangeReadTimeout))
	header, err := ReadOpHeader(conn)
	if err != nil {
		return nil, E.Cause(err, "read OP_REP_IMPORT header")
	}
	if header.Version != ProtocolVersion {
		return nil, E.New("unexpected reply version ", fmt.Sprintf("0x%04x", header.Version))
	}
	if header.Code != OpRepImport {
		return nil, E.New("unexpected reply code ", fmt.Sprintf("0x%04x", header.Code))
	}
	if header.Status != OpStatusOK {
		return nil, E.Extend(errImportRejected, "status=", header.Status)
	}
	info, err := ReadOpRepImportBody(conn)
	if err != nil {
		return nil, E.Cause(err, "read OP_REP_IMPORT body")
	}
	_ = conn.SetReadDeadline(time.Time{})
	err = c.verifyImportedDevice(busid, info, expected)
	if err != nil {
		return nil, err
	}
	session, err := c.host.Attach(ctx, info, conn)
	if err != nil {
		return nil, err
	}
	releaseConn = false
	return session, nil
}

func (c *ClientService) verifyImportedDevice(busid string, info DeviceInfoTruncated, expected DeviceMatch) error {
	replyBusID := info.BusIDString()
	if replyBusID != busid {
		return E.New("server attached ", replyBusID, " instead of ", busid)
	}
	key := DeviceKey{
		BusID:     busid,
		VendorID:  info.IDVendor,
		ProductID: info.IDProduct,
	}
	snapshotKey, found := c.remoteDeviceKey(busid)
	if found && snapshotKey.VendorID == key.VendorID && snapshotKey.ProductID == key.ProductID {
		key.Serial = snapshotKey.Serial
	}
	adjusted := expected
	if adjusted.Serial != "" && key.Serial == "" {
		adjusted.Serial = ""
	}
	if !matches(adjusted, key) {
		return E.New("imported device vid=", fmt.Sprintf("0x%04x", key.VendorID),
			" pid=", fmt.Sprintf("0x%04x", key.ProductID),
			" serial=", key.Serial, " does not match ", describeMatch(expected))
	}
	return nil
}

func (c *ClientService) remoteDeviceKey(busid string) (DeviceKey, bool) {
	c.remoteAccess.Lock()
	defer c.remoteAccess.Unlock()
	device, found := c.remoteDevices[busid]
	if !found {
		return DeviceKey{}, false
	}
	return DeviceKey{
		BusID:     device.BusID,
		VendorID:  device.VendorID,
		ProductID: device.ProductID,
		Serial:    device.Serial,
	}, true
}
