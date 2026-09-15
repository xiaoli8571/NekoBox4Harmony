//go:build windows

package usbip

import (
	"sync"

	"github.com/sagernet/sing-usbip/internal/vboxusb"
	E "github.com/sagernet/sing/common/exceptions"
)

type vboxusbEngine struct {
	device *vboxusb.Device
}

func newVBoxUSBEngine(device *vboxusb.Device) *vboxusbEngine {
	return &vboxusbEngine{device: device}
}

func (e *vboxusbEngine) Submit(req URBRequest) URBResponse {
	command := req.Command
	// VBoxUSB rebuilds its pipe-handle table on SET_CONFIGURATION and
	// SET_INTERFACE and resets the host-side pipe state on
	// CLEAR_FEATURE(ENDPOINT_HALT); racing a SEND_URB against them produces
	// wrong-pipe errors, so they must go through dedicated IOCTLs.
	if command.Header.Endpoint == 0 {
		response, trapped := e.trapStandardControl(command)
		if trapped {
			return response
		}
		return e.controlSubmit(req)
	}
	if command.NumberOfPackets > 0 {
		return e.isoSubmit(req)
	}
	transferType := vboxusb.TransferTypeBulk
	if command.Interval > 0 {
		transferType = vboxusb.TransferTypeInterrupt
	}
	return e.bulkSubmit(req, transferType)
}

func (e *vboxusbEngine) AbortEndpoint(endpoint uint8) error {
	return e.device.AbortEndpoint(endpoint)
}

func (e *vboxusbEngine) Close() error {
	return e.device.Close()
}

func (e *vboxusbEngine) trapStandardControl(command SubmitCommand) (URBResponse, bool) {
	bmRequestType := command.Setup[0]
	bRequest := command.Setup[1]
	wValue := uint16(command.Setup[2]) | uint16(command.Setup[3])<<8
	wIndex := uint16(command.Setup[4]) | uint16(command.Setup[5])<<8

	switch {
	case bmRequestType == 0x00 && bRequest == 0x09:
		err := e.device.SetConfig(byte(wValue))
		return controlAckResponse(err), true
	case bmRequestType == 0x01 && bRequest == 0x0b:
		err := e.device.SelectInterface(byte(wIndex), byte(wValue))
		return controlAckResponse(err), true
	case bmRequestType == 0x02 && bRequest == 0x01 && wValue == 0x00:
		err := e.device.ClearEndpoint(byte(wIndex))
		return controlAckResponse(err), true
	}
	return URBResponse{}, false
}

func controlAckResponse(err error) URBResponse {
	if err != nil {
		return URBResponse{Error: err}
	}
	return URBResponse{Status: 0, ActualLength: 0}
}

// USBSUP_TRANSFER_TYPE_MSG carries the 8-byte setup packet prepended to
// the buffer, and urb.Length includes those 8 bytes.
func (e *vboxusbEngine) controlSubmit(req URBRequest) URBResponse {
	command := req.Command
	data := req.Buffer
	combined := make([]byte, 8+len(data))
	copy(combined[:8], command.Setup[:])
	if command.Header.Direction == USBIPDirOut && len(data) > 0 {
		copy(combined[8:], data)
	}
	urb := &vboxusb.URB{
		Type:      vboxusb.TransferTypeMessage,
		Endpoint:  0,
		Direction: vboxusb.DirectionSetup,
		Length:    uint64(len(combined)),
		Buffer:    combined,
	}
	err := e.device.SendURB(urb)
	status, ok := classifyURBError(err)
	if !ok {
		return URBResponse{Error: err}
	}
	actual := int64(urb.Length) - 8
	if actual < 0 {
		actual = 0
	}
	resp := URBResponse{Status: status, ActualLength: int32(actual)}
	if command.Header.Direction == USBIPDirIn && actual > 0 {
		end := 8 + int(actual)
		if end > len(combined) {
			end = len(combined)
		}
		resp.Buffer = combined[8:end]
	}
	return resp
}

func (e *vboxusbEngine) bulkSubmit(req URBRequest, transferType vboxusb.TransferType) URBResponse {
	command := req.Command
	urb := &vboxusb.URB{
		Type:      transferType,
		Endpoint:  uint32(req.Endpoint & 0x0f),
		Direction: directionFromCommand(command.Header.Direction),
		Flags:     flagsFromCommand(command.TransferFlags, command.Header.Direction),
		Length:    uint64(len(req.Buffer)),
		Buffer:    req.Buffer,
	}
	err := e.device.SendURB(urb)
	status, ok := classifyURBError(err)
	if !ok {
		return URBResponse{Error: err}
	}
	resp := URBResponse{Status: status, ActualLength: int32(urb.Length)}
	if command.Header.Direction == USBIPDirIn && urb.Length > 0 {
		end := int(urb.Length)
		if end > len(req.Buffer) {
			end = len(req.Buffer)
		}
		resp.Buffer = req.Buffer[:end]
	}
	return resp
}

func (e *vboxusbEngine) isoSubmit(req URBRequest) URBResponse {
	command := req.Command
	if len(command.IsoPackets) > vboxusb.MaxIsoPacketsPerURB {
		return e.isoSubmitSplit(req)
	}
	pkts := make([]vboxusb.IsoPacket, len(command.IsoPackets))
	for i, p := range command.IsoPackets {
		pkts[i] = vboxusb.IsoPacket{
			Length: uint16(p.Length),
			Offset: uint16(p.Offset),
		}
	}
	urb := &vboxusb.URB{
		Type:       vboxusb.TransferTypeIso,
		Endpoint:   uint32(req.Endpoint & 0x0f),
		Direction:  directionFromCommand(command.Header.Direction),
		Flags:      flagsFromCommand(command.TransferFlags, command.Header.Direction),
		Length:     uint64(len(req.Buffer)),
		Buffer:     req.Buffer,
		IsoPackets: pkts,
	}
	err := e.device.SendURB(urb)
	status, ok := classifyURBError(err)
	if !ok {
		return URBResponse{Error: err}
	}
	for i := range req.IsoPackets {
		if i >= len(urb.IsoPackets) {
			break
		}
		req.IsoPackets[i].ActualLength = int32(urb.IsoPackets[i].Length)
		req.IsoPackets[i].Status = vboxusbStatusToUSBIP(urb.IsoPackets[i].Status)
	}
	resp := URBResponse{Status: status, ActualLength: int32(urb.Length), IsoPackets: req.IsoPackets}
	if command.Header.Direction == USBIPDirIn && urb.Length > 0 {
		end := int(urb.Length)
		if end > len(req.Buffer) {
			end = len(req.Buffer)
		}
		resp.Buffer = req.Buffer[:end]
	}
	return resp
}

type isoChunk struct {
	first int
	count int
	base  int
	end   int
}

// USBSUP_URB carries at most 8 packets, and its per-packet offsets are
// uint16 relative to the URB buffer, so each sub-URB's buffer pointer is
// advanced to its first packet to keep those offsets in range.
func (e *vboxusbEngine) isoSubmitSplit(req URBRequest) URBResponse {
	command := req.Command
	packets := command.IsoPackets
	for i := range packets {
		if packets[i].Length < 0 || packets[i].Length > 0xffff {
			return URBResponse{Error: E.New("vboxusb iso submit: packet length ", packets[i].Length, " exceeds driver limit")}
		}
		if packets[i].Offset < 0 || int(packets[i].Offset)+int(packets[i].Length) > len(req.Buffer) {
			return URBResponse{Error: E.New("vboxusb iso submit: packet ", i, " outside transfer buffer")}
		}
	}
	var chunks []isoChunk
	index := 0
	for index < len(packets) {
		chunk := isoChunk{first: index, base: int(packets[index].Offset)}
		chunk.end = chunk.base
		for index+chunk.count < len(packets) && chunk.count < vboxusb.MaxIsoPacketsPerURB {
			packet := packets[index+chunk.count]
			relativeOffset := int(packet.Offset) - chunk.base
			if relativeOffset < 0 {
				return URBResponse{Error: E.New("vboxusb iso submit: non-monotonic packet offsets")}
			}
			if relativeOffset > 0xffff {
				break
			}
			packetEnd := int(packet.Offset) + int(packet.Length)
			if packetEnd > chunk.end {
				chunk.end = packetEnd
			}
			chunk.count++
		}
		chunks = append(chunks, chunk)
		index += chunk.count
	}

	urbs := make([]*vboxusb.URB, len(chunks))
	submitErrors := make([]error, len(chunks))
	var wg sync.WaitGroup
	for chunkIndex, chunk := range chunks {
		pkts := make([]vboxusb.IsoPacket, chunk.count)
		for i := range chunk.count {
			packet := packets[chunk.first+i]
			pkts[i] = vboxusb.IsoPacket{
				Length: uint16(packet.Length),
				Offset: uint16(int(packet.Offset) - chunk.base),
			}
		}
		urb := &vboxusb.URB{
			Type:       vboxusb.TransferTypeIso,
			Endpoint:   uint32(req.Endpoint & 0x0f),
			Direction:  directionFromCommand(command.Header.Direction),
			Flags:      flagsFromCommand(command.TransferFlags, command.Header.Direction),
			Length:     uint64(chunk.end - chunk.base),
			Buffer:     req.Buffer[chunk.base:chunk.end],
			IsoPackets: pkts,
		}
		urbs[chunkIndex] = urb
		wg.Add(1)
		go func(chunkIndex int, urb *vboxusb.URB) {
			defer wg.Done()
			submitErrors[chunkIndex] = e.device.SendURB(urb)
		}(chunkIndex, urb)
	}
	wg.Wait()

	for chunkIndex, chunk := range chunks {
		status, ok := classifyURBError(submitErrors[chunkIndex])
		if !ok {
			return URBResponse{Error: submitErrors[chunkIndex]}
		}
		urb := urbs[chunkIndex]
		for i := range chunk.count {
			globalIndex := chunk.first + i
			if globalIndex >= len(req.IsoPackets) || i >= len(urb.IsoPackets) {
				break
			}
			req.IsoPackets[globalIndex].ActualLength = int32(urb.IsoPackets[i].Length)
			packetStatus := vboxusbStatusToUSBIP(urb.IsoPackets[i].Status)
			if packetStatus == 0 {
				packetStatus = status
			}
			req.IsoPackets[globalIndex].Status = packetStatus
		}
	}
	var total int64
	for i := range req.IsoPackets {
		total += int64(req.IsoPackets[i].ActualLength)
	}
	resp := URBResponse{Status: 0, ActualLength: int32(total), IsoPackets: req.IsoPackets}
	if command.Header.Direction == USBIPDirIn && total > 0 {
		resp.Buffer = req.Buffer
	}
	return resp
}

func directionFromCommand(usbipDir uint32) vboxusb.Direction {
	if usbipDir == USBIPDirIn {
		return vboxusb.DirectionIn
	}
	return vboxusb.DirectionOut
}

func flagsFromCommand(transferFlags int32, usbipDir uint32) vboxusb.TransferFlags {
	if usbipDir != USBIPDirIn {
		return vboxusb.TransferFlagNone
	}
	const usbipShortNotOK int32 = 0x00000001
	if transferFlags&usbipShortNotOK != 0 {
		return vboxusb.TransferFlagNone
	}
	return vboxusb.TransferFlagShortOK
}

func classifyURBError(err error) (int32, bool) {
	if err == nil {
		return 0, true
	}
	if statusErr, isStatus := E.Cast[*vboxusb.URBStatusError](err); isStatus {
		return vboxusbStatusToUSBIP(statusErr.Code), true
	}
	return 0, false
}

func vboxusbStatusToUSBIP(code vboxusb.URBError) int32 {
	switch code {
	case vboxusb.URBOK:
		return 0
	case vboxusb.URBStall:
		return -32 // EPIPE
	case vboxusb.URBDeviceNotResponding:
		return -19 // ENODEV
	case vboxusb.URBCRCError, vboxusb.URBNACError:
		return -71 // EPROTO
	case vboxusb.URBUnderrun, vboxusb.URBOverrun:
		return -75 // EOVERFLOW
	default:
		return usbipStatusEIO
	}
}
