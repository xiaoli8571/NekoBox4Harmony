package protocol

type DatagramV2Type byte

const (
	DatagramV2TypeUDP         DatagramV2Type = 0
	DatagramV2TypeIP          DatagramV2Type = 1
	DatagramV2TypeIPWithTrace DatagramV2Type = 2
	DatagramV2TypeTracingSpan DatagramV2Type = 3

	TypeIDLength = 1
)

type DatagramV3Type byte

const (
	DatagramV3TypeRegistration         DatagramV3Type = 0
	DatagramV3TypePayload              DatagramV3Type = 1
	DatagramV3TypeICMP                 DatagramV3Type = 2
	DatagramV3TypeRegistrationResponse DatagramV3Type = 3

	MaxV3UDPPayloadLen = 1280
)

type RequestID [16]byte

type DatagramSender interface {
	SendDatagram(data []byte) error
}

type ConnectResponseWriter interface {
	WriteResponse(responseError error, metadata []Metadata) error
}

const (
	MetadataHTTPMethod       = "HttpMethod"
	MetadataHTTPHost         = "HttpHost"
	MetadataHTTPHeader       = "HttpHeader"
	MetadataHTTPHeaderPrefix = MetadataHTTPHeader + ":"
	MetadataHTTPStatus       = "HttpStatus"
)

const (
	DefaultDatagramVersion = "v2"
	DatagramVersionV3      = "v3"
)
