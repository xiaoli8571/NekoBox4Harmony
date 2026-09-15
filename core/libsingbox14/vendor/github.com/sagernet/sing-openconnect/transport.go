package openconnect

const (
	TransportCSTP = "cstp"
	TransportGPST = "gpst"
	TransportTLS  = "tls"
	TransportDTLS = "dtls"
	TransportIFT  = "ift"
	TransportONCP = "oncp"
	TransportESP  = "esp"
)

func (c *Client) ActiveTransport() string {
	c.activeTransportAccess.Lock()
	defer c.activeTransportAccess.Unlock()
	return c.activeTransport
}

func (c *Client) ActiveTransportUpdated() <-chan struct{} {
	c.activeTransportAccess.Lock()
	defer c.activeTransportAccess.Unlock()
	return c.activeTransportUpdated
}

func (c *Client) setActiveTransport(session clientSession, transport string) {
	c.lifecycleAccess.Lock()
	if c.activeTransportSession == session && (transport == "" || !c.closed && c.terminalError == nil) {
		c.setActiveTransportWithLifecycleLocked(transport)
	}
	c.lifecycleAccess.Unlock()
}

func (c *Client) stopActiveTransport(session clientSession) {
	c.lifecycleAccess.Lock()
	if c.activeTransportSession == session {
		c.activeTransportSession = nil
		c.setActiveTransportWithLifecycleLocked("")
	}
	c.lifecycleAccess.Unlock()
}

func (c *Client) setActiveTransportWithLifecycleLocked(transport string) {
	c.activeTransportAccess.Lock()
	if c.activeTransport != transport {
		c.activeTransport = transport
		close(c.activeTransportUpdated)
		c.activeTransportUpdated = make(chan struct{})
	}
	c.activeTransportAccess.Unlock()
}
