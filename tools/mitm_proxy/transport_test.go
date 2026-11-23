package main

import (
	"net/http"
	"testing"
)

func TestNewUpstreamTransportTypes(t *testing.T) {
	cases := []struct {
		proxyType string
		wantErr   bool
	}{
		{"", false},
		{"socks5", false},
		{"SOCKS5", false},
		{"http", false},
		{"https", false},
		{"ftp", true},
	}

	for _, tc := range cases {
		t.Run(tc.proxyType, func(t *testing.T) {
			tr, err := newUpstreamTransport(tc.proxyType, "127.0.0.1:7900")
			if tc.wantErr {
				if err == nil {
					t.Fatalf("newUpstreamTransport(%q) error = nil, want error", tc.proxyType)
				}
				return
			}
			if err != nil {
				t.Fatalf("newUpstreamTransport(%q) error = %v", tc.proxyType, err)
			}
			if tr == nil {
				t.Fatalf("newUpstreamTransport(%q) returned nil transport", tc.proxyType)
			}
		})
	}
}

func TestHTTPUpstreamTransportUsesConfiguredProxy(t *testing.T) {
	tr, err := newUpstreamTransport("http", "127.0.0.1:7900")
	if err != nil {
		t.Fatalf("newUpstreamTransport: %v", err)
	}

	req, err := http.NewRequest(http.MethodGet, "https://cloudcode-pa.googleapis.com/", nil)
	if err != nil {
		t.Fatalf("new request: %v", err)
	}

	proxyURL, err := tr.Proxy(req)
	if err != nil {
		t.Fatalf("transport.Proxy: %v", err)
	}
	if proxyURL == nil {
		t.Fatal("transport.Proxy returned nil for an http upstream")
	}
	if got, want := proxyURL.String(), "http://127.0.0.1:7900"; got != want {
		t.Fatalf("proxy URL = %q, want %q", got, want)
	}
}

func TestSocksUpstreamTransportDoesNotSetHTTPProxy(t *testing.T) {
	tr, err := newUpstreamTransport("socks5", "127.0.0.1:7900")
	if err != nil {
		t.Fatalf("newUpstreamTransport: %v", err)
	}

	req, _ := http.NewRequest(http.MethodGet, "https://example.com/", nil)
	if tr.Proxy != nil {
		if proxyURL, err := tr.Proxy(req); err != nil || proxyURL != nil {
			t.Fatalf("socks5 transport should dial through DialContext, got proxy=%v err=%v", proxyURL, err)
		}
	}
}
