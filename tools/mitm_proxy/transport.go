package main

import (
	"bufio"
	"context"
	"crypto/tls"
	"fmt"
	"net"
	"net/http"
	"net/url"
	"strings"
	"time"

	socks5proxy "golang.org/x/net/proxy"
)

// Timeouts for the outbound (upstream) leg. Without them a blackholed proxy
// node pins every request until the *client* gives up — the observed failure
// mode when the egress node cannot reach Google's API frontends: SOCKS5 CONNECT
// is granted, the TLS ClientHello is swallowed, and nothing ever times out
// inside the gateway. The client then sees 10-15s of "loading" per attempt,
// multiplied by passthrough retries.
const (
	// socks5DialTimeout bounds TCP connect to the local proxy *and* the SOCKS5
	// handshake with it, including remote name resolution.
	socks5DialTimeout = 10 * time.Second

	// upstreamTLSHandshakeTimeout bounds the TLS handshake with the upstream
	// host once the tunnel is up. This is the timeout that catches a node whose
	// route to the target silently drops packets. Healthy handshakes through the
	// local node measure 0.5-0.9s, so 15s leaves room for jitter without making
	// a dead path painful.
	upstreamTLSHandshakeTimeout = 15 * time.Second

	// upstreamResponseHeaderTimeout bounds the wait for the upstream's response
	// headers. Streaming responses (SSE) only have to deliver headers here; the
	// body is streamed unbounded afterwards, so this does not cap generation
	// time. It must stay generous: Gemini flushes headers only when the first
	// chunk is ready, and a model switch mid-conversation replays a huge history
	// (hundreds of KB plus dozens of tool definitions), where prefill alone can
	// exceed one minute.
	upstreamResponseHeaderTimeout = 120 * time.Second

	// upstreamExpectContinueTimeout is the standard 100-continue grace period.
	upstreamExpectContinueTimeout = 5 * time.Second
)

// newSocks5Transport builds the shared outbound transport used by both the
// goproxy engine and provider http.Clients (via http.DefaultTransport).
func newSocks5Transport(socks5Addr string) (*http.Transport, error) {
	dialer, err := socks5proxy.SOCKS5("tcp", socks5Addr, nil, &net.Dialer{
		Timeout:   socks5DialTimeout,
		KeepAlive: 30 * time.Second,
	})
	if err != nil {
		return nil, err
	}

	return &http.Transport{
		DialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
			return dialThroughSocks5(ctx, dialer, network, addr)
		},
		TLSHandshakeTimeout:   upstreamTLSHandshakeTimeout,
		ResponseHeaderTimeout: upstreamResponseHeaderTimeout,
		ExpectContinueTimeout: upstreamExpectContinueTimeout,
		MaxIdleConns:          100,
		MaxIdleConnsPerHost:   10,
		IdleConnTimeout:       90 * time.Second,
	}, nil
}

// newHTTPProxyTransport builds the outbound transport for an HTTP/HTTPS
// CONNECT proxy. The gateway used to hardcode SOCKS5, so "type": "http" in
// proxy_config.json produced a SOCKS5 handshake against an HTTP port and every
// request failed with an opaque 502.
func newHTTPProxyTransport(proxyType, addr string) (*http.Transport, error) {
	u, err := url.Parse(proxyType + "://" + addr)
	if err != nil {
		return nil, fmt.Errorf("invalid http proxy %q: %w", addr, err)
	}

	return &http.Transport{
		Proxy: http.ProxyURL(u),
		DialContext: (&net.Dialer{
			Timeout:   socks5DialTimeout,
			KeepAlive: 30 * time.Second,
		}).DialContext,
		TLSHandshakeTimeout:   upstreamTLSHandshakeTimeout,
		ResponseHeaderTimeout: upstreamResponseHeaderTimeout,
		ExpectContinueTimeout: upstreamExpectContinueTimeout,
		MaxIdleConns:          100,
		MaxIdleConnsPerHost:   10,
		IdleConnTimeout:       90 * time.Second,
	}, nil
}

// newHTTPConnectDialer opens a CONNECT tunnel through an HTTP(S) proxy.
//
// http.Transport.Proxy only covers requests the transport sends itself, but
// goproxy tunnels non-MITM CONNECT traffic through proxy.ConnectDial. Without
// this dialer, "type": "http" looked configured yet every tunnelled connection
// went direct (and failed behind a blocked egress).
func newHTTPConnectDialer(proxyType, proxyAddr string) func(network, addr string) (net.Conn, error) {
	return func(network, addr string) (net.Conn, error) {
		dialer := &net.Dialer{Timeout: socks5DialTimeout, KeepAlive: 30 * time.Second}
		conn, err := dialer.Dial(network, proxyAddr)
		if err != nil {
			return nil, fmt.Errorf("dial upstream proxy %s: %w", proxyAddr, err)
		}

		if proxyType == "https" {
			serverName, _, err := net.SplitHostPort(proxyAddr)
			if err != nil {
				serverName = proxyAddr
			}
			tlsConn := tls.Client(conn, &tls.Config{ServerName: serverName})
			if hsErr := tlsConn.Handshake(); hsErr != nil {
				conn.Close()
				return nil, fmt.Errorf("tls handshake with upstream proxy %s: %w", proxyAddr, hsErr)
			}
			conn = tlsConn
		}

		if _, err := fmt.Fprintf(conn, "CONNECT %s HTTP/1.1\r\nHost: %s\r\nProxy-Connection: keep-alive\r\n\r\n", addr, addr); err != nil {
			conn.Close()
			return nil, fmt.Errorf("write CONNECT to upstream proxy %s: %w", proxyAddr, err)
		}

		reader := bufio.NewReader(conn)
		_ = conn.SetReadDeadline(time.Now().Add(upstreamTLSHandshakeTimeout))
		resp, err := http.ReadResponse(reader, &http.Request{Method: http.MethodConnect})
		_ = conn.SetReadDeadline(time.Time{})
		if err != nil {
			conn.Close()
			return nil, fmt.Errorf("read CONNECT response from upstream proxy %s: %w", proxyAddr, err)
		}
		if resp.StatusCode != http.StatusOK {
			resp.Body.Close()
			conn.Close()
			return nil, fmt.Errorf("upstream proxy %s rejected CONNECT to %s: %s", proxyAddr, addr, resp.Status)
		}

		return &bufferedConn{Conn: conn, reader: reader}, nil
	}
}

// bufferedConn keeps bytes that bufio already read past the CONNECT response
// headers, so the tunnelled protocol never loses its first bytes.
type bufferedConn struct {
	net.Conn
	reader *bufio.Reader
}

func (c *bufferedConn) Read(p []byte) (int, error) {
	return c.reader.Read(p)
}

// newUpstreamTransport dispatches on the configured proxy type.
func newUpstreamTransport(proxyType, addr string) (*http.Transport, error) {
	switch strings.ToLower(strings.TrimSpace(proxyType)) {
	case "", "socks", "socks5", "socks5h":
		return newSocks5Transport(addr)
	case "http", "https":
		return newHTTPProxyTransport(strings.ToLower(strings.TrimSpace(proxyType)), addr)
	default:
		return nil, fmt.Errorf("unsupported upstream proxy type %q", proxyType)
	}
}

// dialThroughSocks5 runs the classic (context-less) SOCKS5 dialer in a
// goroutine so a stalled hop cannot outlive the caller's deadline. Without this
// the proxy's dial ignores request cancellation entirely: goproxy's RoundTrip
// ctx has no deadline of its own, so a blackholed node keeps the request parked
// until the OS-level TCP timeout.
func dialThroughSocks5(ctx context.Context, dialer socks5proxy.Dialer, network, addr string) (net.Conn, error) {
	if ctx == nil {
		ctx = context.Background()
	}
	dialCtx, cancel := context.WithTimeout(ctx, socks5DialTimeout)
	defer cancel()

	type dialResult struct {
		conn net.Conn
		err  error
	}
	done := make(chan dialResult, 1)
	go func() {
		conn, err := dialer.Dial(network, addr)
		done <- dialResult{conn: conn, err: err}
	}()

	select {
	case res := <-done:
		return res.conn, res.err
	case <-dialCtx.Done():
		// The dial goroutine may still succeed later; close whatever it returns
		// so the tunnel does not leak.
		go func() {
			if res := <-done; res.conn != nil {
				res.conn.Close()
			}
		}()
		return nil, fmt.Errorf("socks5 dial %s: %w", addr, dialCtx.Err())
	}
}
