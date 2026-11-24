package handler

import (
	"bytes"
	"compress/gzip"
	"context"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/elazarl/goproxy"
)

// passthroughMaxRetries bounds how many extra attempts a passthrough request
// gets when the upstream fails transiently (transport errors such as EOF or
// connection reset, HTTP 5xx, truncated response body) — 3 attempts total.
const passthroughMaxRetries = 2

// passthroughRetryBaseDelay is multiplied by the retry number (1s, 2s, ...)
// for backoff, matching the OpenAI provider retry policy.
const passthroughRetryBaseDelay = time.Second

// passthroughRetryBudget is the wall-clock ceiling for one request across all
// attempts, backoff included. A dead egress path (blackholed node: SOCKS5
// handshake succeeds, TLS ClientHello is swallowed) used to burn one full
// transport timeout per attempt, tripling the wait before the client saw a 502.
const passthroughRetryBudget = 20 * time.Second

// passthroughControlRetryBudget is the ceiling for idempotent control RPCs
// (listExperiments / loadCodeAssist / fetchUserInfo / ...). They are cheap and
// their failure is amplified: one swallowed TLS ClientHello makes the IDE treat
// all Gemini models as unavailable. One retry (15s timeout + 1s backoff + 15s)
// fits in this budget, so a transient node hiccup no longer surfaces as a 502
// that breaks model selection.
const passthroughControlRetryBudget = 32 * time.Second

// isTimeoutOrCanceled reports whether err is a timeout, a cancellation, or a
// caller deadline — the class that is only worth retrying for idempotent
// control RPCs.
func isTimeoutOrCanceled(err error) bool {
	if err == nil {
		return false
	}
	if errors.Is(err, context.Canceled) ||
		errors.Is(err, context.DeadlineExceeded) ||
		errors.Is(err, os.ErrDeadlineExceeded) {
		return true
	}
	var netErr net.Error
	return errors.As(err, &netErr) && netErr.Timeout()
}

// isRetryableControlRPCTimeout narrows isTimeoutOrCanceled to genuine transport
// timeouts. The caller's own cancellation (context.Canceled) and its deadline
// (context.DeadlineExceeded) stay one-shot even for control RPCs: the client is
// already gone, so retrying would only waste a request.
func isRetryableControlRPCTimeout(err error) bool {
	if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
		return false
	}
	return isTimeoutOrCanceled(err)
}

// isRetryablePassthroughError reports whether another attempt can plausibly
// succeed. Timeouts and client cancellations are one-shot for model calls: the
// path or the caller is gone, and retrying only multiplies the latency the user
// sees.
func isRetryablePassthroughError(err error) bool {
	if err == nil {
		return false
	}
	if errors.Is(err, context.Canceled) ||
		errors.Is(err, context.DeadlineExceeded) ||
		errors.Is(err, os.ErrDeadlineExceeded) {
		return false
	}
	var netErr net.Error
	if errors.As(err, &netErr) && netErr.Timeout() {
		return false
	}
	return true
}

// readRequestBody consumes and returns the client request body, capped at
// maxRequestBodySize, so every upstream attempt can replay it. Returns nil
// when the request carries no body.
func readRequestBody(r *http.Request) ([]byte, error) {
	return readRequestBodyCapped(r)
}

// roundTripWithRetry sends r upstream through the proxy chain (ctx.RoundTrip,
// which includes the configured SOCKS5 transport) and retries transient
// failures. bodyBytes is the buffered request body replayed on every attempt
// (nil = no body); maxRetries bounds the number of extra attempts.
//
// Retrying is safe because nothing has been forwarded to the client when these
// failures happen: transport errors and HTTP 5xx precede any client-visible
// data, and a truncated response body is detected before the client receives
// it. Streaming responses (SSE / streamGenerateContent) are forwarded as soon
// as the headers arrive and are never buffered or retried after that.
//
// Returns the upstream response — buffered for non-stream requests (with gzip
// bodies decompressed and Content-Encoding dropped), live and unbuffered for
// streams — or (nil, lastErr) once the attempts are exhausted.
func roundTripWithRetry(tag string, r *http.Request, bodyBytes []byte, ctx *goproxy.ProxyCtx, maxRetries int) (*http.Response, error) {
	isStream := strings.Contains(r.URL.Path, "streamGenerateContent")
	// Idempotent control RPCs get one extra attempt even on timeout: their
	// failure cascades into "all Gemini models unavailable" in the IDE, and a
	// node hiccup is usually gone a second later. Model calls keep the strict
	// fail-fast policy so a dead path cannot stack latency.
	controlRPC := isNonModelRpc(r.URL.Path)
	budget := passthroughRetryBudget
	if controlRPC {
		budget = passthroughControlRetryBudget
	}

	start := time.Now()
	var lastErr error
	for attempt := 0; attempt <= maxRetries; attempt++ {
		if attempt > 0 {
			delay := passthroughRetryBaseDelay * time.Duration(attempt)
			if spent := time.Since(start); spent+delay >= budget {
				log.Printf("[%s] Passthrough %s: abandoning retries after %d attempt(s) (%v of %v budget used, last: %v)",
					tag, r.URL.Path, attempt, spent.Round(time.Millisecond), budget, lastErr)
				break
			}
			log.Printf("[%s] Passthrough %s: transient upstream failure, retry %d/%d in %v (last: %v)",
				tag, r.URL.Path, attempt, maxRetries, delay, lastErr)
			time.Sleep(delay)
		}

		// Rebuild the body for each attempt (the transport consumes it).
		if bodyBytes != nil {
			r.Body = io.NopCloser(bytes.NewBuffer(bodyBytes))
			r.ContentLength = int64(len(bodyBytes))
		} else {
			r.Body = http.NoBody
			r.ContentLength = 0
		}

		resp, err := ctx.RoundTrip(r)
		if err != nil {
			lastErr = fmt.Errorf("roundtrip failed: %w", err)
			if !isRetryablePassthroughError(err) && !(controlRPC && isRetryableControlRPCTimeout(err)) {
				// Timeout or cancellation on a model call: another attempt cannot
				// help and would only stack more waiting on top of the client's.
				log.Printf("[%s] Passthrough %s: not retrying after %v (dead path or canceled request)",
					tag, r.URL.Path, lastErr)
				break
			}
			continue
		}
		if resp == nil || resp.Body == nil {
			lastErr = fmt.Errorf("upstream returned empty response")
			continue
		}

		// Headers received: the stream is live, forward immediately — never
		// buffer, never retry after this point.
		if isStream || resp.Header.Get("Content-Type") == "text/event-stream" {
			return resp, nil
		}

		if resp.StatusCode >= 500 {
			io.Copy(io.Discard, io.LimitReader(resp.Body, 4096))
			resp.Body.Close()
			lastErr = fmt.Errorf("API error (status %d)", resp.StatusCode)
			continue
		}

		body, readErr := io.ReadAll(resp.Body)
		resp.Body.Close()
		if readErr != nil {
			lastErr = fmt.Errorf("truncated upstream response: %w", readErr)
			continue
		}

		if len(body) >= 2 && body[0] == 0x1f && body[1] == 0x8b {
			gr, gzErr := gzip.NewReader(bytes.NewReader(body))
			if gzErr == nil {
				decompressed, derr := io.ReadAll(gr)
				gr.Close()
				if derr == nil && len(decompressed) > 0 {
					body = decompressed
				}
			}
		}

		resp.Header.Del("Content-Encoding")
		resp.ContentLength = int64(len(body))
		resp.Body = io.NopCloser(bytes.NewBuffer(body))
		return resp, nil
	}

	return nil, lastErr
}

// passthroughWithRetry is the retry-hardened raw passthrough used by every
// handler fallback. On exhausted attempts it surfaces a 502 instead of the
// silent nil response that left the client staring at a dead upstream with no
// feedback.
func passthroughWithRetry(tag string, r *http.Request, bodyBytes []byte, ctx *goproxy.ProxyCtx, maxRetries int) (*http.Request, *http.Response) {
	resp, err := roundTripWithRetry(tag, r, bodyBytes, ctx, maxRetries)
	if err != nil {
		log.Printf("[%s] Passthrough error: %v", tag, err)
		return r, goproxy.NewResponse(r, "text/plain", http.StatusBadGateway, "Upstream error")
	}
	return r, resp
}
