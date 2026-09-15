package openvpn

import (
	"net/netip"
	"strings"
	"time"

	E "github.com/sagernet/sing/common/exceptions"
	M "github.com/sagernet/sing/common/metadata"
)

func (c *tlsClient) pullConfigurationAndCipher() (string, string, error) {
	selectedCipher := ""
	selectedAuth := c.parent.options.DataChannel.Auth
	if selectedAuth == "" {
		selectedAuth = "SHA1"
	}
	var accumulatedPushReplyLines []string
	pushContinuationPending := false
	authenticationPending := false
	now := time.Now()
	deadline := now.Add(c.parent.options.Timing.HandWindow)
	writeErr := c.writeControlChannelPayload(tlsControlStringPayload([]byte(pushRequestPayload)), deadline)
	if writeErr != nil {
		return "", "", writeErr
	}
	nextPushRequest := now.Add(tlsPushRequestResendInterval)
	pingRestart := c.prePullPingRestart()
	for time.Now().Before(deadline) {
		readDeadline := deadline
		if nextPushRequest.Before(readDeadline) {
			readDeadline = nextPushRequest
		}
		var lastInboundTime time.Time
		if pingRestart > 0 {
			lastInboundTime, _ = c.keepalive.snapshotActivity()
			pingDeadline := lastInboundTime.Add(pingRestart)
			if pingDeadline.Before(readDeadline) {
				readDeadline = pingDeadline
			}
		}
		controlRecord, readErr := c.readControlChannelRecord(readDeadline)
		if readErr != nil {
			cancelErr := c.canceledChallengeError()
			if cancelErr != nil {
				return "", "", cancelErr
			}
			if !E.IsTimeout(readErr) {
				return "", "", readErr
			}
			now = time.Now()
			if pingRestart > 0 {
				lastInboundTime, _ = c.keepalive.snapshotActivity()
				if shouldExitForPingTimeout(lastInboundTime, now, pingRestart) {
					return "", "", ErrPingRestartTimeout
				}
			}
			if !now.Before(nextPushRequest) {
				writeErr = c.writeControlChannelPayload(tlsControlStringPayload([]byte(pushRequestPayload)), deadline)
				if writeErr != nil {
					return "", "", writeErr
				}
				nextPushRequest = now.Add(tlsPushRequestResendInterval)
			}
			continue
		}
		switch classifyTLSControlDirective(controlRecord) {
		case tlsControlDirectiveAuthFailed:
			return "", "", c.authFailedError(controlRecord)
		case tlsControlDirectiveAuthPending:
			deadline = authPendingDeadline(c.parent.options, controlRecord)
			authenticationPending = true
			c.parent.updateChallengeDeadline(c, deadline)
			continue
		case tlsControlDirectiveRestart:
			return "", "", newServerRestartError(controlRecord)
		case tlsControlDirectiveHalt:
			return "", "", ErrServerHalt
		case tlsControlDirectiveExit:
			return "", "", ErrServerExit
		case tlsControlDirectiveInfoPre:
			c.handleServerPushedInfo(controlRecord, deadline)
			continue
		case tlsControlDirectiveInfo, tlsControlDirectiveCRResponse:
			continue
		case tlsControlDirectivePushReply:
			accumulatedLines, continuation, decoded := appendPushReplyPayloadSegment(accumulatedPushReplyLines, controlRecord)
			var decodedPushedOptions pushedOptions
			if decoded {
				accumulatedPushReplyLines = accumulatedLines
				pushContinuationPending = continuation == 2
				if pushContinuationPending {
					continue
				}
				decodedPushedOptions, _ = decodePushReplyOptionLines(
					accumulatedPushReplyLines[0],
					accumulatedPushReplyLines[1:],
					c.remoteTransportAddress(),
					c.parent.options.Pull.Filters,
				)
				accumulatedPushReplyLines = nil
			} else {
				decodedPushedOptions, continuation, decoded = decodePushReplyPayloadWithFilters(controlRecord, c.remoteTransportAddress(), c.parent.options.Pull.Filters)
				pushContinuationPending = continuation == 2
			}
			if !decoded || pushContinuationPending {
				continue
			}
			applyErr := c.applyDecodedPushedOptions(decodedPushedOptions)
			if applyErr != nil {
				return "", "", applyErr
			}
			if decodedPushedOptions.SelectedCipher != "" {
				selectedCipher = decodedPushedOptions.SelectedCipher
			}
			if decodedPushedOptions.SelectedAuth != "" {
				selectedAuth = decodedPushedOptions.SelectedAuth
			}
			if continuation != 2 {
				if selectedCipher == "" {
					resolvedCipher, resolveErr := selectPulledCipher(c.parent.options, c.remoteCipherName)
					if resolveErr != nil {
						return "", "", resolveErr
					}
					selectedCipher = resolvedCipher
				}
				return selectedCipher, selectedAuth, nil
			}
		}
	}
	if authenticationPending {
		return "", "", ErrAuthPendingTimeout
	}
	if pushContinuationPending {
		return "", "", E.Extend(ErrNoPushReply, "incomplete push continuation")
	}
	return "", "", ErrNoPushReply
}

func (c *tlsClient) controlMessageLoop() {
	for {
		select {
		case <-c.sessionContext.Done():
			c.finish(nil)
			return
		default:
		}
		controlRecord, err := c.readControlChannelRecord(time.Now().Add(time.Second))
		if err != nil {
			if E.IsTimeout(err) {
				continue
			}
			c.finish(err)
			return
		}
		dispatchErr := c.dispatchControlDirective(controlRecord)
		if dispatchErr != nil {
			c.finish(dispatchErr)
			return
		}
	}
}

func (c *tlsClient) remoteTransportAddress() netip.Addr {
	if c.packetConnection != nil {
		remoteAddress := M.SocksaddrFromNet(c.packetConnection.RemoteAddr()).Addr.Unmap()
		if remoteAddress.IsValid() {
			return remoteAddress
		}
	}
	return M.ParseSocksaddr(c.remote.address).Addr.Unmap()
}

// Upstream process_explicit_exit_notification_init (sig.c) sends EXIT over
// the control channel when cc-exit is negotiated.
func (c *tlsClient) sendExplicitExitNotifyIfRequested() {
	if c.parent == nil {
		return
	}
	if !strings.HasPrefix(c.remote.remote.Protocol, "udp") {
		return
	}
	tunnelConfiguration := c.parent.TunnelConfiguration()
	notifyCount := int(tunnelConfiguration.ExplicitExitNotify)
	if notifyCount <= 0 {
		return
	}
	if c.controlChannel == nil {
		return
	}
	if shouldSendCCExitOverControlChannel(tunnelConfiguration) {
		primaryChannel := c.primaryControlChannel()
		if primaryChannel == nil {
			return
		}
		exitDeadline := time.Now().Add(time.Second)
		_ = primaryChannel.SetWriteDeadline(exitDeadline)
		_ = c.writeControlChannelPayload(tlsControlChannelExitPayload, exitDeadline)
		return
	}
	sendCodec, _ := c.currentSendCodec()
	if sendCodec == nil {
		return
	}
	// Upstream process_explicit_exit_notification_timer_wakeup (forward.c)
	// re-stamps occ_op with OCC_EXIT on every one-second tick until the
	// notification window closes, so a notification the link refuses costs that
	// tick alone and the remaining ones are still sent.
	for retry := range notifyCount {
		if retry > 0 {
			time.Sleep(time.Second)
		}
		c.writeDataPacketWithinTick(openVPNDataChannelExitNotifyPayload, time.Second)
	}
}

func tlsPreferredCipher(options ClientOptions) string {
	for _, dataCipher := range tlsAdvertisedDataCiphers(options.DataChannel.Ciphers) {
		if dataCipher != "" {
			return dataCipher
		}
	}
	return "AES-256-GCM"
}
