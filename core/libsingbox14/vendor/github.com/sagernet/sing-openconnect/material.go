package openconnect

import (
	"os"

	E "github.com/sagernet/sing/common/exceptions"
)

type Material struct {
	Path    string
	Content []byte
}

func (m Material) Validate(name string) error {
	if m.Path != "" && len(m.Content) > 0 {
		return E.Extend(ErrMaterialSourceConflict, name)
	}
	return nil
}

func (m Material) IsSet() bool {
	return m.Path != "" || len(m.Content) > 0
}

func loadMaterial(material Material) ([]byte, error) {
	err := material.Validate("material")
	if err != nil {
		return nil, err
	}
	if len(material.Content) > 0 {
		return append([]byte(nil), material.Content...), nil
	}
	if material.Path == "" {
		return nil, nil
	}
	content, err := os.ReadFile(material.Path)
	if err != nil {
		return nil, E.Cause(err, "read openconnect material")
	}
	return content, nil
}
