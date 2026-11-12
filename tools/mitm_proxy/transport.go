package main

import (
	"context"
	"fmt"
	"net"
	"net/http"
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
	// route to the target silently drops packets.
	upstreamTLSHandshakeTimeout = 10 * time.Second

	// upstreamResponseHeaderTimeout bounds the wait for the upstream's response
	// headers. Streaming responses (SSE) only have to deliver headers here; the
	// body is streamed unbounded afterwards, so this does not cap generation
	// time. Keep it generous: some gateways only flush headers with the first
	// token.
	upstreamResponseHeaderTimeout = 60 * time.Second

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
