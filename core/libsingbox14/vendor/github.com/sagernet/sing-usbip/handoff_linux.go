//go:build linux

package usbip

import (
	"context"
	"errors"
	"net"
	"os"
	"sync"

	"github.com/sagernet/sing/common"
	sBufio "github.com/sagernet/sing/common/bufio"
	E "github.com/sagernet/sing/common/exceptions"
	"github.com/sagernet/sing/common/logger"
	N "github.com/sagernet/sing/common/network"

	"golang.org/x/sys/unix"
)

var _ DataSession = (*kernelHandoffSession)(nil)

type kernelHandoffSession struct {
	ctx         context.Context
	logger      logger.ContextLogger
	side        string
	busid       string
	conn        net.Conn
	file        *os.File
	monitorFile *os.File
	relayConn   net.Conn

	wakeReader *os.File
	wakeWriter *os.File
	wakeOnce   sync.Once

	done      chan struct{}
	doneOnce  sync.Once
	runErr    error
	closeOnce sync.Once
	closeErr  error

	stateAccess sync.Mutex
	started     bool
	closed      bool
}

func newKernelHandoffSession(ctx context.Context, conn net.Conn, logger logger.ContextLogger, side string, busid string) (*kernelHandoffSession, error) {
	if tcpConn, _ := N.UnwrapReader(conn).(*net.TCPConn); tcpConn != nil {
		file, err := tcpConn.File()
		if err != nil {
			return nil, E.Cause(err, "dup TCP socket fd")
		}
		monitorFile, err := tcpConn.File()
		if err != nil {
			_ = file.Close()
			return nil, E.Cause(err, "dup TCP socket monitor fd")
		}
		wakeReader, wakeWriter, err := os.Pipe()
		if err != nil {
			_ = file.Close()
			_ = monitorFile.Close()
			return nil, E.Cause(err, "create monitor wake pipe")
		}
		return &kernelHandoffSession{
			ctx:         ctx,
			logger:      logger,
			side:        side,
			busid:       busid,
			conn:        conn,
			file:        file,
			monitorFile: monitorFile,
			wakeReader:  wakeReader,
			wakeWriter:  wakeWriter,
			done:        make(chan struct{}),
		}, nil
	}

	fds, err := unix.Socketpair(unix.AF_UNIX, unix.SOCK_STREAM|unix.SOCK_CLOEXEC, 0)
	if err != nil {
		return nil, E.Cause(err, "create USB/IP relay socketpair")
	}
	kernelFile := os.NewFile(uintptr(fds[0]), "usbip-kernel")
	relayFile := os.NewFile(uintptr(fds[1]), "usbip-relay")
	relayConn, err := net.FileConn(relayFile)
	_ = relayFile.Close()
	if err != nil {
		_ = kernelFile.Close()
		return nil, E.Cause(err, "wrap USB/IP relay socket")
	}
	return &kernelHandoffSession{
		ctx:       ctx,
		logger:    logger,
		side:      side,
		busid:     busid,
		conn:      conn,
		file:      kernelFile,
		relayConn: relayConn,
		done:      make(chan struct{}),
	}, nil
}

func (h *kernelHandoffSession) closeKernelFD() error {
	if h.file == nil {
		return nil
	}
	err := h.file.Close()
	h.file = nil
	return err
}

func (h *kernelHandoffSession) Done() <-chan struct{} {
	return h.done
}

func (h *kernelHandoffSession) Err() error {
	return h.runErr
}

func (h *kernelHandoffSession) Close() error {
	h.stateAccess.Lock()
	h.closed = true
	conn := h.conn
	relayConn := h.relayConn
	h.conn = nil
	h.relayConn = nil
	var monitorFile, wakeReader *os.File
	if !h.started {
		monitorFile = h.monitorFile
		wakeReader = h.wakeReader
		h.monitorFile = nil
		h.wakeReader = nil
	}
	h.stateAccess.Unlock()

	h.signalWake()
	h.closeOnce.Do(func() {
		h.closeErr = E.Errors(
			h.closeKernelFD(),
			common.Close(monitorFile),
			common.Close(wakeReader),
			common.Close(relayConn),
			common.Close(conn),
		)
	})
	h.markDone(nil)
	return h.closeErr
}

func (h *kernelHandoffSession) abortPreservingConn() {
	h.stateAccess.Lock()
	h.conn = nil
	h.stateAccess.Unlock()
	_ = h.Close()
}

func (h *kernelHandoffSession) signalWake() {
	h.wakeOnce.Do(func() {
		if h.wakeWriter != nil {
			_ = h.wakeWriter.Close()
		}
	})
}

func (h *kernelHandoffSession) markDone(err error) {
	h.doneOnce.Do(func() {
		h.runErr = err
		close(h.done)
	})
}

func (h *kernelHandoffSession) Start() error {
	h.stateAccess.Lock()
	if h.started || h.closed {
		h.stateAccess.Unlock()
		return nil
	}
	h.started = true
	conn := h.conn
	relayConn := h.relayConn
	monitorFile := h.monitorFile
	wakeReader := h.wakeReader
	h.stateAccess.Unlock()

	if relayConn == nil {
		err := common.Close(conn)
		if err != nil && !E.IsClosedOrCanceled(err) {
			h.logger.Debug("close usbip ", h.side, " userspace socket ", h.busid, ": ", err)
		}
		h.stateAccess.Lock()
		if h.conn == conn {
			h.conn = nil
		}
		h.stateAccess.Unlock()
		go h.runDirect(h.ctx, h.logger, h.side, h.busid, monitorFile, wakeReader)
		return nil
	}
	go h.runRelay(h.ctx, h.logger, h.side, h.busid, conn, relayConn)
	return nil
}

func (h *kernelHandoffSession) runDirect(ctx context.Context, logger logger.ContextLogger, side string, busid string, file *os.File, wakeReader *os.File) {
	stopWakeOnCancel := context.AfterFunc(ctx, h.signalWake)
	defer func() {
		stopWakeOnCancel()
		_ = file.Close()
		_ = wakeReader.Close()
		h.signalWake()
	}()
	fd := int32(file.Fd())
	wakeFd := int32(wakeReader.Fd())
	for {
		events := int16(unix.POLLHUP | unix.POLLERR | unix.POLLRDHUP)
		fds := []unix.PollFd{
			{Fd: fd, Events: events},
			{Fd: wakeFd, Events: int16(unix.POLLIN)},
		}
		_, err := unix.Poll(fds, -1)
		if err == unix.EINTR {
			continue
		}
		if err != nil {
			if ctx.Err() == nil && !errors.Is(err, unix.EBADF) {
				logger.Debug("usbip ", side, " direct monitor ", busid, ": ", err)
				h.markDone(err)
				return
			}
			h.markDone(nil)
			return
		}
		if fds[1].Revents != 0 {
			h.markDone(nil)
			return
		}
		if fds[0].Revents&(events|unix.POLLNVAL) != 0 {
			h.markDone(nil)
			return
		}
	}
}

func (h *kernelHandoffSession) runRelay(ctx context.Context, logger logger.ContextLogger, side string, busid string, conn net.Conn, relayConn net.Conn) {
	err := sBufio.CopyConn(ctx, conn, relayConn)
	var runErr error
	switch {
	case err == nil:
		logger.Debug("usbip ", side, " relay ", busid, " closed")
	case ctx.Err() == nil && !E.IsClosedOrCanceled(err):
		logger.Warn("usbip ", side, " relay ", busid, ": ", err)
		runErr = err
	default:
		logger.Debug("usbip ", side, " relay ", busid, ": ", err)
	}
	h.markDone(runErr)
}
