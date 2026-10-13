package handler

import (
	"bytes"
	"compress/gzip"
	"fmt"
	"io"
	"log"
	"net/http"
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

// readRequestBody consumes and returns the client request body, capped at
// maxRequestBodySize, so every upstream attempt can replay it. Returns nil
// when the request carries no body.
func readRequestBody(r *http.Request) ([]byte, error) {
	if r.Body == nil {
		return nil, nil
	}
	b, err := io.ReadAll(io.LimitReader(r.Body, maxRequestBodySize))
	r.Body.Close()
	return b, err
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

	var lastErr error
	for attempt := 0; attempt <= maxRetries; attempt++ {
		if attempt > 0 {
			delay := passthroughRetryBaseDelay * time.Duration(attempt)
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
