package openconnect

import (
	"io"
	"net/http"
	"strings"

	E "github.com/sagernet/sing/common/exceptions"
)

type oidcBearerRoundTripper struct {
	base  http.RoundTripper
	token string
}

func (t *oidcBearerRoundTripper) RoundTrip(request *http.Request) (*http.Response, error) {
	response, err := t.base.RoundTrip(request)
	if err != nil || response.StatusCode != http.StatusUnauthorized || request.Header.Get("Authorization") != "" || !hasBearerChallenge(response.Header.Values("WWW-Authenticate")) {
		return response, err
	}
	if request.Body != nil && request.GetBody == nil {
		return response, nil
	}
	_, _ = io.Copy(io.Discard, io.LimitReader(response.Body, 1024*1024))
	_ = response.Body.Close()
	retryRequest := request.Clone(request.Context())
	retryRequest.Header = request.Header.Clone()
	retryRequest.Header.Set("Authorization", "Bearer "+t.token)
	if request.Body != nil {
		retryRequest.Body, err = request.GetBody()
		if err != nil {
			return nil, E.Cause(err, "recreate OIDC authentication request body")
		}
	}
	return t.base.RoundTrip(retryRequest)
}

func hasBearerChallenge(values []string) bool {
	for _, value := range values {
		position := 0
		for position < len(value) {
			position = skipAuthenticationDelimiters(value, position)
			schemeStart := position
			position = scanAuthenticationToken(value, position)
			if position == schemeStart {
				break
			}
			if strings.EqualFold(value[schemeStart:position], "Bearer") {
				return true
			}
			position = nextAuthenticationChallenge(value, position)
		}
	}
	return false
}

func skipAuthenticationDelimiters(value string, position int) int {
	for position < len(value) && (value[position] == ' ' || value[position] == '\t' || value[position] == ',') {
		position++
	}
	return position
}

func skipAuthenticationWhitespace(value string, position int) int {
	for position < len(value) && (value[position] == ' ' || value[position] == '\t') {
		position++
	}
	return position
}

func scanAuthenticationToken(value string, position int) int {
	for position < len(value) {
		character := value[position]
		if character >= 'a' && character <= 'z' || character >= 'A' && character <= 'Z' || character >= '0' && character <= '9' || strings.ContainsRune("!#$%&'*+-.^_`|~", rune(character)) {
			position++
			continue
		}
		break
	}
	return position
}

func nextAuthenticationChallenge(value string, position int) int {
	quoted := false
	escaped := false
	for position < len(value) {
		character := value[position]
		if quoted {
			if escaped {
				escaped = false
			} else if character == '\\' {
				escaped = true
			} else if character == '"' {
				quoted = false
			}
			position++
			continue
		}
		if character == '"' {
			quoted = true
			position++
			continue
		}
		if character != ',' {
			position++
			continue
		}
		candidate := skipAuthenticationWhitespace(value, position+1)
		candidateEnd := scanAuthenticationToken(value, candidate)
		if candidateEnd == candidate {
			position++
			continue
		}
		afterCandidate := skipAuthenticationWhitespace(value, candidateEnd)
		if afterCandidate >= len(value) || value[afterCandidate] != '=' {
			return candidate
		}
		position = candidateEnd
	}
	return position
}

func (c *Client) wrapHTTPTransport(transport http.RoundTripper) http.RoundTripper {
	if c.options.Token == nil || c.options.Token.Mode != TokenModeOIDC {
		return transport
	}
	return &oidcBearerRoundTripper{base: transport, token: c.options.Token.Secret}
}
