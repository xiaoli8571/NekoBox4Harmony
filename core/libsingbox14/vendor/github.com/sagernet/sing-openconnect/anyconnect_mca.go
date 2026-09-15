// Portions of the AnyConnect multiple-certificate exchange are derived from
// OpenConnect commit 2035601b64a5360a46d18e08937e7f654b3230f2, auth.c
// prepare_multicert_response/post_multicert_response and openssl.c
// multicert_sign_data. OpenConnect is licensed LGPL-2.1-or-later.
package openconnect

import (
	"bytes"
	"crypto"
	"crypto/ecdsa"
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"encoding/base64"
	"encoding/xml"
	"strings"

	E "github.com/sagernet/sing/common/exceptions"

	"github.com/smallstep/pkcs7"
)

type anyConnectMCAHash struct {
	name string
	hash crypto.Hash
}

var anyConnectMCAHashes = []anyConnectMCAHash{
	{name: "sha512", hash: crypto.SHA512},
	{name: "sha384", hash: crypto.SHA384},
	{name: "sha256", hash: crypto.SHA256},
}

func buildAnyConnectMCAResponse(client *Client, identity *mcaIdentity, form anyConnectForm) ([]byte, error) {
	if client == nil || identity == nil || identity.Signer == nil {
		return nil, E.New("multiple-certificate authentication requires an MCA identity")
	}
	if len(form.RawResponse) == 0 {
		return nil, E.New("multiple-certificate request omitted the raw challenge response")
	}
	certificateData, err := marshalAnyConnectMCACertificates(identity.Certificate)
	if err != nil {
		return nil, err
	}
	hashMethod, signature, err := signAnyConnectMCAChallenge(identity.Signer, form.MultipleCertificateHashMethods, form.RawResponse)
	if err != nil {
		return nil, err
	}
	encodedCertificates := encodeAnyConnectMCABase64(certificateData)
	encodedSignature := encodeAnyConnectMCABase64(signature)
	var content bytes.Buffer
	content.WriteString(xml.Header)
	encoder := xml.NewEncoder(&content)
	root := xml.StartElement{
		Name: xml.Name{Local: "config-auth"},
		Attr: []xml.Attr{
			{Name: xml.Name{Local: "client"}, Value: "vpn"},
			{Name: xml.Name{Local: "type"}, Value: "auth-reply"},
			{Name: xml.Name{Local: "aggregate-auth-version"}, Value: "2"},
		},
	}
	err = encoder.EncodeToken(root)
	if err != nil {
		return nil, E.Cause(err, "encode AnyConnect MCA root")
	}
	err = encodeAnyConnectVersionAndDevice(encoder, client)
	if err != nil {
		return nil, err
	}
	err = encodeAnyConnectCapabilities(encoder, client)
	if err != nil {
		return nil, err
	}
	err = encodeAnyConnectTextElement(encoder, "session-token", "", nil)
	if err != nil {
		return nil, err
	}
	err = encodeAnyConnectTextElement(encoder, "session-id", "", nil)
	if err != nil {
		return nil, err
	}
	if form.Opaque != nil {
		err = encoder.Encode(form.Opaque)
		if err != nil {
			return nil, E.Cause(err, "echo AnyConnect MCA opaque state")
		}
	}
	authentication := xml.StartElement{Name: xml.Name{Local: "auth"}}
	err = encoder.EncodeToken(authentication)
	if err != nil {
		return nil, E.Cause(err, "encode AnyConnect MCA authentication")
	}
	machineChain := xml.StartElement{
		Name: xml.Name{Local: "client-cert-chain"},
		Attr: []xml.Attr{{Name: xml.Name{Local: "cert-store"}, Value: "1M"}},
	}
	err = encoder.EncodeToken(machineChain)
	if err != nil {
		return nil, E.Cause(err, "encode AnyConnect MCA machine certificate chain")
	}
	err = encodeAnyConnectTextElement(encoder, "client-cert-sent-via-protocol", "", nil)
	if err != nil {
		return nil, err
	}
	err = encoder.EncodeToken(machineChain.End())
	if err != nil {
		return nil, E.Cause(err, "close AnyConnect MCA machine certificate chain")
	}
	userChain := xml.StartElement{
		Name: xml.Name{Local: "client-cert-chain"},
		Attr: []xml.Attr{{Name: xml.Name{Local: "cert-store"}, Value: "1U"}},
	}
	err = encoder.EncodeToken(userChain)
	if err != nil {
		return nil, E.Cause(err, "encode AnyConnect MCA user certificate chain")
	}
	err = encodeAnyConnectTextElement(encoder, "client-cert", encodedCertificates, []xml.Attr{{Name: xml.Name{Local: "cert-format"}, Value: "pkcs7"}})
	if err != nil {
		return nil, err
	}
	err = encodeAnyConnectTextElement(encoder, "client-cert-auth-signature", encodedSignature, []xml.Attr{{Name: xml.Name{Local: "hash-algorithm-chosen"}, Value: hashMethod}})
	if err != nil {
		return nil, err
	}
	err = encoder.EncodeToken(userChain.End())
	if err != nil {
		return nil, E.Cause(err, "close AnyConnect MCA user certificate chain")
	}
	err = encoder.EncodeToken(authentication.End())
	if err != nil {
		return nil, E.Cause(err, "close AnyConnect MCA authentication")
	}
	err = encoder.EncodeToken(root.End())
	if err != nil {
		return nil, E.Cause(err, "close AnyConnect MCA root")
	}
	err = encoder.Flush()
	if err != nil {
		return nil, E.Cause(err, "flush AnyConnect MCA response")
	}
	return content.Bytes(), nil
}

func marshalAnyConnectMCACertificates(certificates [][]byte) ([]byte, error) {
	if len(certificates) == 0 {
		return nil, E.New("MCA identity has no certificates")
	}
	var certificateChain bytes.Buffer
	for i, certificateData := range certificates {
		_, err := x509.ParseCertificate(certificateData)
		if err != nil {
			return nil, E.Cause(err, "parse AnyConnect MCA certificate ", i)
		}
		certificateChain.Write(certificateData)
	}
	encodedCertificates, err := pkcs7.DegenerateCertificate(certificateChain.Bytes())
	if err != nil {
		return nil, E.Cause(err, "marshal AnyConnect MCA PKCS#7 certificate chain")
	}
	return encodedCertificates, nil
}

func signAnyConnectMCAChallenge(signer crypto.Signer, offeredMethods []string, challenge []byte) (string, []byte, error) {
	if len(challenge) == 0 {
		return "", nil, E.New("MCA challenge is empty")
	}
	switch signer.Public().(type) {
	case *rsa.PublicKey, *ecdsa.PublicKey:
	default:
		return "", nil, E.New("unsupported AnyConnect MCA signing key type")
	}
	offered := make(map[string]struct{}, len(offeredMethods))
	for _, method := range offeredMethods {
		offered[strings.ToLower(strings.TrimSpace(method))] = struct{}{}
	}
	var signingErrors []error
	foundCommonMethod := false
	for _, method := range anyConnectMCAHashes {
		_, methodOffered := offered[method.name]
		if !methodOffered {
			continue
		}
		foundCommonMethod = true
		digestState := method.hash.New()
		_, err := digestState.Write(challenge)
		if err != nil {
			return "", nil, E.Cause(err, "hash AnyConnect MCA challenge with ", method.name)
		}
		digest := digestState.Sum(nil)
		signature, err := signer.Sign(rand.Reader, digest, method.hash)
		if err != nil {
			signingErrors = append(signingErrors, E.Cause(err, "sign AnyConnect MCA challenge with ", method.name))
			continue
		}
		err = verifyAnyConnectMCASignature(signer.Public(), method.hash, digest, signature)
		if err != nil {
			signingErrors = append(signingErrors, E.Cause(err, "verify AnyConnect MCA ", method.name, " signature format"))
			continue
		}
		return method.name, signature, nil
	}
	if !foundCommonMethod {
		return "", nil, E.New("MCA signature hash negotiation failed; gateway offered: ", strings.Join(offeredMethods, ", "))
	}
	return "", nil, E.Cause(E.Errors(signingErrors...), "generate AnyConnect MCA signature")
}

func verifyAnyConnectMCASignature(publicKey crypto.PublicKey, hashMethod crypto.Hash, digest []byte, signature []byte) error {
	switch typedPublicKey := publicKey.(type) {
	case *rsa.PublicKey:
		err := rsa.VerifyPKCS1v15(typedPublicKey, hashMethod, digest, signature)
		if err != nil {
			return err
		}
	case *ecdsa.PublicKey:
		if !ecdsa.VerifyASN1(typedPublicKey, digest, signature) {
			return E.New("invalid ECDSA signature")
		}
	default:
		return E.New("unsupported MCA public key type")
	}
	return nil
}

func encodeAnyConnectMCABase64(content []byte) string {
	encoded := base64.StdEncoding.EncodeToString(content)
	if len(encoded) <= 64 {
		return encoded
	}
	var wrapped strings.Builder
	wrapped.Grow(len(encoded) + len(encoded)/64)
	for len(encoded) > 64 {
		wrapped.WriteString(encoded[:64])
		wrapped.WriteByte('\n')
		encoded = encoded[64:]
	}
	wrapped.WriteString(encoded)
	return wrapped.String()
}
