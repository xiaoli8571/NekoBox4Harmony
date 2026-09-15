//go:build linux || (darwin && cgo) || windows

package usbip

type URBEngine interface {
	Submit(request URBRequest) URBResponse
	AbortEndpoint(endpoint uint8) error
	Close() error
}

type URBRequest struct {
	Command    SubmitCommand
	Endpoint   uint8
	Buffer     []byte
	IsoPackets []IsoPacketDescriptor
}

type URBResponse struct {
	Status       int32
	ActualLength int32
	Buffer       []byte
	IsoPackets   []IsoPacketDescriptor
	Error        error
}
