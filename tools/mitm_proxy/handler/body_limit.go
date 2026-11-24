package handler

import (
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
)

// maxRequestBodySize is the hard cap for buffering a client request body.
//
// Cloud Code / Gemini requests carry base64 inline images on top of a long
// conversation history and dozens of tool schemas, so a single request can
// legitimately reach tens of megabytes. A previous 10 MB cap silently cut such
// bodies in the middle of a JSON string; the malformed result was forwarded
// upstream and Google answered 400 "Closing quote expected in string."
// Reading one byte past the cap now lets us detect and reject the request
// instead of forwarding a broken payload.
const defaultMaxRequestBodySize = 100 * 1024 * 1024 // 100MB

// maxRequestBodySize is a variable (not const) solely so tests can lower it
// without allocating 100 MB; production never reassigns it.
var maxRequestBodySize = defaultMaxRequestBodySize

// errRequestBodyTooLarge signals that a body was cut at maxRequestBodySize.
// It must never be forwarded upstream: a half-written JSON document surfaces
// as an opaque 400 from the model gateway.
var errRequestBodyTooLarge = errors.New("request body exceeds maximum allowed size")

// readRequestBodyCapped reads r.Body into memory, refusing to silently
// truncate. It reads up to maxRequestBodySize+1 bytes so an oversized body is
// detectable, and logs any Content-Length mismatch for diagnosis.
func readRequestBodyCapped(r *http.Request) ([]byte, error) {
	if r.Body == nil {
		return nil, nil
	}
	b, err := io.ReadAll(io.LimitReader(r.Body, int64(maxRequestBodySize)+1))
	r.Body.Close()
	if err != nil {
		return nil, err
	}
	if len(b) > maxRequestBodySize {
		return nil, fmt.Errorf("%w: body >%d bytes (Content-Length=%d, path=%s)",
			errRequestBodyTooLarge, maxRequestBodySize, r.ContentLength, r.URL.Path)
	}
	if r.ContentLength > 0 && int64(len(b)) != r.ContentLength {
		log.Printf("[Body] WARNING: short read on %s: got %d bytes, Content-Length=%d",
			r.URL.Path, len(b), r.ContentLength)
	}
	return b, nil
}
