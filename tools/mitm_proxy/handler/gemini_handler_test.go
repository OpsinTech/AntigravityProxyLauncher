package handler

import (
	"bytes"
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

func TestIsNonModelRpc(t *testing.T) {
	testCases := []struct {
		path     string
		expected bool
	}{
		{"/v1/listExperiments", true},
		{"/google.internal.cloudcode.v1.CloudCodeService/fetchUserInfo", true},
		{"/google.internal.cloudcode.v1.CloudCodeService/loadCodeAssist", true},
		{"/recordTelemetry", true},
		{"/recordEvent", true},
		{"/checkEligibility", true},
		{"/v1beta/models/gemini-pro:generateContent", false},
		{"/v1beta/models/gemini-pro:streamGenerateContent", false},
		{"/v1/projects/test/locations/global/publishers/google/models/gemini-1.5-pro:streamGenerateContent", false},
	}

	for _, tc := range testCases {
		res := isNonModelRpc(tc.path)
		if res != tc.expected {
			t.Errorf("isNonModelRpc(%q) = %v, want %v", tc.path, res, tc.expected)
		}
	}
}

func TestGeminiHandler_FastBypassNonPost(t *testing.T) {
	routingCfg := &config.RoutingConfig{}
	provReg := provider.NewRegistry()
	transReg := translator.NewRegistry()
	h := NewGeminiHandler(provReg, transReg, routingCfg)

	req := httptest.NewRequest("GET", "https://cloudcode-pa.googleapis.com/v1/listExperiments", nil)
	ctx := &goproxy.ProxyCtx{}

	outReq, outResp := h.Handle(req, ctx)
	if outResp != nil {
		t.Errorf("Expected nil response for fast-bypassed GET request, got %+v", outResp)
	}
	if outReq != req {
		t.Errorf("Expected unchanged request pointer")
	}
}

func TestGeminiHandler_InternalRpcPassthrough(t *testing.T) {
	routingCfg := &config.RoutingConfig{}
	provReg := provider.NewRegistry()
	transReg := translator.NewRegistry()
	h := NewGeminiHandler(provReg, transReg, routingCfg)

	body := []byte(`{"userId": "12345"}`)
	req := httptest.NewRequest("POST", "https://cloudcode-pa.googleapis.com/v1/fetchUserInfo", bytes.NewReader(body))

	// Internal RPCs are forwarded upstream through the retry-hardened
	// passthrough instead of being model-translated, so a transient upstream
	// disconnect doesn't surface as a dead login page.
	upstreamCalls := 0
	ctx := &goproxy.ProxyCtx{RoundTripper: goproxy.RoundTripperFunc(func(r *http.Request, c *goproxy.ProxyCtx) (*http.Response, error) {
		upstreamCalls++
		return &http.Response{
			StatusCode: 200,
			Header:     http.Header{"Content-Type": []string{"application/json"}},
			Body:       io.NopCloser(strings.NewReader(`{"ok":true}`)),
			Request:    r,
		}, nil
	})}

	outReq, outResp := h.Handle(req, ctx)
	if outResp == nil {
		t.Fatalf("expected internal RPC to be passed through upstream, got nil response (outReq=%v)", outReq)
	}
	if outResp.StatusCode != 200 {
		t.Errorf("passed-through status = %d, want 200", outResp.StatusCode)
	}
	if upstreamCalls != 1 {
		t.Errorf("upstream attempts = %d, want 1", upstreamCalls)
	}
}

func TestGeminiHandler_GeminiBuiltinModelSubstitution(t *testing.T) {
	routingCfg := &config.RoutingConfig{
		Rules: []config.RoutingRule{
			{
				SourceModelPattern: "gemini-2.0-flash",
				TargetProviderID:   config.GeminiBuiltinProviderID,
				TargetModel:        "gemini-2.5-flash-preview",
				Enabled:            true,
			},
		},
	}
	provReg := provider.NewRegistry()
	transReg := translator.NewRegistry()
	h := NewGeminiHandler(provReg, transReg, routingCfg)

	rawBody := []byte(`{"model":"gemini-2.0-flash","request":{"contents":[{"parts":[{"text":"hello"}]}]}}`)
	req := httptest.NewRequest("POST", "https://cloudcode-pa.googleapis.com/v1/streamGenerateContent", bytes.NewReader(rawBody))

	// gemini_builtin keeps Google auth and only substitutes the model, then
	// forwards the live stream upstream — so capture what the upstream saw.
	var upstreamBody []byte
	ctx := &goproxy.ProxyCtx{RoundTripper: goproxy.RoundTripperFunc(func(r *http.Request, c *goproxy.ProxyCtx) (*http.Response, error) {
		upstreamBody, _ = io.ReadAll(r.Body)
		return &http.Response{
			StatusCode: 200,
			Header:     http.Header{"Content-Type": []string{"text/event-stream"}},
			Body:       io.NopCloser(strings.NewReader("data: {}\n\n")),
			Request:    r,
		}, nil
	})}

	_, outResp := h.Handle(req, ctx)
	if outResp == nil {
		t.Fatal("Expected the gemini_builtin stream to be forwarded upstream, got nil response")
	}
	if outResp.StatusCode != 200 {
		t.Errorf("Expected passed-through stream, got status %d", outResp.StatusCode)
	}

	// Verify the request body was modified to the new model
	if !bytes.Contains(upstreamBody, []byte("gemini-2.5-flash-preview")) {
		t.Errorf("Modified body did not contain target model: %s", string(upstreamBody))
	}
}

func TestEnsureThoughtSignatures(t *testing.T) {
	// 1. Cloud Code wrapped format with a third-party functionCall (lacking signature)
	wrappedInput := []byte(`{
		"model": "gemini-3.8-flash-high",
		"request": {
			"contents": [
				{
					"role": "user",
					"parts": [{"text": "hello"}]
				},
				{
					"role": "model",
					"parts": [
						{
							"functionCall": {
								"name": "default_api:replace_file_content",
								"args": {"path": "/tmp/a"}
							}
						}
					]
				}
			]
		}
	}`)

	patched := ensureThoughtSignatures(wrappedInput)
	if !bytes.Contains(patched, []byte(`"thought_signature":"skip_thought_signature_validator"`)) {
		t.Errorf("Expected thought_signature to be injected: %s", string(patched))
	}
	if bytes.Contains(patched, []byte(`"thoughtSignature"`)) {
		t.Errorf("Expected no duplicate thoughtSignature field: %s", string(patched))
	}

	// 2. Direct format with existing signature - must NOT overwrite
	directExisting := []byte(`{
		"contents": [
			{
				"role": "model",
				"parts": [
					{
						"functionCall": {"name": "view_file"},
						"thought_signature": "genuine_google_signature_abc123"
					}
				]
			}
		]
	}`)
	unchanged := ensureThoughtSignatures(directExisting)
	if !bytes.Contains(unchanged, []byte("genuine_google_signature_abc123")) {
		t.Errorf("Genuine thought_signature was overwritten: %s", string(unchanged))
	}
	if bytes.Contains(unchanged, []byte("skip_thought_signature_validator")) {
		t.Errorf("Should not inject sentinel when genuine signature exists: %s", string(unchanged))
	}
}

func TestGeminiHandler_FetchAvailableModelsCache(t *testing.T) {
	routingCfg := &config.RoutingConfig{}
	provReg := provider.NewRegistry()
	transReg := translator.NewRegistry()
	h := NewGeminiHandler(provReg, transReg, routingCfg)

	// Pre-populate cache
	cachedJSON := []byte(`{"models":{"gemini-3.8-flash-high":{"displayName":"Gemini 3.8 Flash (High)"}}}`)
	h.modelsCache.mu.Lock()
	h.modelsCache.body = cachedJSON
	h.modelsCache.updatedAt = time.Now()
	h.modelsCache.modelsSummary = "gemini-3.8-flash-high=Gemini 3.8 Flash (High);"
	h.modelsCache.mu.Unlock()

	req := httptest.NewRequest("POST", "https://daily-cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels", nil)
	ctx := &goproxy.ProxyCtx{}

	outReq, resp := h.Handle(req, ctx)
	if outReq == nil {
		t.Fatalf("Expected non-nil outReq")
	}
	if resp == nil {
		t.Fatalf("Expected cached http.Response, got nil")
	}
	if resp.StatusCode != 200 {
		t.Errorf("Expected status 200, got %d", resp.StatusCode)
	}

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatalf("Failed to read response body: %v", err)
	}
	if !bytes.Equal(body, cachedJSON) {
		t.Errorf("Expected body %s, got %s", string(cachedJSON), string(body))
	}
}

