package tstun

import (
	"errors"
	"fmt"

	"github.com/sagernet/tailscale/net/packet"
	"github.com/sagernet/tailscale/wgengine/filter"
	"github.com/sagernet/wireguard-go/device"
)

var errNoInputDevice = errors.New("input device not set")

const (
	ipv4HeaderSize = 20 // fixed IPv4 header (RFC 791 §3.1)
	ipv6HeaderSize = 40 // fixed IPv6 header (RFC 8200 §3)
)

// ReturnPath mirrors sing-tun's tun.Return: ReturnPackets writes back packets
// matching its NAT reverse table and returns the unconsumed subset in order,
// reusing the backing array of packets. Every offered packet must carry
// ReturnHeadroom writable bytes in front of the IP header.
type ReturnPath interface {
	ReturnHeadroom() int
	ReturnPackets(packets [][]byte) [][]byte
}

type returnPathState struct {
	returnPath ReturnPath
	headroom   int
}

// SetInputDevice enables InputPackets, feeding dev's encryption queues.
func (t *Wrapper) SetInputDevice(dev *device.Device) {
	t.inputDevice.Store(dev)
}

// SetReturnPath offers all decrypted packet batches to returnPath before the
// inbound filter.
func (t *Wrapper) SetReturnPath(returnPath ReturnPath) error {
	headroom := returnPath.ReturnHeadroom()
	if headroom > PacketStartOffset {
		return fmt.Errorf("return path headroom %d exceeds PacketStartOffset %d", headroom, PacketStartOffset)
	}
	t.returnPath.Store(&returnPathState{returnPath: returnPath, headroom: headroom})
	return nil
}

// InputPackets injects whole IP packets into the WireGuard encryption queues,
// bypassing the TUN read path. Packets are borrowed for the duration of the
// call: device.InputPackets copies them into pooled outbound elements, so a
// packet is copied up front only when SNAT must rewrite it.
func (t *Wrapper) InputPackets(packets [][]byte) ([][]byte, error) {
	dev := t.inputDevice.Load()
	if dev == nil {
		return nil, errNoInputDevice
	}
	pc := t.peerConfig.Load()
	p := parsedPacketPool.Get().(*packet.Parsed)
	defer parsedPacketPool.Put(p)
	buffers := make([][]byte, len(packets))
	originals := make([][]byte, len(packets))
	refs := make([]device.InputPacketRef, 0, len(packets))
	var accepted int
	for _, pkt := range packets {
		if len(pkt) == 0 {
			continue
		}
		version := pkt[0] >> 4 // IP version field (RFC 791 §3.1 / RFC 8200 §3)
		switch version {
		case 4:
			if len(pkt) < ipv4HeaderSize {
				continue
			}
		case 6:
			if len(pkt) < ipv6HeaderSize {
				continue
			}
		default:
			continue
		}
		p.Decode(pkt)
		if !t.disableFilter {
			response, _ := t.filterPacketOutboundToWireGuard(p, pc, nil)
			if response != filter.Accept {
				metricPacketOutDrop.Add(1)
				continue
			}
		}
		buffer := pkt
		if pc.selectSrcIP(p.Src.Addr(), p.Dst.Addr()) != p.Src.Addr() {
			buffer = append([]byte(nil), pkt...)
			p.Decode(buffer)
			pc.snat(p)
		}
		var destination []byte
		if version == 4 {
			destination = buffer[16:20] // IPv4 destination address field (RFC 791 §3.1)
		} else {
			destination = buffer[24:40] // IPv6 destination address field (RFC 8200 §3)
		}
		buffers[accepted] = buffer
		originals[accepted] = pkt
		refs = append(refs, device.InputPacketRef{
			Destination:  destination,
			PacketSlices: buffers[accepted : accepted+1],
		})
		accepted++
	}
	if accepted == 0 {
		return nil, nil
	}
	packetRefs := make([]*device.InputPacketRef, accepted)
	for i := range refs {
		packetRefs[i] = &refs[i]
	}
	unmatchedRefs := dev.InputPackets(packetRefs)
	t.noteActivity()
	metricPacketOut.Add(int64(accepted))
	if len(unmatchedRefs) == 0 {
		return nil, nil
	}
	unmatched := make([][]byte, 0, len(unmatchedRefs))
	for _, unmatchedRef := range unmatchedRefs {
		for i := range refs {
			if unmatchedRef == &refs[i] {
				unmatched = append(unmatched, originals[i])
				break
			}
		}
	}
	return unmatched, nil
}

// offerReturnPath applies dnat to every packet in buffs, offers the batch to
// the return path, and returns the unconsumed packets matched back to their
// original buffers by backing array identity.
func (t *Wrapper) offerReturnPath(state *returnPathState, buffs [][]byte, offset int) [][]byte {
	pc := t.peerConfig.Load()
	p := parsedPacketPool.Get().(*packet.Parsed)
	defer parsedPacketPool.Put(p)
	packets := make([][]byte, len(buffs))
	for i, buff := range buffs {
		p.Decode(buff[offset:])
		pc.dnat(p)
		packets[i] = buff[offset-state.headroom:]
	}
	unconsumed := state.returnPath.ReturnPackets(packets)
	if len(unconsumed) == len(buffs) {
		return buffs
	}
	remaining := make([][]byte, 0, len(unconsumed))
	searchIndex := 0
	for _, pkt := range unconsumed {
		for searchIndex < len(buffs) && &pkt[0] != &buffs[searchIndex][offset-state.headroom] {
			searchIndex++
		}
		if searchIndex == len(buffs) {
			break
		}
		remaining = append(remaining, buffs[searchIndex])
		searchIndex++
	}
	return remaining
}
