package handler

import (
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// A body that exceeds the cap must be rejected in full — never silently
// truncated and forwarded as a half-written JSON document (which is what made
// Google answer 400 "Closing quote expected in string.").
func TestReadRequestBodyCapped_RejectsOversize(t *testing.T) {
	original := maxRequestBodySize
	maxRequestBodySize = 16
	t.Cleanup(func() { maxRequestBodySize = original })

	payload := `{"model":"gemini-4-hydrogen-medium","prompt":"` + strings.Repeat("x", 64) + `"}`
	req := httptest.NewRequest(http.MethodPost, "/v1internal:streamGenerateContent", strings.NewReader(payload))
	req.ContentLength = int64(len(payload))

	got, err := readRequestBodyCapped(req)
	if got != nil {
		t.Fatalf("expected no body on oversize, got %d bytes", len(got))
	}
	if !errors.Is(err, errRequestBodyTooLarge) {
		t.Fatalf("expected errRequestBodyTooLarge, got %v", err)
	}
	if !strings.Contains(err.Error(), "Content-Length") {
		t.Fatalf("error should carry Content-Length for diagnosis, got: %v", err)
	}
}

func TestReadRequestBodyCapped_AcceptsWithinLimit(t *testing.T) {
	original := maxRequestBodySize
	maxRequestBodySize = 1024
	t.Cleanup(func() { maxRequestBodySize = original })

	payload := `{"model":"hy3","ok":true}`
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(payload))
	req.ContentLength = int64(len(payload))

	got, err := readRequestBodyCapped(req)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if string(got) != payload {
		t.Fatalf("body changed: got %q, want %q", got, payload)
	}
}

// Exactly at the cap is allowed; only cap+1 and beyond are rejected.
func TestReadRequestBodyCapped_ExactLimit(t *testing.T) {
	original := maxRequestBodySize
	maxRequestBodySize = 8
	t.Cleanup(func() { maxRequestBodySize = original })

	req := httptest.NewRequest(http.MethodPost, "/x", strings.NewReader("12345678"))
	got, err := readRequestBodyCapped(req)
	if err != nil {
		t.Fatalf("unexpected error at exact limit: %v", err)
	}
	if string(got) != "12345678" {
		t.Fatalf("body changed: %q", got)
	}
}

func TestReadRequestBodyCapped_NilBody(t *testing.T) {
	req := httptest.NewRequest(http.MethodPost, "/x", nil)
	req.Body = nil
	got, err := readRequestBodyCapped(req)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got != nil {
		t.Fatalf("expected nil body, got %d bytes", len(got))
	}
}
