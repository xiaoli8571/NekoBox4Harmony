package urltest

import (
	"context"
	"crypto/tls"
	"net"
	"net/http"
	"net/url"
	"sync"
	"time"

	"github.com/sagernet/sing-box/adapter"
	C "github.com/sagernet/sing-box/constant"
	"github.com/sagernet/sing/common"
	E "github.com/sagernet/sing/common/exceptions"
	M "github.com/sagernet/sing/common/metadata"
	N "github.com/sagernet/sing/common/network"
	"github.com/sagernet/sing/common/ntp"
	"github.com/sagernet/sing/common/observable"
)

type HistoryStorage struct {
	access       sync.RWMutex
	delayHistory map[string]*adapter.URLTestHistory
	updateHooks  []*observable.Subscriber[struct{}]
}

func NewHistoryStorage() *HistoryStorage {
	return &HistoryStorage{
		delayHistory: make(map[string]*adapter.URLTestHistory),
	}
}

func (s *HistoryStorage) AddUpdateHook(hook *observable.Subscriber[struct{}]) {
	s.access.Lock()
	defer s.access.Unlock()
	s.updateHooks = append(s.updateHooks, hook)
}

func (s *HistoryStorage) NotifyUpdated() {
	s.access.RLock()
	defer s.access.RUnlock()
	s.notifyUpdated()
}

func (s *HistoryStorage) LoadURLTestHistory(tag string) *adapter.URLTestHistory {
	if s == nil {
		return nil
	}
	s.access.RLock()
	defer s.access.RUnlock()
	return s.delayHistory[tag]
}

func (s *HistoryStorage) DeleteURLTestHistory(tag string) {
	s.access.Lock()
	delete(s.delayHistory, tag)
	s.notifyUpdated()
	s.access.Unlock()
}

func (s *HistoryStorage) StoreURLTestHistory(tag string, history *adapter.URLTestHistory) {
	s.access.Lock()
	s.delayHistory[tag] = history
	s.notifyUpdated()
	s.access.Unlock()
}

func (s *HistoryStorage) notifyUpdated() {
	for _, updateHook := range s.updateHooks {
		updateHook.Emit(struct{}{})
	}
}

func (s *HistoryStorage) Close() error {
	s.access.Lock()
	defer s.access.Unlock()
	s.updateHooks = nil
	return nil
}

// OHOS patch 7:状态码校验 + HEAD→GET 回退
//
// 上游 urlTest 拿到 HTTP 响应就直接返回耗时,从不看 StatusCode。
// 探测网址返回 403/404/500(CDN 劫持、GFW 污染返回错误页)时,节点照样
// 被判成"可用",直接击穿"绿=真可用"这个测速卖点。mihomo 的 urltest 有
// expected-status 选项专门处理这件事,这里补齐等价能力。
//
// 另外上游固定用 HEAD,部分站点对 HEAD 返回 405,会让整组节点假红。
// 这里在 HEAD 得到 405/501 时回退到 GET 再试一次。
type URLTestOptions struct {
	// true:仅 2xx 判定通过;false:任意响应码都算通(适合只关心 TCP/TLS 可达的自定义地址)
	Expect2xx bool
	// HEAD 收到 405/501 时是否回退到 GET
	AllowGetFallback bool
}

func DefaultURLTestOptions() URLTestOptions {
	return URLTestOptions{
		Expect2xx:       true,
		AllowGetFallback: true,
	}
}

func URLTest(ctx context.Context, link string, detour N.Dialer) (uint16, error) {
	return URLTestWithOptions(ctx, link, detour, DefaultURLTestOptions())
}

func URLTestWithOptions(ctx context.Context, link string, detour N.Dialer, options URLTestOptions) (uint16, error) {
	multiplexOutbound, isMultiplexOutbound := common.Cast[adapter.OutboundWithMultiplex](detour)
	if isMultiplexOutbound && multiplexOutbound.MultiplexEnabled() {
		_, err := urlTest(ctx, link, detour, options, http.MethodHead)
		if err != nil {
			return 0, err
		}
	}
	return urlTest(ctx, link, detour, options, http.MethodHead)
}

func urlTest(ctx context.Context, link string, detour N.Dialer, options URLTestOptions, method string) (t uint16, err error) {
	if link == "" {
		link = "https://www.gstatic.com/generate_204"
	}
	linkURL, err := url.Parse(link)
	if err != nil {
		return
	}
	hostname := linkURL.Hostname()
	port := linkURL.Port()
	if port == "" {
		switch linkURL.Scheme {
		case "http":
			port = "80"
		case "https":
			port = "443"
		}
	}

	start := time.Now()
	instance, err := detour.DialContext(ctx, "tcp", M.ParseSocksaddrHostPortStr(hostname, port))
	if err != nil {
		return
	}
	defer instance.Close()
	if N.NeedHandshakeForWrite(instance) {
		start = time.Now()
	}
	req, err := http.NewRequest(method, link, nil)
	if err != nil {
		return
	}
	client := http.Client{
		Transport: &http.Transport{
			DialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
				return instance, nil
			},
			TLSClientConfig: &tls.Config{
				Time:    ntp.TimeFuncFromContext(ctx),
				RootCAs: adapter.RootPoolFromContext(ctx),
			},
		},
		CheckRedirect: func(req *http.Request, via []*http.Request) error {
			return http.ErrUseLastResponse
		},
		Timeout: C.TCPTimeout,
	}
	defer client.CloseIdleConnections()
	resp, err := client.Do(req.WithContext(ctx))
	if err != nil {
		return
	}
	resp.Body.Close()
	// patch 7:HEAD 被站点拒绝(405/501)时回退到 GET 再试一次。
	// 必须排在状态码判定之前 —— 405/501 都不在 2xx 内,顺序反了这段就是死代码,
	// 默认选项(Expect2xx=true)下永远走不到。
	if options.AllowGetFallback && method == http.MethodHead &&
		(resp.StatusCode == http.StatusMethodNotAllowed || resp.StatusCode == http.StatusNotImplemented) {
		return urlTest(ctx, link, detour, options, http.MethodGet)
	}
	// patch 7:状态码判定(防"假绿":403/404/500 也曾被当成可用)
	if options.Expect2xx && (resp.StatusCode < 200 || resp.StatusCode >= 300) {
		return 0, E.New("unexpected HTTP status: ", resp.StatusCode)
	}
	t = uint16(time.Since(start) / time.Millisecond)
	return
}
