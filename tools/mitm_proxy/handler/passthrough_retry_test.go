package handler

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/elazarl/goproxy"
)

// timeoutErr mimics a dead egress path: the dial/handshake never completes.
type timeoutErr struct{}

func (timeoutErr) Error() string   { return "i/o timeout" }
func (timeoutErr) Timeout() bool   { return true }
func (timeoutErr) Temporary() bool { return true }

func TestIsRetryablePassthroughError(t *testing.T) {
	testCases := []struct {
		name     string
		err      error
		expected bool
	}{
		{"nil", nil, false},
		{"eof", io.EOF, true},
		{"unexpected eof", io.ErrUnexpectedEOF, true},
		{"connection reset", errors.New("read tcp: connection reset by peer"), true},
		{"timeout", timeoutErr{}, false},
		{"wrapped timeout", fmt.Errorf("roundtrip failed: %w", timeoutErr{}), false},
		{"context canceled", context.Canceled, false},
		{"context deadline", context.DeadlineExceeded, false},
	}

	for _, tc := range testCases {
		t.Run(tc.name, func(t *testing.T) {
			if got := isRetryablePassthroughError(tc.err); got != tc.expected {
				t.Errorf("isRetryablePassthroughError(%v) = %v, want %v", tc.err, got, tc.expected)
			}
		})
	}
}

// A blackholed node must fail fast on model calls: retrying a timeout only
// stacks more waiting on top of the client's.
func TestRoundTripWithRetry_DoesNotRetryTimeout(t *testing.T) {
	req := httptest.NewRequest("POST", "https://cloudcode-pa.googleapis.com/v1internal:streamGenerateContent?alt=sse", strings.NewReader(`{}`))

	calls := 0
	ctx := &goproxy.ProxyCtx{RoundTripper: goproxy.RoundTripperFunc(func(r *http.Request, c *goproxy.ProxyCtx) (*http.Response, error) {
		calls++
		return nil, timeoutErr{}
	})}

	resp, err := roundTripWithRetry("Test", req, []byte(`{}`), ctx, passthroughMaxRetries)
	if resp != nil {
		t.Fatalf("expected nil response on dead path, got %+v", resp)
	}
	if err == nil {
		t.Fatal("expected an error on dead path, got nil")
	}
	if calls != 1 {
		t.Fatalf("timeout should not be retried: upstream attempts = %d, want 1", calls)
	}
}

// Idempotent control RPCs are the exception: one swallowed TLS ClientHello makes
// the IDE mark every Gemini model unavailable, so a timeout gets one more try.
func TestRoundTripWithRetry_RetriesTimeoutOnControlRPC(t *testing.T) {
	req := httptest.NewRequest("POST", "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist", strings.NewReader(`{}`))

	calls := 0
	ctx := &goproxy.ProxyCtx{RoundTripper: goproxy.RoundTripperFunc(func(r *http.Request, c *goproxy.ProxyCtx) (*http.Response, error) {
		calls++
		return nil, timeoutErr{}
	})}

	resp, err := roundTripWithRetry("Test", req, []byte(`{}`), ctx, passthroughMaxRetries)
	if resp != nil || err == nil {
		t.Fatalf("expected (nil, err), got (%+v, %v)", resp, err)
	}
	if calls < 2 {
		t.Fatalf("control RPC timeout should be retried: upstream attempts = %d, want >= 2", calls)
	}
}

// Canceled requests are never retried, even for control RPCs.
func TestRoundTripWithRetry_DoesNotRetryCanceledControlRPC(t *testing.T) {
	req := httptest.NewRequest("POST", "https://cloudcode-pa.googleapis.com/v1internal:listExperiments", strings.NewReader(`{}`))

	calls := 0
	ctx := &goproxy.ProxyCtx{RoundTripper: goproxy.RoundTripperFunc(func(r *http.Request, c *goproxy.ProxyCtx) (*http.Response, error) {
		calls++
		return nil, context.Canceled
	})}

	if _, err := roundTripWithRetry("Test", req, []byte(`{}`), ctx, passthroughMaxRetries); err == nil {
		t.Fatal("expected an error")
	}
	if calls != 1 {
		t.Fatalf("canceled request must not be retried: upstream attempts = %d, want 1", calls)
	}
}
