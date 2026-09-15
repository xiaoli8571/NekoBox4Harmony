//go:build aix || android || darwin || dragonfly || freebsd || illumos || ios || linux || netbsd || openbsd || solaris

package openconnect

import (
	"bufio"
	"context"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"io"
	"net"
	"net/http"
	"net/netip"
	"net/url"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"sync"
	"time"

	E "github.com/sagernet/sing/common/exceptions"

	"golang.org/x/sys/unix"
)

const (
	ncTNCCWrapperMaximumLine      = 1024
	ncTNCCWrapperOperationTimeout = 30 * time.Second
	ncTNCCWrapperExitTimeout      = 2 * time.Second
)

type ncExternalTNCCRunner struct {
	access          sync.Mutex
	wrapperPath     string
	gatewayHostname string
	localHostname   string
	certificateHash string
	conn            net.Conn
	reader          *bufio.Reader
	command         *exec.Cmd
	waitDone        chan struct{}
	processErr      error
	interval        time.Duration
	started         bool
	closed          bool
}

func newNCExternalTNCCRunner(
	frontend *ncFrontend,
	serverURL *url.URL,
	_ netip.Addr,
	_ http.CookieJar,
	peerCertificate *x509.Certificate,
) (ncTNCCRunner, error) {
	if serverURL == nil {
		return nil, markTerminal(E.New("external Network Connect TNCC wrapper requires a gateway URL"))
	}
	certificateHash, err := ncPeerCertificateSHA256(peerCertificate)
	if err != nil {
		return nil, markTerminal(err)
	}
	return &ncExternalTNCCRunner{
		wrapperPath:     frontend.client.options.TNCC.WrapperPath,
		gatewayHostname: serverURL.Hostname(),
		localHostname:   frontend.localHostname,
		certificateHash: certificateHash,
	}, nil
}

func ncPeerCertificateSHA256(certificate *x509.Certificate) (string, error) {
	if certificate == nil || len(certificate.RawSubjectPublicKeyInfo) == 0 {
		return "", E.New("TNCC wrapper requires the accepted TLS peer certificate")
	}
	digest := sha256.Sum256(certificate.RawSubjectPublicKeyInfo)
	return base64.StdEncoding.EncodeToString(digest[:]), nil
}

// /tmp/openconnect/auth-juniper.c:tncc_preauth gives the wrapper one full-duplex Unix socket as descriptor zero and exchanges start/setcookie line commands on that descriptor.
func (r *ncExternalTNCCRunner) Start(
	ctx context.Context,
	preauthenticationCookie string,
	signInURL string,
) (string, error) {
	r.access.Lock()
	defer r.access.Unlock()
	if r.closed {
		return "", ErrClientClosed
	}
	if r.started {
		return "", E.New("external Network Connect TNCC wrapper already started")
	}
	err := r.startProcessLocked()
	if err != nil {
		return "", err
	}
	r.started = true
	command := "start\nIC=" + r.gatewayHostname + "\nCookie=" + preauthenticationCookie + "\nDSSIGNIN=" + signInURL + "\n"
	err = r.writeCommandLocked(ctx, command)
	if err != nil {
		return "", err
	}
	status, err := r.readLineLocked(ctx)
	if err != nil {
		return "", err
	}
	if status != "200" {
		return "", markTerminal(E.New("external Network Connect TNCC wrapper returned status ", status))
	}
	_, err = r.readLineLocked(ctx)
	if err != nil {
		return "", err
	}
	preauthenticationCookie, err = r.readLineLocked(ctx)
	if err != nil {
		return "", err
	}
	if preauthenticationCookie == "" {
		return "", markTerminal(E.New("external Network Connect TNCC wrapper returned an empty DSPREAUTH cookie"))
	}
	intervalLine, err := r.readLineLocked(ctx)
	if err != nil {
		return "", err
	}
	if intervalLine != "" {
		interval, parseErr := parseNCTNCCWrapperInterval(intervalLine)
		if parseErr != nil {
			return "", parseErr
		}
		r.interval = interval
	}
	for lineNumber := 0; ; lineNumber++ {
		line, readErr := r.readLineLocked(ctx)
		if readErr != nil {
			return "", readErr
		}
		if line == "" {
			break
		}
		if lineNumber >= 10 {
			return "", markTerminal(E.New("external Network Connect TNCC wrapper returned too many response lines"))
		}
	}
	return preauthenticationCookie, nil
}

func (r *ncExternalTNCCRunner) SetCookie(ctx context.Context, preauthenticationCookie string) error {
	r.access.Lock()
	defer r.access.Unlock()
	if r.closed {
		return ErrClientClosed
	}
	if !r.started || r.conn == nil {
		return E.New("external Network Connect TNCC wrapper is not started")
	}
	return r.writeCommandLocked(ctx, "setcookie\nCookie="+preauthenticationCookie+"\n")
}

func (r *ncExternalTNCCRunner) Interval() time.Duration {
	r.access.Lock()
	defer r.access.Unlock()
	return r.interval
}

func (r *ncExternalTNCCRunner) Close() error {
	r.access.Lock()
	if r.closed {
		r.access.Unlock()
		return nil
	}
	r.closed = true
	conn := r.conn
	r.conn = nil
	command := r.command
	waitDone := r.waitDone
	r.access.Unlock()
	var closeErr error
	if conn != nil {
		err := conn.Close()
		if err != nil && !E.IsClosed(err) {
			closeErr = E.Cause(err, "close external Network Connect TNCC wrapper socket")
		}
	}
	if command == nil || waitDone == nil {
		return closeErr
	}
	timer := time.NewTimer(ncTNCCWrapperExitTimeout)
	select {
	case <-waitDone:
		timer.Stop()
	case <-timer.C:
		if command.Process != nil {
			err := command.Process.Kill()
			if err != nil && !E.IsClosed(err) {
				closeErr = E.Append(closeErr, err, func(cause error) error {
					return E.Cause(cause, "kill external Network Connect TNCC wrapper")
				})
			}
		}
		<-waitDone
	}
	return closeErr
}

func (r *ncExternalTNCCRunner) startProcessLocked() error {
	descriptors, err := unix.Socketpair(unix.AF_UNIX, unix.SOCK_STREAM, 0)
	if err != nil {
		return markTerminal(E.Cause(err, "create external Network Connect TNCC wrapper socket"))
	}
	unix.CloseOnExec(descriptors[0])
	unix.CloseOnExec(descriptors[1])
	parentFile := os.NewFile(uintptr(descriptors[0]), "tncc-parent")
	childFile := os.NewFile(uintptr(descriptors[1]), "tncc-child")
	conn, err := net.FileConn(parentFile)
	parentCloseErr := parentFile.Close()
	if err != nil {
		_ = childFile.Close()
		return markTerminal(E.Errors(E.Cause(err, "open external Network Connect TNCC wrapper socket"), parentCloseErr))
	}
	if parentCloseErr != nil {
		_ = conn.Close()
		_ = childFile.Close()
		return markTerminal(E.Cause(parentCloseErr, "close duplicated external Network Connect TNCC wrapper descriptor"))
	}
	command := exec.Command(r.wrapperPath, r.gatewayHostname)
	command.Stdin = childFile
	command.Stdout = io.Discard
	command.Stderr = io.Discard
	command.Env = ncTNCCWrapperEnvironment(command.Environ(), r.certificateHash, r.localHostname)
	err = command.Start()
	childCloseErr := childFile.Close()
	if err != nil {
		_ = conn.Close()
		return markTerminal(E.Errors(E.Cause(err, "start external Network Connect TNCC wrapper"), childCloseErr))
	}
	if childCloseErr != nil {
		_ = conn.Close()
		_ = command.Process.Kill()
		_ = command.Wait()
		return markTerminal(E.Cause(childCloseErr, "close parent copy of external Network Connect TNCC wrapper socket"))
	}
	r.conn = conn
	r.reader = bufio.NewReaderSize(conn, ncTNCCWrapperMaximumLine)
	r.command = command
	r.waitDone = make(chan struct{})
	waitDone := r.waitDone
	go func() {
		processErr := command.Wait()
		_ = conn.Close()
		r.processErr = processErr
		close(waitDone)
	}()
	return nil
}

func (r *ncExternalTNCCRunner) writeCommandLocked(ctx context.Context, command string) error {
	err := r.processStatusLocked()
	if err != nil {
		return err
	}
	stopDeadline := r.applyContextDeadlineLocked(ctx)
	defer stopDeadline()
	content := []byte(command)
	for len(content) > 0 {
		n, writeErr := r.conn.Write(content)
		if writeErr != nil {
			if ctx.Err() != nil {
				return ctx.Err()
			}
			return E.Cause(writeErr, "write external Network Connect TNCC wrapper command")
		}
		if n == 0 {
			return E.New("external Network Connect TNCC wrapper command write made no progress")
		}
		content = content[n:]
	}
	return nil
}

func (r *ncExternalTNCCRunner) readLineLocked(ctx context.Context) (string, error) {
	err := r.processStatusLocked()
	if err != nil {
		return "", err
	}
	stopDeadline := r.applyContextDeadlineLocked(ctx)
	defer stopDeadline()
	lineContent, readErr := r.reader.ReadSlice('\n')
	if readErr == bufio.ErrBufferFull || len(lineContent) > ncTNCCWrapperMaximumLine {
		return "", markTerminal(E.New("external Network Connect TNCC wrapper response line exceeds ", ncTNCCWrapperMaximumLine, " bytes"))
	}
	if readErr != nil {
		if ctx.Err() != nil {
			return "", ctx.Err()
		}
		statusErr := r.processStatusLocked()
		if statusErr != nil {
			return "", statusErr
		}
		return "", E.Cause(readErr, "read external Network Connect TNCC wrapper response")
	}
	line := string(lineContent)
	return strings.TrimSuffix(strings.TrimSuffix(line, "\n"), "\r"), nil
}

func (r *ncExternalTNCCRunner) applyContextDeadlineLocked(ctx context.Context) func() {
	deadline := time.Now().Add(ncTNCCWrapperOperationTimeout)
	contextDeadline, hasDeadline := ctx.Deadline()
	if hasDeadline && contextDeadline.Before(deadline) {
		deadline = contextDeadline
	}
	_ = r.conn.SetDeadline(deadline)
	stop := context.AfterFunc(ctx, func() {
		_ = r.conn.SetDeadline(time.Now())
	})
	return func() {
		if stop() {
			_ = r.conn.SetDeadline(time.Time{})
		}
	}
}

func (r *ncExternalTNCCRunner) processStatusLocked() error {
	if r.waitDone == nil {
		return nil
	}
	select {
	case <-r.waitDone:
		if r.processErr == nil {
			return markTerminal(E.New("external Network Connect TNCC wrapper exited unexpectedly"))
		}
		return markTerminal(E.Cause(r.processErr, "external Network Connect TNCC wrapper terminated"))
	default:
		return nil
	}
}

func parseNCTNCCWrapperInterval(value string) (time.Duration, error) {
	seconds, err := strconv.ParseUint(strings.TrimSpace(value), 10, 31)
	if err != nil {
		return 0, markTerminal(E.Cause(err, "parse external Network Connect TNCC wrapper interval"))
	}
	return time.Duration(seconds) * time.Second, nil
}

func ncTNCCWrapperEnvironment(environment []string, certificateHash string, localHostname string) []string {
	filtered := make([]string, 0, len(environment)+3)
	for _, entry := range environment {
		name, _, _ := strings.Cut(entry, "=")
		if name == "TNCC_SHA256" || name == "TNCC_HOSTNAME" || name == "TNCC_INTERVAL" {
			continue
		}
		filtered = append(filtered, entry)
	}
	return append(filtered,
		"TNCC_SHA256="+certificateHash,
		"TNCC_HOSTNAME="+localHostname,
		"TNCC_INTERVAL=0",
	)
}
