package openvpn

import (
	"sync"
	"time"
)

type tlsClientKeepalive struct {
	session *tlsClient
	parent  *Client

	access sync.Mutex

	lastInboundTime            time.Time
	lastOutboundTime           time.Time
	inactivityBytesAccumulator uint64
	lastInactivityResetTime    time.Time

	pingInterval time.Duration
	pingRestart  time.Duration

	sessionStartTime        time.Time
	renegotiationBudget     dataRenegotiationBudget
	renegotiationInterval   time.Duration
	renegotiationDeadline   time.Time
	renegotiationInProgress bool
}

func (k *tlsClientKeepalive) configureRenegotiation(selectedCipher string, activeKeyID uint8) {
	k.access.Lock()
	defer k.access.Unlock()
	k.renegotiationBudget = newDataRenegotiationBudget(
		selectedCipher,
		k.parent.options.Timing.RenegotiationBytes,
		k.parent.options.Timing.RenegotiationPackets,
		activeKeyID,
	)
	k.renegotiationInterval = k.parent.options.Timing.RenegotiationInterval
	if k.renegotiationInterval > 0 {
		k.renegotiationDeadline = time.Now().Add(k.renegotiationInterval)
	}
}

func (k *tlsClientKeepalive) noteRenegotiated(activeKeyID uint8) {
	k.access.Lock()
	defer k.access.Unlock()
	k.renegotiationBudget.reset(activeKeyID)
	if k.renegotiationInterval > 0 {
		k.renegotiationDeadline = time.Now().Add(k.renegotiationInterval)
	}
}

// Upstream should_trigger_renegotiation/key_state_soft_reset (ssl.c)
// keeps the old key active while a fresh key is negotiated.
func (k *tlsClientKeepalive) consumeOutboundRenegotiationBudget(
	keyID uint8,
	packetID uint32,
	aeadBlockBytes int,
	accountedBytes int,
) {
	k.access.Lock()
	transferErr := k.renegotiationBudget.consumeTransfer(keyID, accountedBytes)
	usageErr := k.renegotiationBudget.consumeUsage(
		keyID,
		dataRenegotiationDirectionSend,
		packetID,
		aeadBlockBytes,
	)
	k.access.Unlock()
	if transferErr != nil || usageErr != nil {
		k.requestSoftReset()
	}
}

func (k *tlsClientKeepalive) consumeInboundRenegotiationCounter(keyID uint8, accountedBytes int) {
	k.access.Lock()
	budgetErr := k.renegotiationBudget.consumeTransfer(keyID, accountedBytes)
	k.access.Unlock()
	if budgetErr != nil {
		k.requestSoftReset()
	}
}

func (k *tlsClientKeepalive) consumeInboundRenegotiationUsage(
	keyID uint8,
	packetID uint32,
	aeadBlockBytes int,
) {
	k.access.Lock()
	budgetErr := k.renegotiationBudget.consumeUsage(
		keyID,
		dataRenegotiationDirectionReceive,
		packetID,
		aeadBlockBytes,
	)
	k.access.Unlock()
	if budgetErr != nil {
		k.requestSoftReset()
	}
}

func (k *tlsClientKeepalive) noteSessionStart() {
	k.access.Lock()
	defer k.access.Unlock()
	k.sessionStartTime = time.Now()
}

func (k *tlsClientKeepalive) markActivity(inbound bool, outbound bool) {
	k.access.Lock()
	defer k.access.Unlock()
	now := time.Now()
	if inbound {
		k.lastInboundTime = now
	}
	if outbound {
		k.lastOutboundTime = now
	}
}

func (k *tlsClientKeepalive) snapshotActivity() (time.Time, time.Time) {
	k.access.Lock()
	defer k.access.Unlock()
	return k.lastInboundTime, k.lastOutboundTime
}

// Upstream event_timeout_init/init_instance (forward.c/init.c) seeds
// the inactivity timer before the first data packet.
func (k *tlsClientKeepalive) resetInactivityTimer() {
	k.access.Lock()
	defer k.access.Unlock()
	k.inactivityBytesAccumulator = 0
	k.lastInactivityResetTime = time.Now()
}

// Upstream register_activity (forward.h) excludes ping packets from the
// inactive byte accumulator.
func (k *tlsClientKeepalive) registerInactivityBytes(byteCount int) {
	if byteCount <= 0 {
		return
	}
	tunnelConfiguration := k.parent.TunnelConfiguration()
	threshold := tunnelConfiguration.InactiveMinimumBytes
	k.access.Lock()
	defer k.access.Unlock()
	newAccumulator, shouldReset := shouldResetInactivityTimer(k.inactivityBytesAccumulator, uint64(byteCount), threshold)
	k.inactivityBytesAccumulator = newAccumulator
	if shouldReset {
		k.lastInactivityResetTime = time.Now()
	}
}

// Upstream register_activity (forward.h) treats a zero byte threshold as
// reset-on-any-activity.
func shouldResetInactivityTimer(accumulator uint64, byteCount uint64, threshold uint64) (uint64, bool) {
	newAccumulator := accumulator + byteCount
	if newAccumulator >= threshold {
		return 0, true
	}
	return newAccumulator, false
}

func (k *tlsClientKeepalive) snapshotInactivityReset() time.Time {
	k.access.Lock()
	defer k.access.Unlock()
	return k.lastInactivityResetTime
}

func (k *tlsClientKeepalive) refreshFromTunnelConfiguration() {
	tunnelConfiguration := k.parent.TunnelConfiguration()
	k.setDurations(
		tunnelConfiguration.PingInterval,
		tunnelConfiguration.PingRestart,
	)
}

func (k *tlsClientKeepalive) setDurations(pingInterval time.Duration, pingRestart time.Duration) {
	k.access.Lock()
	defer k.access.Unlock()
	k.pingInterval = pingInterval
	k.pingRestart = pingRestart
}

func (k *tlsClientKeepalive) currentDurations() (time.Duration, time.Duration) {
	k.access.Lock()
	defer k.access.Unlock()
	return k.pingInterval, k.pingRestart
}

func (k *tlsClientKeepalive) snapshotRenegotiationDeadline() time.Time {
	k.access.Lock()
	defer k.access.Unlock()
	return k.renegotiationDeadline
}

func (k *tlsClientKeepalive) runLoop() {
	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-k.session.sessionContext.Done():
			return
		case <-ticker.C:
		}
		k.refreshFromTunnelConfiguration()
		pingInterval, _ := k.currentDurations()
		tunnelConfiguration := k.parent.TunnelConfiguration()
		sessionTimeout := tunnelConfiguration.SessionTimeout
		inactiveTimeout := tunnelConfiguration.InactiveTimeout
		lastInbound, lastOutbound := k.snapshotActivity()
		lastInactivityReset := k.snapshotInactivityReset()
		renegotiationDeadline := k.snapshotRenegotiationDeadline()
		now := time.Now()
		// Upstream check_session_timeout (forward.c).
		if sessionTimeout > 0 && !k.sessionStartTime.IsZero() && now.Sub(k.sessionStartTime) >= sessionTimeout {
			k.session.finish(ErrSessionTimeout)
			return
		}
		// Upstream should_trigger_renegotiation/key_state_soft_reset (ssl.c).
		if !renegotiationDeadline.IsZero() && !now.Before(renegotiationDeadline) {
			k.requestSoftReset()
		}
		if shouldExitForInactivityTimeout(lastInactivityReset, now, inactiveTimeout) {
			k.session.finish(ErrInactiveTimeout)
			return
		}
		pingReceiveTimeout, pingTimeoutAction := effectiveClientPingTimeout(tunnelConfiguration)
		if shouldExitForPingTimeout(lastInbound, now, pingReceiveTimeout) {
			if pingTimeoutAction == clientPingTimeoutExit {
				k.session.finish(ErrPingExitTimeout)
			} else {
				k.session.finish(ErrPingRestartTimeout)
			}
			return
		}
		if pingInterval > 0 && (lastOutbound.IsZero() || now.Sub(lastOutbound) >= pingInterval) {
			messages := k.session.dataChannelMessages()
			if messages != nil {
				messages.sendPing()
			}
		}
	}
}

// Upstream key_state_soft_reset (ssl.c) negotiates a new key_id while
// the current key remains active.
func (k *tlsClientKeepalive) requestSoftReset() {
	k.access.Lock()
	if k.renegotiationInProgress {
		k.access.Unlock()
		return
	}
	k.renegotiationInProgress = true
	k.access.Unlock()
	go func() {
		_ = k.session.triggerSoftReset()
		k.access.Lock()
		k.renegotiationInProgress = false
		k.access.Unlock()
	}()
}
