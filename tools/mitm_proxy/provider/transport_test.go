package provider

import "testing"

func TestNewProviderHTTPClientDefaultUsesGlobalTransport(t *testing.T) {
	client := newProviderHTTPClient(ProviderConfig{ID: "codebuddy"})
	if client.Transport != nil {
		t.Fatalf("默认应沿用 http.DefaultTransport（即全局 SOCKS 设置），实际指定了 Transport")
	}
}

func TestNewProviderHTTPClientDirectConnection(t *testing.T) {
	client := newProviderHTTPClient(ProviderConfig{
		ID:      "codebuddy",
		Options: map[string]string{"direct_connection": "true"},
	})
	if client.Transport != directTransport {
		t.Fatalf("开启 direct_connection 后应使用直连 transport")
	}
	if directTransport.Proxy != nil {
		t.Fatalf("直连 transport 不应设置 Proxy，否则会继承环境变量里的代理")
	}
}

func TestDirectTransportDoesNotEnableHTTP2(t *testing.T) {
	// 与 SOCKS transport 行为保持一致：显式 DialContext 时 Go 不会自动启用 HTTP/2
	if directTransport.ForceAttemptHTTP2 {
		t.Fatalf("直连 transport 不应强制启用 HTTP/2")
	}
}
