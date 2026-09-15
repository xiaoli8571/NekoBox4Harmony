package openvpn

import (
	"encoding/binary"
	"time"

	E "github.com/sagernet/sing/common/exceptions"
)

const (
	openVPNFragmentTypeWhole   = 0
	openVPNFragmentTypePartial = 1
	openVPNFragmentTypeLast    = 2

	openVPNFragmentTypeMask       = 0x00000003
	openVPNFragmentTypeShift      = 0
	openVPNFragmentSequenceMask   = 0x000000ff
	openVPNFragmentSequenceShift  = 2
	openVPNFragmentIDMask         = 0x0000001f
	openVPNFragmentIDShift        = 10
	openVPNFragmentSizeMask       = 0x00003fff
	openVPNFragmentSizeShift      = 15
	openVPNFragmentSizeRoundShift = 2
	openVPNFragmentMaxParts       = 32
	openVPNFragmentReceiveWindow  = 25

	openVPNFragmentReassemblyTimeout        = 30 * time.Second
	openVPNFragmentReassemblyMaxBytes       = 4 << 20
	openVPNFragmentReassemblyMaxPacketBytes = 1<<16 - 1
)

type incomingFragmentBuffer struct {
	maxSize int
	lastID  int
	parts   map[int][]byte
	bytes   int
	updated time.Time
}

func (f *dataChannelFraming) encodeFragments(payload []byte, fragmentSize int) ([][]byte, error) {
	fragmentSize &= ^((1 << openVPNFragmentSizeRoundShift) - 1)
	if fragmentSize <= 0 {
		return nil, E.New("fragment packet size is too small for data channel overhead")
	}
	if len(payload) <= fragmentSize {
		return [][]byte{prependFragmentHeader(payload, openVPNFragmentTypeWhole, 0, 0, 0)}, nil
	}

	f.access.Lock()
	sequenceID := f.outgoingSequence
	f.outgoingSequence = (f.outgoingSequence + 1) & openVPNFragmentSequenceMask
	f.access.Unlock()

	var fragments [][]byte
	for offset, fragmentID := 0, 0; offset < len(payload); fragmentID++ {
		if fragmentID >= openVPNFragmentMaxParts {
			return nil, E.New("too many fragments")
		}
		chunkSize := min(fragmentSize, len(payload)-offset)
		fragmentType := openVPNFragmentTypePartial
		maxFragmentSize := 0
		if offset+chunkSize >= len(payload) {
			fragmentType = openVPNFragmentTypeLast
			maxFragmentSize = fragmentSize >> openVPNFragmentSizeRoundShift
		}
		fragments = append(fragments, prependFragmentHeader(payload[offset:offset+chunkSize], fragmentType, sequenceID, fragmentID, maxFragmentSize))
		offset += chunkSize
	}
	return fragments, nil
}

func prependFragmentHeader(payload []byte, fragmentType int, sequenceID int, fragmentID int, maxFragmentSize int) []byte {
	flags := uint32(fragmentType&openVPNFragmentTypeMask) << openVPNFragmentTypeShift
	flags |= uint32(sequenceID&openVPNFragmentSequenceMask) << openVPNFragmentSequenceShift
	flags |= uint32(fragmentID&openVPNFragmentIDMask) << openVPNFragmentIDShift
	if fragmentType == openVPNFragmentTypeLast {
		flags |= uint32(maxFragmentSize&openVPNFragmentSizeMask) << openVPNFragmentSizeShift
	}
	framedPayload := make([]byte, 4+len(payload))
	binary.BigEndian.PutUint32(framedPayload[:4], flags)
	copy(framedPayload[4:], payload)
	return framedPayload
}

func (f *dataChannelFraming) decodeFragment(payload []byte) ([]byte, bool, error) {
	if len(payload) < 4 {
		return nil, false, E.New("fragment header not found")
	}
	flags := binary.BigEndian.Uint32(payload[:4])
	fragmentType := int((flags >> openVPNFragmentTypeShift) & openVPNFragmentTypeMask)
	fragmentPayload := payload[4:]

	switch fragmentType {
	case openVPNFragmentTypeWhole:
		if ((flags>>openVPNFragmentSequenceShift)&openVPNFragmentSequenceMask) != 0 ||
			((flags>>openVPNFragmentIDShift)&openVPNFragmentIDMask) != 0 {
			return nil, false, E.New("spurious fragment header flags")
		}
		return append([]byte{}, fragmentPayload...), true, nil
	case openVPNFragmentTypePartial, openVPNFragmentTypeLast:
		return f.storeIncomingFragment(
			int((flags>>openVPNFragmentSequenceShift)&openVPNFragmentSequenceMask),
			int((flags>>openVPNFragmentIDShift)&openVPNFragmentIDMask),
			int((flags>>openVPNFragmentSizeShift)&openVPNFragmentSizeMask)<<openVPNFragmentSizeRoundShift,
			fragmentType == openVPNFragmentTypeLast,
			fragmentPayload,
		)
	default:
		return nil, false, E.New("unknown fragment type")
	}
}

func (f *dataChannelFraming) storeIncomingFragment(sequenceID int, fragmentID int, maxFragmentSize int, last bool, payload []byte) ([]byte, bool, error) {
	f.access.Lock()
	defer f.access.Unlock()
	now := time.Now()
	f.expireIncomingFragments(now)
	maxPacketBytes := f.reassemblyMaxPacketBytes
	if maxPacketBytes <= 0 {
		maxPacketBytes = openVPNFragmentReassemblyMaxPacketBytes
	}
	maxReassemblyBytes := f.reassemblyMaxBytes
	if maxReassemblyBytes <= 0 {
		maxReassemblyBytes = openVPNFragmentReassemblyMaxBytes
	}
	if len(payload) > maxPacketBytes {
		return nil, false, E.New("fragment exceeds maximum reassembled packet size")
	}
	f.advanceIncomingFragmentWindow(sequenceID)

	fragmentBuffer, exists := f.incomingBySequence[sequenceID]
	fragmentSize := len(payload)
	if maxFragmentSize > 0 {
		fragmentSize = maxFragmentSize
	}
	if exists && fragmentBuffer.maxSize != fragmentSize {
		f.deleteIncomingFragmentBuffer(sequenceID)
		fragmentBuffer = nil
		exists = false
	}
	if !exists {
		fragmentBuffer = &incomingFragmentBuffer{
			maxSize: fragmentSize,
			lastID:  -1,
			parts:   make(map[int][]byte),
			updated: now,
		}
		f.incomingBySequence[sequenceID] = fragmentBuffer
	}
	previousPart := fragmentBuffer.parts[fragmentID]
	additionalBytes := len(payload) - len(previousPart)
	if fragmentBuffer.bytes+additionalBytes > maxPacketBytes {
		f.deleteIncomingFragmentBuffer(sequenceID)
		return nil, false, E.New("fragmented packet exceeds maximum IP packet size")
	}
	for f.incomingBytes+additionalBytes > maxReassemblyBytes {
		oldestSequence, found := f.oldestIncomingFragmentSequence(sequenceID)
		if !found {
			f.deleteIncomingFragmentBuffer(sequenceID)
			return nil, false, E.New("fragment reassembly memory limit exceeded")
		}
		f.deleteIncomingFragmentBuffer(oldestSequence)
	}
	if maxFragmentSize > 0 {
		fragmentBuffer.maxSize = maxFragmentSize
	} else if fragmentBuffer.maxSize == 0 {
		fragmentBuffer.maxSize = len(payload)
	}
	fragmentBuffer.parts[fragmentID] = append([]byte{}, payload...)
	fragmentBuffer.bytes += additionalBytes
	fragmentBuffer.updated = now
	f.incomingBytes += additionalBytes
	if last {
		fragmentBuffer.lastID = fragmentID
	}
	if fragmentBuffer.lastID < 0 {
		return nil, false, nil
	}

	totalLength := 0
	for currentFragmentID := 0; currentFragmentID <= fragmentBuffer.lastID; currentFragmentID++ {
		fragmentPayload, partExists := fragmentBuffer.parts[currentFragmentID]
		if !partExists {
			return nil, false, nil
		}
		totalLength += len(fragmentPayload)
	}

	reassembledPayload := make([]byte, 0, totalLength)
	for currentFragmentID := 0; currentFragmentID <= fragmentBuffer.lastID; currentFragmentID++ {
		reassembledPayload = append(reassembledPayload, fragmentBuffer.parts[currentFragmentID]...)
	}
	f.deleteIncomingFragmentBuffer(sequenceID)
	return reassembledPayload, true, nil
}

func (f *dataChannelFraming) advanceIncomingFragmentWindow(sequenceID int) {
	if !f.incomingSequenceSet {
		f.incomingSequence = sequenceID
		f.incomingSequenceSet = true
		return
	}
	difference := fragmentSequenceDifference(sequenceID, f.incomingSequence)
	if difference >= openVPNFragmentReceiveWindow || difference <= -openVPNFragmentReceiveWindow {
		f.clearIncomingFragments()
		f.incomingSequence = sequenceID
		return
	}
	if difference <= 0 {
		return
	}
	f.incomingSequence = sequenceID
	for bufferedSequence := range f.incomingBySequence {
		bufferedDifference := fragmentSequenceDifference(bufferedSequence, f.incomingSequence)
		if bufferedDifference <= -openVPNFragmentReceiveWindow || bufferedDifference > 0 {
			f.deleteIncomingFragmentBuffer(bufferedSequence)
		}
	}
}

func fragmentSequenceDifference(sequenceID int, referenceSequence int) int {
	directDifference := sequenceID - referenceSequence
	if directDifference == 0 {
		return 0
	}
	wrappedDifference := directDifference
	if sequenceID > referenceSequence {
		wrappedDifference -= openVPNFragmentSequenceMask + 1
	} else {
		wrappedDifference += openVPNFragmentSequenceMask + 1
	}
	if directDifference < 0 {
		if -directDifference <= wrappedDifference {
			return directDifference
		}
		return wrappedDifference
	}
	if directDifference <= -wrappedDifference {
		return directDifference
	}
	return wrappedDifference
}

func (f *dataChannelFraming) clearIncomingFragments() {
	for sequenceID := range f.incomingBySequence {
		f.deleteIncomingFragmentBuffer(sequenceID)
	}
}

func (f *dataChannelFraming) expireIncomingFragments(now time.Time) {
	timeout := f.reassemblyTimeout
	if timeout <= 0 {
		timeout = openVPNFragmentReassemblyTimeout
	}
	for sequenceID, fragmentBuffer := range f.incomingBySequence {
		if fragmentBuffer.updated.IsZero() || now.Sub(fragmentBuffer.updated) >= timeout {
			f.deleteIncomingFragmentBuffer(sequenceID)
		}
	}
}

func (f *dataChannelFraming) oldestIncomingFragmentSequence(excludeSequence int) (int, bool) {
	oldestSequence := 0
	var oldestTime time.Time
	found := false
	for sequenceID, fragmentBuffer := range f.incomingBySequence {
		if sequenceID == excludeSequence {
			continue
		}
		if !found || fragmentBuffer.updated.Before(oldestTime) {
			oldestSequence = sequenceID
			oldestTime = fragmentBuffer.updated
			found = true
		}
	}
	return oldestSequence, found
}

func (f *dataChannelFraming) deleteIncomingFragmentBuffer(sequenceID int) {
	fragmentBuffer, found := f.incomingBySequence[sequenceID]
	if !found {
		return
	}
	delete(f.incomingBySequence, sequenceID)
	f.incomingBytes -= fragmentBuffer.bytes
	f.incomingBytes = max(f.incomingBytes, 0)
}
