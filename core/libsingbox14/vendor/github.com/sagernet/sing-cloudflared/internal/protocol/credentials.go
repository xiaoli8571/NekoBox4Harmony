package protocol

import "github.com/google/uuid"

type Credentials struct {
	AccountTag   string    `json:"AccountTag"`
	TunnelSecret []byte    `json:"TunnelSecret"`
	TunnelID     uuid.UUID `json:"TunnelID"`
	Endpoint     string    `json:"Endpoint,omitempty"`
}

type TunnelToken struct {
	AccountTag   string    `json:"a"`
	TunnelSecret []byte    `json:"s"`
	TunnelID     uuid.UUID `json:"t"`
	Endpoint     string    `json:"e,omitempty"`
}

func (t TunnelToken) ToCredentials() Credentials {
	return Credentials(t)
}

type TunnelAuth struct {
	AccountTag   string
	TunnelSecret []byte
}

func (c *Credentials) Auth() TunnelAuth {
	return TunnelAuth{
		AccountTag:   c.AccountTag,
		TunnelSecret: c.TunnelSecret,
	}
}
