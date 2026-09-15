package openconnect

import (
	"context"
	"net"
	"syscall"
	"time"

	E "github.com/sagernet/sing/common/exceptions"
)

const (
	anyConnectDTLSMTUProbeInterval = 50 * time.Millisecond
	anyConnectDTLSMTUProbeTimeout  = 10 * time.Second
	anyConnectDTLSMTUProbeRetries  = 6
)

// Upstream probe_mtu sends padded DTLS DPD requests and binary-searches for the largest echoed payload between the IP minimum and the negotiated tunnel MTU.
func detectAnyConnectDTLSMTU(ctx context.Context, conn net.Conn, minimum int, maximum int) (detected int, err error) {
	if minimum <= 0 || maximum <= minimum {
		return 0, nil
	}
	defer func() {
		deadlineErr := conn.SetDeadline(time.Time{})
		if deadlineErr != nil && err == nil {
			err = E.Cause(deadlineErr, "clear AnyConnect DTLS MTU probe deadline")
		}
	}()
	payload := make([]byte, maximum+1)
	for i := range payload {
		payload[i] = 0x5a
	}
	payload[0] = cstpPacketDPDRequest
	response := make([]byte, maximum+1)
	probeDeadline := time.Now().Add(anyConnectDTLSMTUProbeTimeout)
	lower := minimum
	upper := maximum
	candidate := maximum
	for lower < upper && time.Now().Before(probeDeadline) {
		if ctx.Err() != nil {
			return 0, ctx.Err()
		}
		successful, probeErr := probeAnyConnectDTLSMTUCandidate(
			ctx,
			conn,
			payload[:candidate+1],
			response,
			probeDeadline,
		)
		if probeErr != nil {
			return 0, probeErr
		}
		if successful {
			lower = candidate
		} else {
			upper = candidate - 1
		}
		if lower >= upper {
			break
		}
		candidate = (lower + upper + 1) / 2
	}
	return lower, nil
}

func probeAnyConnectDTLSMTUCandidate(
	ctx context.Context,
	conn net.Conn,
	payload []byte,
	response []byte,
	probeDeadline time.Time,
) (bool, error) {
	for range anyConnectDTLSMTUProbeRetries {
		if ctx.Err() != nil {
			return false, ctx.Err()
		}
		attemptDeadline := time.Now().Add(anyConnectDTLSMTUProbeInterval)
		if attemptDeadline.After(probeDeadline) {
			attemptDeadline = probeDeadline
		}
		err := conn.SetWriteDeadline(attemptDeadline)
		if err != nil {
			return false, E.Cause(err, "set AnyConnect DTLS MTU probe write deadline")
		}
		n, err := conn.Write(payload)
		if err != nil {
			if E.IsMulti(err, syscall.EMSGSIZE) {
				return false, nil
			}
			if ctx.Err() != nil {
				return false, ctx.Err()
			}
			return false, E.Cause(err, "write AnyConnect DTLS MTU probe")
		}
		if n != len(payload) {
			return false, E.New("short AnyConnect DTLS MTU probe write: wrote ", n, " of ", len(payload), " bytes")
		}
		for time.Now().Before(attemptDeadline) {
			err = conn.SetReadDeadline(attemptDeadline)
			if err != nil {
				return false, E.Cause(err, "set AnyConnect DTLS MTU probe read deadline")
			}
			n, err = conn.Read(response)
			if err != nil {
				if E.IsTimeout(err) {
					break
				}
				if ctx.Err() != nil {
					return false, ctx.Err()
				}
				return false, E.Cause(err, "read AnyConnect DTLS MTU probe response")
			}
			if n == len(payload) && response[0] == cstpPacketDPDResponse {
				return true, nil
			}
			if n > 0 && response[0] == cstpPacketDPDRequest {
				n, err = conn.Write([]byte{cstpPacketDPDResponse})
				if err != nil {
					return false, E.Cause(err, "answer AnyConnect DTLS DPD during MTU probing")
				}
				if n != 1 {
					return false, E.New("short AnyConnect DTLS DPD response during MTU probing: wrote ", n, " of 1 byte")
				}
			}
		}
	}
	return false, nil
}
