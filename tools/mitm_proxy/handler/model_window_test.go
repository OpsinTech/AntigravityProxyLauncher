package handler

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/KevinLiangX/AntigravityProxyLauncher/mitm_proxy/config"
	"github.com/KevinLiangX/AntigravityProxyLauncher/mitm_proxy/provider"
	"github.com/KevinLiangX/AntigravityProxyLauncher/mitm_proxy/translator"
	"github.com/elazarl/goproxy"
)

func newWindowHandler(rules []config.RoutingRule) *GeminiHandler {
	return NewGeminiHandler(provider.NewRegistry(), translator.NewRegistry(), routingPtr(&config.RoutingConfig{Rules: rules}))
}

// A fetchAvailableModels payload as the client receives it: the window lives in
// models[id].maxTokens / maxOutputTokens.
const availableModelsBody = `{
  "models": {
    "gemini-2.5-pro":   {"displayName":"Gemini 2.5 Pro","maxTokens":1048576,"maxOutputTokens":65536,"supportsImages":true,"model":1},
    "gemini-2.5-flash": {"displayName":"Gemini 2.5 Flash","maxTokens":1048576,"maxOutputTokens":65536,"supportsImages":true},
    "gemini-3-pro-low": {"displayName":"Gemini 3 Pro Low","maxTokens":200000,"maxOutputTokens":32768}
  },
  "defaultAgentModelId": "gemini-2.5-pro",
  "agentModelSorts": [{"displayName":"Recommended","groups":[{"modelIds":["gemini-2.5-pro"]}]}]
}`

func decodeModels(t *testing.T, body []byte) map[string]map[string]json.RawMessage {
	t.Helper()
	var top struct {
		Models map[string]map[string]json.RawMessage `json:"models"`
	}
	if err := json.Unmarshal(body, &top); err != nil {
		t.Fatalf("output is not valid JSON: %v\n%s", err, body)
	}
	return top.Models
}

func jsonInt(t *testing.T, raw json.RawMessage) int64 {
	t.Helper()
	var v int64
	if err := json.Unmarshal(raw, &v); err != nil {
		t.Fatalf("not an integer: %s", raw)
	}
	return v
}

func TestApplyModelWindowOverrides_RewritesOnlyMappedModels(t *testing.T) {
	h := newWindowHandler([]config.RoutingRule{
		{
			SourceModelPattern: "gemini-2.5-pro",
			TargetProviderID:   "my-openai",
			TargetModel:        "qwen3-32b",
			Enabled:            true,
			Options:            map[string]string{"context_window": "32000", "max_output_tokens": "8192"},
		},
	})

	out := h.applyModelWindowOverrides([]byte(availableModelsBody))
	models := decodeModels(t, out)

	if got := jsonInt(t, models["gemini-2.5-pro"]["maxTokens"]); got != 32000 {
		t.Errorf("mapped model maxTokens = %d, want 32000", got)
	}
	if got := jsonInt(t, models["gemini-2.5-pro"]["maxOutputTokens"]); got != 8192 {
		t.Errorf("mapped model maxOutputTokens = %d, want 8192", got)
	}
	// Unmapped models keep the upstream window verbatim.
	if got := jsonInt(t, models["gemini-2.5-flash"]["maxTokens"]); got != 1048576 {
		t.Errorf("unmapped model maxTokens = %d, want 1048576 unchanged", got)
	}
	// Unknown fields survive; large integers are not float-mangled.
	if string(models["gemini-2.5-pro"]["supportsImages"]) != "true" {
		t.Errorf("supportsImages lost: %s", models["gemini-2.5-pro"]["supportsImages"])
	}
	if string(models["gemini-2.5-pro"]["model"]) != "1" {
		t.Errorf("unknown field mangled: %s", models["gemini-2.5-pro"]["model"])
	}
	if !bytes.Contains(out, []byte(`"defaultAgentModelId"`)) {
		t.Errorf("top-level fields dropped: %s", out)
	}
}

func TestApplyModelWindowOverrides_PartialAndInvalidOptions(t *testing.T) {
	h := newWindowHandler([]config.RoutingRule{
		{
			SourceModelPattern: "gemini-2.5-pro",
			Enabled:            true,
			Options:            map[string]string{"max_output_tokens": "4096"},
		},
		{
			SourceModelPattern: "gemini-3",
			Enabled:            true,
			Options:            map[string]string{"context_window": "not-a-number"},
		},
		{
			// Disabled rules must not rewrite anything.
			SourceModelPattern: "flash",
			Enabled:            false,
			Options:            map[string]string{"context_window": "1000"},
		},
	})

	models := decodeModels(t, h.applyModelWindowOverrides([]byte(availableModelsBody)))

	if got := jsonInt(t, models["gemini-2.5-pro"]["maxOutputTokens"]); got != 4096 {
		t.Errorf("maxOutputTokens = %d, want 4096", got)
	}
	if got := jsonInt(t, models["gemini-2.5-pro"]["maxTokens"]); got != 1048576 {
		t.Errorf("maxTokens should stay upstream, got %d", got)
	}
	if got := jsonInt(t, models["gemini-3-pro-low"]["maxTokens"]); got != 200000 {
		t.Errorf("invalid option must not rewrite, got %d", got)
	}
	if got := jsonInt(t, models["gemini-2.5-flash"]["maxTokens"]); got != 1048576 {
		t.Errorf("disabled rule must not rewrite, got %d", got)
	}
}

func TestApplyModelWindowOverrides_SkipsBuiltinGeminiTarget(t *testing.T) {
	// A rule that keeps the request on Google's backend must not shrink the window:
	// the model really does have the official one.
	h := newWindowHandler([]config.RoutingRule{{
		SourceModelPattern: "gemini-2.5-pro",
		TargetProviderID:   config.GeminiBuiltinProviderID,
		TargetModel:        "gemini-2.5-pro",
		Enabled:            true,
		Options:            map[string]string{"context_window": "32000"},
	}})

	in := []byte(availableModelsBody)
	if out := h.applyModelWindowOverrides(in); !bytes.Equal(out, in) {
		t.Errorf("built-in Gemini rule must not rewrite the catalog: %s", out)
	}
	// The very same options do apply once the rule is routed to a third party.
	h2 := newWindowHandler([]config.RoutingRule{{
		SourceModelPattern: "gemini-2.5-pro",
		TargetProviderID:   "my-openai",
		TargetModel:        "qwen3-32b",
		Enabled:            true,
		Options:            map[string]string{"context_window": "32000"},
	}})
	models := decodeModels(t, h2.applyModelWindowOverrides(in))
	if got := jsonInt(t, models["gemini-2.5-pro"]["maxTokens"]); got != 32000 {
		t.Errorf("routed rule should still rewrite, got maxTokens=%d", got)
	}
}

func TestApplyModelWindowOverrides_NoConfigIsByteIdentical(t *testing.T) {
	h := newWindowHandler(nil)
	in := []byte(availableModelsBody)
	if out := h.applyModelWindowOverrides(in); !bytes.Equal(out, in) {
		t.Errorf("body changed with no rules configured")
	}
	// Non-JSON and empty payloads must pass through untouched.
	for _, in := range [][]byte{nil, []byte(""), []byte("not json"), []byte(`{"models":{}}`)} {
		if out := h.applyModelWindowOverrides(in); !bytes.Equal(out, in) {
			t.Errorf("body %q mutated", in)
		}
	}
}

func TestFetchAvailableModels_CachedBodyGetsOverrides(t *testing.T) {
	rules := []config.RoutingRule{{
		SourceModelPattern: "gemini-2.5-pro",
		Enabled:            true,
		Options:            map[string]string{"context_window": "32000"},
	}}
	h := newWindowHandler(rules)

	isolateCatalogCache(t)

	snap, err := parseCatalog([]byte(availableModelsBody))
	if err != nil {
		t.Fatalf("parseCatalog: %v", err)
	}
	h.catalog.store("anon", &catalogEntry{
		snapshot:  snap,
		header:    http.Header{},
		updatedAt: time.Now(),
	})

	req := httptest.NewRequest("POST", "https://daily-cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels", nil)
	_, resp := h.Handle(req, &goproxy.ProxyCtx{})
	if resp == nil {
		t.Fatal("expected cached response")
	}
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatalf("read body: %v", err)
	}
	models := decodeModels(t, body)
	if got := jsonInt(t, models["gemini-2.5-pro"]["maxTokens"]); got != 32000 {
		t.Errorf("cached body not rewritten: maxTokens=%d", got)
	}
	// The stored snapshot must stay raw so a config change applies immediately.
	if bytes.Contains(h.catalog.peek("anon").snapshot.encode(), []byte(`"maxTokens":32000`)) {
		t.Errorf("cached snapshot was mutated; overrides should be applied per response")
	}
}
