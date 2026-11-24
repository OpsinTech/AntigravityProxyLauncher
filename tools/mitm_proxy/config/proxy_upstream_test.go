package config

import (
	"os"
	"path/filepath"
	"testing"
)

func writeProxyConfig(t *testing.T, body string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "proxy_config.json")
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatalf("write proxy config: %v", err)
	}
	return path
}

func TestLoadUpstreamProxyFromConfig(t *testing.T) {
	path := writeProxyConfig(t, `{"proxy":{"type":"http","host":"10.1.2.3","port":8080}}`)
	t.Setenv("PROXY_CONFIG", path)
	t.Setenv("SOCKS5_PROXY", "")
	t.Setenv("UPSTREAM_PROXY", "")

	got := LoadUpstreamProxy()
	want := UpstreamProxy{Type: "http", Host: "10.1.2.3", Port: 8080}
	if got != want {
		t.Fatalf("LoadUpstreamProxy() = %+v, want %+v", got, want)
	}
}

func TestLoadUpstreamProxyEnvWinsOverConfig(t *testing.T) {
	path := writeProxyConfig(t, `{"proxy":{"type":"http","host":"10.1.2.3","port":8080}}`)
	t.Setenv("PROXY_CONFIG", path)
	t.Setenv("UPSTREAM_PROXY", "socks5://127.0.0.1:7900")
	t.Setenv("SOCKS5_PROXY", "")

	got := LoadUpstreamProxy()
	want := UpstreamProxy{Type: "socks5", Host: "127.0.0.1", Port: 7900}
	if got != want {
		t.Fatalf("LoadUpstreamProxy() = %+v, want %+v", got, want)
	}
}

func TestLoadUpstreamProxyLegacySocksEnv(t *testing.T) {
	path := writeProxyConfig(t, `{"proxy":{"type":"http","host":"10.1.2.3","port":8080}}`)
	t.Setenv("PROXY_CONFIG", path)
	t.Setenv("UPSTREAM_PROXY", "")
	t.Setenv("SOCKS5_PROXY", "127.0.0.1:7897")

	got := LoadUpstreamProxy()
	want := UpstreamProxy{Type: "socks5", Host: "127.0.0.1", Port: 7897}
	if got != want {
		t.Fatalf("LoadUpstreamProxy() = %+v, want %+v", got, want)
	}
}

func TestLoadUpstreamProxyFallsBackToDefault(t *testing.T) {
	t.Setenv("PROXY_CONFIG", filepath.Join(t.TempDir(), "missing.json"))
	t.Setenv("SOCKS5_PROXY", "")
	t.Setenv("UPSTREAM_PROXY", "")

	got := LoadUpstreamProxy()
	if got.Type != "socks5" || got.Port != 7897 {
		t.Fatalf("LoadUpstreamProxy() = %+v, want default socks5:7897", got)
	}
}

func TestParseUpstreamProxy(t *testing.T) {
	cases := []struct {
		raw     string
		want    UpstreamProxy
		wantOK  bool
		comment string
	}{
		{"socks5://127.0.0.1:7900", UpstreamProxy{"socks5", "127.0.0.1", 7900}, true, "url form"},
		{"http://127.0.0.1:8080", UpstreamProxy{"http", "127.0.0.1", 8080}, true, "http url"},
		{"https://proxy.local:8443", UpstreamProxy{"https", "proxy.local", 8443}, true, "https url"},
		{"127.0.0.1:7897", UpstreamProxy{"socks5", "127.0.0.1", 7897}, true, "bare host:port"},
		{"socks://127.0.0.1:1080", UpstreamProxy{"socks5", "127.0.0.1", 1080}, true, "socks alias"},
		{"ftp://127.0.0.1:21", UpstreamProxy{}, false, "unsupported scheme"},
		{"http://127.0.0.1", UpstreamProxy{}, false, "missing port"},
		{"http://127.0.0.1:70000", UpstreamProxy{}, false, "port out of range"},
	}

	for _, tc := range cases {
		t.Run(tc.comment, func(t *testing.T) {
			got, ok := parseUpstreamProxy(tc.raw)
			if ok != tc.wantOK {
				t.Fatalf("parseUpstreamProxy(%q) ok = %v, want %v", tc.raw, ok, tc.wantOK)
			}
			if ok && got != tc.want {
				t.Fatalf("parseUpstreamProxy(%q) = %+v, want %+v", tc.raw, got, tc.want)
			}
		})
	}
}
