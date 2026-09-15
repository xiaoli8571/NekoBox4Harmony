package openvpn

import (
	"bytes"
	"encoding/asn1"
	"strings"

	E "github.com/sagernet/sing/common/exceptions"
)

type distinguishedNameAttribute struct {
	Type  asn1.ObjectIdentifier
	Value asn1.RawValue
}

// Upstream reads the subject through OpenSSL's X509_NAME, which holds every
// attribute in encoding order together with the index of the relative name it
// belongs to.
func parseDistinguishedName(rawName []byte) ([][]distinguishedNameAttribute, error) {
	var nameSequence asn1.RawValue
	trailing, err := asn1.Unmarshal(rawName, &nameSequence)
	if err != nil {
		return nil, err
	}
	if len(trailing) > 0 || nameSequence.Class != asn1.ClassUniversal || nameSequence.Tag != asn1.TagSequence {
		return nil, E.New("malformed certificate name")
	}
	var relativeNames [][]distinguishedNameAttribute
	remaining := nameSequence.Bytes
	for len(remaining) > 0 {
		var relativeName asn1.RawValue
		remaining, err = asn1.Unmarshal(remaining, &relativeName)
		if err != nil {
			return nil, err
		}
		if relativeName.Class != asn1.ClassUniversal || relativeName.Tag != asn1.TagSet {
			return nil, E.New("malformed certificate relative name")
		}
		var attributes []distinguishedNameAttribute
		attributeBytes := relativeName.Bytes
		for len(attributeBytes) > 0 {
			var attribute distinguishedNameAttribute
			attributeBytes, err = asn1.Unmarshal(attributeBytes, &attribute)
			if err != nil {
				return nil, err
			}
			attributes = append(attributes, attribute)
		}
		relativeNames = append(relativeNames, attributes)
	}
	return relativeNames, nil
}

// Upstream x509_get_subject (ssl_verify_openssl.c) renders the encoded subject
// with X509_NAME_print_ex under XN_FLAG_SEP_CPLUS_SPC | XN_FLAG_FN_SN |
// ASN1_STRFLGS_UTF8_CONVERT | ASN1_STRFLGS_ESC_CTRL, and verify_cert rejects
// the peer when that leaves the sink empty.
func formatCertificateSubject(rawSubject []byte) (string, error) {
	relativeNames, err := parseDistinguishedName(rawSubject)
	if err != nil {
		return "", err
	}
	var builder strings.Builder
	renderedCount := 0
	for _, attributes := range relativeNames {
		for attributeIndex, attribute := range attributes {
			if renderedCount > 0 {
				if attributeIndex > 0 {
					builder.WriteString(" + ")
				} else {
					builder.WriteString(", ")
				}
			}
			renderedCount++
			builder.WriteString(openSSLAttributeTypeName(attribute.Type))
			builder.WriteByte('=')
			value, valueErr := printAttributeValue(attribute.Value)
			if valueErr != nil {
				return "", valueErr
			}
			builder.WriteString(value)
		}
	}
	if renderedCount == 0 {
		return "", E.New("empty certificate subject")
	}
	return builder.String(), nil
}

// Upstream TLS_USERNAME_LEN (ssl_verify.c).
const certificateUsernameLength = 64

// Upstream extract_x509_field_ssl (ssl_verify_openssl.c) takes the last subject
// entry carrying the field, converts it with ASN1_STRING_to_UTF8, and copies it
// into a TLS_USERNAME_LEN buffer; verify_cert then runs string_mod_remap_name
// over the result.
func certificateUsername(rawSubject []byte, attributeType asn1.ObjectIdentifier) (string, error) {
	relativeNames, err := parseDistinguishedName(rawSubject)
	if err != nil {
		return "", err
	}
	var selectedValue asn1.RawValue
	found := false
	for _, attributes := range relativeNames {
		for _, attribute := range attributes {
			if attribute.Type.Equal(attributeType) {
				selectedValue = attribute.Value
				found = true
			}
		}
	}
	if !found {
		return "", E.New("certificate subject carries no ", openSSLAttributeTypeName(attributeType), " attribute")
	}
	characterWidth := openSSLCharacterWidth(selectedValue)
	if characterWidth < 0 {
		return "", E.New("certificate subject attribute is not a string")
	}
	username := selectedValue.Bytes
	if characterWidth > 0 {
		username, err = convertOpenSSLWideString(selectedValue.Bytes, characterWidth)
		if err != nil {
			return "", err
		}
	}
	terminator := bytes.IndexByte(username, 0)
	if terminator >= 0 {
		username = username[:terminator]
	}
	if len(username) > certificateUsernameLength {
		username = username[:certificateUsernameLength]
	}
	return remapNonPrintableCharacters(username), nil
}

// Upstream do_name_ex (crypto/asn1/a_strex.c) prints the OpenSSL short name of
// the attribute type and falls back to the numeric identifier, truncated to the
// 80 byte OBJ_obj2txt buffer, for types it carries no name for.
func openSSLAttributeTypeName(attributeType asn1.ObjectIdentifier) string {
	numericName := attributeType.String()
	shortName, named := openSSLAttributeTypeShortNames[numericName]
	if named {
		return shortName
	}
	if len(numericName) > 79 {
		numericName = numericName[:79]
	}
	return numericName
}

const (
	asn1TagVisibleString   = 26
	asn1TagUniversalString = 28
)

// Upstream tag2nbyte (crypto/asn1/a_strex.c) maps the string tag to the number
// of bytes per character, with zero for an already UTF-8 encoded string and a
// negative value for tags that carry no string.
func openSSLCharacterWidth(value asn1.RawValue) int {
	if value.Class != asn1.ClassUniversal {
		return -1
	}
	switch value.Tag {
	case asn1.TagUTF8String:
		return 0
	case asn1.TagNumericString, asn1.TagPrintableString, asn1.TagT61String,
		asn1.TagIA5String, asn1.TagUTCTime, asn1.TagGeneralizedTime, asn1TagVisibleString:
		return 1
	case asn1.TagBMPString:
		return 2
	case asn1TagUniversalString:
		return 4
	default:
		return -1
	}
}

// Upstream do_print_ex (crypto/asn1/a_strex.c) under ASN1_STRFLGS_UTF8_CONVERT
// hands a UTF8String through untouched and widens every other tag, including
// the tags it holds no width for, from its characters into UTF-8.
func printAttributeValue(value asn1.RawValue) (string, error) {
	characterWidth := openSSLCharacterWidth(value)
	if characterWidth == 0 {
		return escapeOpenSSLControlCharacters(value.Bytes), nil
	}
	if characterWidth < 0 {
		characterWidth = 1
	}
	converted, err := convertOpenSSLWideString(value.Bytes, characterWidth)
	if err != nil {
		return "", err
	}
	return escapeOpenSSLControlCharacters(converted), nil
}

func convertOpenSSLWideString(content []byte, characterWidth int) ([]byte, error) {
	if len(content)%characterWidth != 0 {
		return nil, E.New("malformed certificate name attribute value")
	}
	converted := make([]byte, 0, len(content))
	for offset := 0; offset < len(content); offset += characterWidth {
		var character uint32
		for _, unit := range content[offset : offset+characterWidth] {
			character = character<<8 | uint32(unit)
		}
		converted = appendOpenSSLUTF8(converted, character)
	}
	return converted, nil
}

// Upstream UTF8_putc (crypto/asn1/a_utf8.c) keeps the five and six byte forms
// that reach up to 0x7fffffff, where Go's utf8 encoder stops at 0x10ffff and
// substitutes the replacement character for surrogates.
func appendOpenSSLUTF8(destination []byte, character uint32) []byte {
	switch {
	case character < 0x80:
		return append(destination, byte(character))
	case character < 0x800:
		return append(destination,
			byte(character>>6)&0x1f|0xc0,
			byte(character)&0x3f|0x80)
	case character < 0x10000:
		return append(destination,
			byte(character>>12)&0x0f|0xe0,
			byte(character>>6)&0x3f|0x80,
			byte(character)&0x3f|0x80)
	case character < 0x200000:
		return append(destination,
			byte(character>>18)&0x07|0xf0,
			byte(character>>12)&0x3f|0x80,
			byte(character>>6)&0x3f|0x80,
			byte(character)&0x3f|0x80)
	case character < 0x4000000:
		return append(destination,
			byte(character>>24)&0x03|0xf8,
			byte(character>>18)&0x3f|0x80,
			byte(character>>12)&0x3f|0x80,
			byte(character>>6)&0x3f|0x80,
			byte(character)&0x3f|0x80)
	default:
		return append(destination,
			byte(character>>30)&0x01|0xfc,
			byte(character>>24)&0x3f|0x80,
			byte(character>>18)&0x3f|0x80,
			byte(character>>12)&0x3f|0x80,
			byte(character>>6)&0x3f|0x80,
			byte(character)&0x3f|0x80)
	}
}

const openSSLHexDigits = "0123456789ABCDEF"

// Upstream do_esc_char (crypto/asn1/a_strex.c) under ASN1_STRFLGS_ESC_CTRL
// escapes the bytes charmap marks as control, which are those below 0x20 plus
// delete, and doubles a backslash once any escaping flag is on.
func escapeOpenSSLControlCharacters(value []byte) string {
	var builder strings.Builder
	builder.Grow(len(value))
	for _, character := range value {
		switch {
		case character < 0x20 || character == 0x7f:
			builder.WriteByte('\\')
			builder.WriteByte(openSSLHexDigits[character>>4])
			builder.WriteByte(openSSLHexDigits[character&0x0f])
		case character == '\\':
			builder.WriteString(`\\`)
		default:
			builder.WriteByte(character)
		}
	}
	return builder.String()
}

// Upstream string_mod_remap_name (buffer.c) keeps CC_PRINT outside CC_CRLF,
// which passes every byte from 0x20 up except delete and replaces the rest.
func remapNonPrintableCharacters(value []byte) string {
	remapped := make([]byte, len(value))
	for index, character := range value {
		if character < 0x20 || character == 0x7f {
			remapped[index] = '_'
			continue
		}
		remapped[index] = character
	}
	return string(remapped)
}

var commonNameAttributeOID = asn1.ObjectIdentifier{2, 5, 4, 3}

// OBJ_nid2sn over the directory attribute types OpenSSL carries a name for.
var openSSLAttributeTypeShortNames = map[string]string{
	"0.9.2342.19200300.100.1.1":  "UID",
	"0.9.2342.19200300.100.1.2":  "textEncodedORAddress",
	"0.9.2342.19200300.100.1.3":  "mail",
	"0.9.2342.19200300.100.1.4":  "info",
	"0.9.2342.19200300.100.1.5":  "favouriteDrink",
	"0.9.2342.19200300.100.1.6":  "roomNumber",
	"0.9.2342.19200300.100.1.7":  "photo",
	"0.9.2342.19200300.100.1.8":  "userClass",
	"0.9.2342.19200300.100.1.9":  "host",
	"0.9.2342.19200300.100.1.10": "manager",
	"0.9.2342.19200300.100.1.11": "documentIdentifier",
	"0.9.2342.19200300.100.1.12": "documentTitle",
	"0.9.2342.19200300.100.1.13": "documentVersion",
	"0.9.2342.19200300.100.1.14": "documentAuthor",
	"0.9.2342.19200300.100.1.15": "documentLocation",
	"0.9.2342.19200300.100.1.20": "homeTelephoneNumber",
	"0.9.2342.19200300.100.1.21": "secretary",
	"0.9.2342.19200300.100.1.22": "otherMailbox",
	"0.9.2342.19200300.100.1.23": "lastModifiedTime",
	"0.9.2342.19200300.100.1.24": "lastModifiedBy",
	"0.9.2342.19200300.100.1.25": "DC",
	"0.9.2342.19200300.100.1.26": "aRecord",
	"0.9.2342.19200300.100.1.27": "pilotAttributeType27",
	"0.9.2342.19200300.100.1.28": "mXRecord",
	"0.9.2342.19200300.100.1.29": "nSRecord",
	"0.9.2342.19200300.100.1.30": "sOARecord",
	"0.9.2342.19200300.100.1.31": "cNAMERecord",
	"0.9.2342.19200300.100.1.37": "associatedDomain",
	"0.9.2342.19200300.100.1.38": "associatedName",
	"0.9.2342.19200300.100.1.39": "homePostalAddress",
	"0.9.2342.19200300.100.1.40": "personalTitle",
	"0.9.2342.19200300.100.1.41": "mobileTelephoneNumber",
	"0.9.2342.19200300.100.1.42": "pagerTelephoneNumber",
	"0.9.2342.19200300.100.1.43": "friendlyCountryName",
	"0.9.2342.19200300.100.1.44": "uid",
	"0.9.2342.19200300.100.1.45": "organizationalStatus",
	"0.9.2342.19200300.100.1.46": "janetMailbox",
	"0.9.2342.19200300.100.1.47": "mailPreferenceOption",
	"0.9.2342.19200300.100.1.48": "buildingName",
	"0.9.2342.19200300.100.1.49": "dSAQuality",
	"0.9.2342.19200300.100.1.50": "singleLevelQuality",
	"0.9.2342.19200300.100.1.51": "subtreeMinimumQuality",
	"0.9.2342.19200300.100.1.52": "subtreeMaximumQuality",
	"0.9.2342.19200300.100.1.53": "personalSignature",
	"0.9.2342.19200300.100.1.54": "dITRedirect",
	"0.9.2342.19200300.100.1.55": "audio",
	"0.9.2342.19200300.100.1.56": "documentPublisher",
	"1.2.840.113549.1.9.1":       "emailAddress",
	"1.2.840.113549.1.9.2":       "unstructuredName",
	"1.2.840.113549.1.9.8":       "unstructuredAddress",
	"1.3.6.1.4.1.311.60.2.1.1":   "jurisdictionL",
	"1.3.6.1.4.1.311.60.2.1.2":   "jurisdictionST",
	"1.3.6.1.4.1.311.60.2.1.3":   "jurisdictionC",
	"2.5.4.3":                    "CN",
	"2.5.4.4":                    "SN",
	"2.5.4.5":                    "serialNumber",
	"2.5.4.6":                    "C",
	"2.5.4.7":                    "L",
	"2.5.4.8":                    "ST",
	"2.5.4.9":                    "street",
	"2.5.4.10":                   "O",
	"2.5.4.11":                   "OU",
	"2.5.4.12":                   "title",
	"2.5.4.13":                   "description",
	"2.5.4.14":                   "searchGuide",
	"2.5.4.15":                   "businessCategory",
	"2.5.4.16":                   "postalAddress",
	"2.5.4.17":                   "postalCode",
	"2.5.4.18":                   "postOfficeBox",
	"2.5.4.19":                   "physicalDeliveryOfficeName",
	"2.5.4.20":                   "telephoneNumber",
	"2.5.4.21":                   "telexNumber",
	"2.5.4.22":                   "teletexTerminalIdentifier",
	"2.5.4.23":                   "facsimileTelephoneNumber",
	"2.5.4.24":                   "x121Address",
	"2.5.4.25":                   "internationaliSDNNumber",
	"2.5.4.26":                   "registeredAddress",
	"2.5.4.27":                   "destinationIndicator",
	"2.5.4.28":                   "preferredDeliveryMethod",
	"2.5.4.29":                   "presentationAddress",
	"2.5.4.30":                   "supportedApplicationContext",
	"2.5.4.31":                   "member",
	"2.5.4.32":                   "owner",
	"2.5.4.33":                   "roleOccupant",
	"2.5.4.34":                   "seeAlso",
	"2.5.4.35":                   "userPassword",
	"2.5.4.36":                   "userCertificate",
	"2.5.4.37":                   "cACertificate",
	"2.5.4.38":                   "authorityRevocationList",
	"2.5.4.39":                   "certificateRevocationList",
	"2.5.4.40":                   "crossCertificatePair",
	"2.5.4.41":                   "name",
	"2.5.4.42":                   "GN",
	"2.5.4.43":                   "initials",
	"2.5.4.44":                   "generationQualifier",
	"2.5.4.45":                   "x500UniqueIdentifier",
	"2.5.4.46":                   "dnQualifier",
	"2.5.4.47":                   "enhancedSearchGuide",
	"2.5.4.48":                   "protocolInformation",
	"2.5.4.49":                   "distinguishedName",
	"2.5.4.50":                   "uniqueMember",
	"2.5.4.51":                   "houseIdentifier",
	"2.5.4.52":                   "supportedAlgorithms",
	"2.5.4.53":                   "deltaRevocationList",
	"2.5.4.54":                   "dmdName",
	"2.5.4.65":                   "pseudonym",
	"2.5.4.72":                   "role",
	"2.5.4.97":                   "organizationIdentifier",
	"2.5.4.98":                   "c3",
	"2.5.4.99":                   "n3",
	"2.5.4.100":                  "dnsName",
}
