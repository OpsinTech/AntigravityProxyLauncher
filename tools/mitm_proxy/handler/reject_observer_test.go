package handler

import (
	"bytes"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/KevinLiangX/AntigravityProxyLauncher/mitm_proxy/config"
	"github.com/KevinLiangX/AntigravityProxyLauncher/mitm_proxy/provider"
	"github.com/KevinLiangX/AntigravityProxyLauncher/mitm_proxy/translator"
	"github.com/elazarl/goproxy"
)

// captureRejectLog installs a sink that records emitted lines for the test.
func captureRejectLog(t *testing.T) *[]string {
	t.Helper()
	var lines []string
	prev := rejectLogSink
	rejectLogSink = func(format string, args ...any) {
		lines = append(lines, fmt.Sprintf(format, args...))
	}
	resetRejectObservations()
	t.Cleanup(func() {
		rejectLogSink = prev
		resetRejectObservations()
	})
	return &lines
}

func modelRequest(t *testing.T, model string) *http.Request {
	t.Helper()
	body := fmt.Sprintf(`{"model":%q,"request":{"contents":[{"role":"user","parts":[{"text":"hi"}]}]}}`, model)
	return httptest.NewRequest("POST", "https://daily-cloudcode-pa.googleapis.com/v1internal:streamGenerateContent",
		bytes.NewBufferString(body))
}

func TestObserveModelRejection_NativeCloudCodeIsFlagged(t *testing.T) {
	lines := captureRejectLog(t)
	req := modelRequest(t, "gemini-4-neon-high")
	observeModelRejection("gemini-4-neon-high", req, jsonResponse(http.StatusNotFound, []byte(`{"error":"model not found"}`)))

	if len(*lines) != 1 {
		t.Fatalf("expected one log line, got %d", len(*lines))
	}
	line := (*lines)[0]
	for _, want := range []string{"gemini-4-neon-high", "native=true", "count=1", "streamGenerateContent"} {
		if !strings.Contains(line, want) {
			t.Errorf("line %q missing %q", line, want)
		}
	}
}

func TestObserveModelRejection_ThirdPartyHostIsNotNative(t *testing.T) {
	lines := captureRejectLog(t)
	req := httptest.NewRequest("POST", "https://api.openai.com/v1/chat/completions", nil)
	observeModelRejection("qwen3-32b", req, jsonResponse(http.StatusNotFound, nil))

	if len(*lines) != 1 {
		t.Fatalf("expected one log line, got %d", len(*lines))
	}
	if !strings.Contains((*lines)[0], "native=false") {
		t.Errorf("third-party 404 must not be flagged native: %q", (*lines)[0])
	}
}

func TestObserveModelRejection_IgnoresOtherStatusesAndEmptyModel(t *testing.T) {
	lines := captureRejectLog(t)
	req := modelRequest(t, "gemini-4-neon-high")
	observeModelRejection("gemini-4-neon-high", req, jsonResponse(http.StatusInternalServerError, nil))
	observeModelRejection("gemini-4-neon-high", req, jsonResponse(http.StatusBadRequest, nil))
	observeModelRejection("", req, jsonResponse(http.StatusNotFound, nil))
	observeModelRejection("gemini-4-neon-high", req, nil)

	if len(*lines) != 0 {
		t.Errorf("only 404 with a model id may be logged, got %v", *lines)
	}
}

func TestObserveModelRejection_DedupesWithinWindow(t *testing.T) {
	lines := captureRejectLog(t)
	req := modelRequest(t, "gemini-4-carbon-high")
	for i := 0; i < 3; i++ {
		observeModelRejection("gemini-4-carbon-high", req, jsonResponse(http.StatusNotFound, nil))
	}
	if len(*lines) != 1 {
		t.Fatalf("expected a single line inside the dedupe window, got %d: %v", len(*lines), *lines)
	}
}

func TestObserveModelRejection_DistinctModelsAreLoggedSeparately(t *testing.T) {
	lines := captureRejectLog(t)
	observeModelRejection("gemini-4-argon-high", modelRequest(t, "gemini-4-argon-high"), jsonResponse(http.StatusNotFound, nil))
	observeModelRejection("gemini-4-carbon-high", modelRequest(t, "gemini-4-carbon-high"), jsonResponse(http.StatusNotFound, nil))
	if len(*lines) != 2 {
		t.Fatalf("expected one line per model, got %v", *lines)
	}
}

// TestGeminiHandler_404ObservationDoesNotTouchCatalog proves the observer is
// wired into the passthrough path and stays read-only: the cached catalog keeps
// every model, including the one upstream just rejected.
func TestGeminiHandler_404ObservationDoesNotTouchCatalog(t *testing.T) {
	lines := captureRejectLog(t)
	h := NewGeminiHandler(provider.NewRegistry(), translator.NewRegistry(), routingPtr(&config.RoutingConfig{}))
	isolateCatalogCache(t)

	cached := catalogBody("gemini-4-neon-high", "gemini-4-carbon-high", "claude-sonnet-5-5-high",
		"gemini-3.8-flash-high", "gemini-3.8-flash-low")
	h.catalog.store("anon", &catalogEntry{
		snapshot:  mustParse(t, cached),
		header:    http.Header{"Content-Type": {"application/json"}},
		updatedAt: time.Now(),
	})

	upstream := &fakeCatalogUpstream{byHost: map[string]func() *http.Response{
		"daily-cloudcode-pa.googleapis.com": func() *http.Response {
			return jsonResponse(http.StatusNotFound, []byte(`{"error":"model not found"}`))
		},
	}}
	ctx := &goproxy.ProxyCtx{RoundTripper: upstream}

	_, resp := h.Handle(modelRequest(t, "gemini-4-neon-high"), ctx)
	if resp == nil || resp.StatusCode != http.StatusNotFound {
		t.Fatalf("response must pass through untouched, got %+v", resp)
	}
	io.Copy(io.Discard, resp.Body)
	resp.Body.Close()

	if len(*lines) != 1 || !strings.Contains((*lines)[0], "gemini-4-neon-high") {
		t.Fatalf("expected one observation for the rejected model, got %v", *lines)
	}
	entry := h.catalog.peek("anon")
	if entry == nil {
		t.Fatal("catalog entry disappeared")
	}
	if entry.snapshot.modelCount() != 5 {
		t.Errorf("observation must not change the catalog: %d models", entry.snapshot.modelCount())
	}
	if !renderedIDs(t, entry.snapshot)["gemini-4-neon-high"] {
		t.Error("rejected model must stay selectable: eviction was explicitly not implemented")
	}
	if len(entry.miss) != 0 {
		t.Errorf("observation must not touch miss counters: %v", entry.miss)
	}
}
