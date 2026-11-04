package provider

import (
	"net"
	"net/http"
	"time"
)

// directTransport 用于绕过本地 SOCKS 代理、直接拨号出站。
//
// 背景：main.go 会把 http.DefaultTransport 整体替换成走 SOCKS5 的 transport
// （默认 127.0.0.1:7897），以便访问需要翻墙的域名。但对国内的 provider
// （如 CodeBuddy / WorkBuddy 的 copilot.tencent.com）来说，这一绕会额外增加
// 约 1 秒的首字节延迟。配置 options.direct_connection = "true" 的 provider
// 改用本 transport，其余 provider 保持原样（仍走 DefaultTransport）。
//
// 与 SOCKS transport 一样显式设置 DialContext，因此同样不会启用 HTTP/2；
// 不设置 Proxy，确保不会意外继承 HTTP_PROXY/HTTPS_PROXY 环境变量。
var directTransport = &http.Transport{
	Proxy: nil,
	DialContext: (&net.Dialer{
		Timeout:   10 * time.Second,
		KeepAlive: 30 * time.Second,
	}).DialContext,
	ForceAttemptHTTP2:     false,
	MaxIdleConns:          100,
	MaxIdleConnsPerHost:   10,
	IdleConnTimeout:       120 * time.Second,
	TLSHandshakeTimeout:   10 * time.Second,
	ExpectContinueTimeout: 1 * time.Second,
}

// newProviderHTTPClient 按 provider 配置选择 HTTP 客户端。
// 默认返回空客户端（沿用 http.DefaultTransport，即全局 SOCKS 设置），
// 仅当 options.direct_connection = "true" 时改用直连 transport。
func newProviderHTTPClient(cfg ProviderConfig) *http.Client {
	if cfg.Options["direct_connection"] == "true" {
		return &http.Client{Transport: directTransport}
	}
	return &http.Client{}
}
