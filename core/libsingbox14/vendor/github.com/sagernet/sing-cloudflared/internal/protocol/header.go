package protocol

import (
	"encoding/base64"
	"net/http"
	"strings"
)

const (
	H2HeaderUpgrade        = "Cf-Cloudflared-Proxy-Connection-Upgrade"
	H2HeaderTCPSrc         = "Cf-Cloudflared-Proxy-Src"
	H2HeaderResponseMeta   = "Cf-Cloudflared-Response-Meta"
	H2HeaderResponseUser   = "Cf-Cloudflared-Response-Headers"
	H2UpgradeControlStream = "control-stream"
	H2UpgradeWebsocket     = "websocket"
	H2UpgradeConfiguration = "update-configuration"
	H2ResponseMetaOrigin   = `{"src":"origin"}`
)

var HeaderEncoding = base64.RawStdEncoding

func SerializeHeaders(header http.Header) string {
	var builder strings.Builder
	for name, values := range header {
		for _, value := range values {
			if builder.Len() > 0 {
				builder.WriteByte(';')
			}
			builder.WriteString(HeaderEncoding.EncodeToString([]byte(name)))
			builder.WriteByte(':')
			builder.WriteString(HeaderEncoding.EncodeToString([]byte(value)))
		}
	}
	return builder.String()
}

func IsControlResponseHeader(name string) bool {
	return strings.HasPrefix(name, ":") ||
		strings.HasPrefix(name, "cf-int-") ||
		strings.HasPrefix(name, "cf-cloudflared-") ||
		strings.HasPrefix(name, "cf-proxy-")
}

func IsWebsocketClientHeader(name string) bool {
	return name == "sec-websocket-accept" ||
		name == "connection" ||
		name == "upgrade"
}
