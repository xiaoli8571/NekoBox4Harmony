package transport

import (
	"context"
	"hash/fnv"
	"net"
	"sync"
	"time"

	"github.com/sagernet/sing-cloudflared/internal/control"
	"github.com/sagernet/sing-cloudflared/internal/protocol"
	"github.com/sagernet/sing/common/json"
)

const (
	featureSelectorHostname       = "cfd-features.argotunnel.com"
	featureLookupTimeout          = 10 * time.Second
	defaultFeatureRefreshInterval = time.Hour
)

type cloudflaredFeaturesRecord struct {
	DatagramV3Percentage uint32 `json:"dv3_2"`
}

var LookupCloudflaredFeatures = func(ctx context.Context) ([]byte, error) {
	lookupCtx, cancel := context.WithTimeout(ctx, featureLookupTimeout)
	defer cancel()

	records, err := net.DefaultResolver.LookupTXT(lookupCtx, featureSelectorHostname)
	if err != nil || len(records) == 0 {
		return nil, err
	}
	return []byte(records[0]), nil
}

type FeatureSelector struct {
	configured             string
	accountTag             string
	lookup                 func(context.Context) ([]byte, error)
	refreshInterval        time.Duration
	currentDatagramVersion string

	access sync.RWMutex
}

func NewFeatureSelector(ctx context.Context, accountTag string, configured string) *FeatureSelector {
	selector := &FeatureSelector{
		configured:             configured,
		accountTag:             accountTag,
		lookup:                 LookupCloudflaredFeatures,
		refreshInterval:        defaultFeatureRefreshInterval,
		currentDatagramVersion: protocol.DefaultDatagramVersion,
	}
	if configured != "" {
		selector.currentDatagramVersion = configured
		return selector
	}
	_ = selector.refresh(ctx)
	if selector.refreshInterval > 0 {
		go selector.refreshLoop(ctx)
	}
	return selector
}

func (s *FeatureSelector) Snapshot() (string, []string) {
	if s == nil {
		return protocol.DefaultDatagramVersion, control.DefaultFeatures(protocol.DefaultDatagramVersion)
	}
	s.access.RLock()
	defer s.access.RUnlock()
	return s.currentDatagramVersion, control.DefaultFeatures(s.currentDatagramVersion)
}

func (s *FeatureSelector) refresh(ctx context.Context) error {
	if s == nil || s.configured != "" {
		return nil
	}
	record, err := s.lookup(ctx)
	if err != nil {
		return err
	}
	version, err := ResolveRemoteDatagramVersion(s.accountTag, record)
	if err != nil {
		return err
	}
	s.access.Lock()
	s.currentDatagramVersion = version
	s.access.Unlock()
	return nil
}

func (s *FeatureSelector) refreshLoop(ctx context.Context) {
	ticker := time.NewTicker(s.refreshInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			_ = s.refresh(ctx)
		}
	}
}

func ResolveRemoteDatagramVersion(accountTag string, record []byte) (string, error) {
	var features cloudflaredFeaturesRecord
	err := json.Unmarshal(record, &features)
	if err != nil {
		return "", err
	}
	if AccountEnabled(accountTag, features.DatagramV3Percentage) {
		return protocol.DatagramVersionV3, nil
	}
	return protocol.DefaultDatagramVersion, nil
}

func AccountEnabled(accountTag string, percentage uint32) bool {
	if percentage == 0 {
		return false
	}
	hasher := fnv.New32a()
	_, _ = hasher.Write([]byte(accountTag))
	return percentage > hasher.Sum32()%100
}
