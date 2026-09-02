package handler

import (
	"bytes"
	"io"
	"net/http/httptest"
	"testing"

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

func TestGeminiHandler_FastBypassInternalRpc(t *testing.T) {
	routingCfg := &config.RoutingConfig{}
	provReg := provider.NewRegistry()
	transReg := translator.NewRegistry()
	h := NewGeminiHandler(provReg, transReg, routingCfg)

	body := []byte(`{"userId": "12345"}`)
	req := httptest.NewRequest("POST", "https://cloudcode-pa.googleapis.com/v1/fetchUserInfo", bytes.NewReader(body))
	ctx := &goproxy.ProxyCtx{}

	outReq, outResp := h.Handle(req, ctx)
	if outResp != nil {
		t.Errorf("Expected nil response for fast-bypassed internal RPC, got %+v", outResp)
	}
	if outReq != req {
		t.Errorf("Expected unchanged request pointer")
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
	ctx := &goproxy.ProxyCtx{}

	outReq, outResp := h.Handle(req, ctx)
	// gemini_builtin should return outResp == nil so goproxy transparently streams to upstream
	if outResp != nil {
		t.Errorf("Expected nil response for gemini_builtin streaming passthrough, got %+v", outResp)
	}

	// Verify the request body was modified to the new model
	bodyBytes, err := io.ReadAll(outReq.Body)
	if err != nil {
		t.Fatalf("Failed to read modified body: %v", err)
	}
	if !bytes.Contains(bodyBytes, []byte("gemini-2.5-flash-preview")) {
		t.Errorf("Modified body did not contain target model: %s", string(bodyBytes))
	}
}
