//go:build linux || freebsd

package quic

import "syscall"

func newBatchReader(syscall.RawConn, bool) batchConn { return nil }

func newSegmentWriter(syscall.RawConn) segmentWriter { return nil }
