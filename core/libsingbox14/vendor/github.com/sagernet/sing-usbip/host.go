//go:build linux || (darwin && cgo) || windows

package usbip

import (
	"context"
	"net"
)

type ExportHost interface {
	Start() error
	Close() error
	Reconcile(isReserved func(busid string) bool) (snapshot map[string]Export, released []string, err error)
	FinishImport(busid string) (released bool, err error)
	Events() (<-chan struct{}, error)
}

type ImportHost interface {
	Start() error
	Close() error
	Attach(ctx context.Context, info DeviceInfoTruncated, conn net.Conn) (AttachedSession, error)
}

type Export interface {
	BusID() string
	Snapshot(busy bool) ExportSnapshot
	DeviceInfo() (DeviceInfoTruncated, error)
	NewServerDataSession(ctx context.Context, conn net.Conn) (DataSession, error)
}

type ExportSnapshot struct {
	Entry        DeviceEntry
	Backend      BackendID
	StableID     string
	State        DeviceState
	StatusReason string
	RawStatus    int
}

type DataSession interface {
	Done() <-chan struct{}
	Err() error
	Start() error
	Close() error
}

type AttachedSession interface {
	DataSession
	Description() string
}
