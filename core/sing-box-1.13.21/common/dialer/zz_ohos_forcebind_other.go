//go:build !openharmony

package dialer

import "github.com/sagernet/sing/common/control"

func ohosForceBindFunc(alreadyBound bool, interfaceFinder control.InterfaceFinder) control.Func { return nil }
