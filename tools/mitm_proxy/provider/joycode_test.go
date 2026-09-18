package provider

import (
	"context"
	"os"
	"strings"
	"testing"
	"time"
)

// TestJoyCodeSignUnit pins the gateway signature to a known vector computed
// with the reference implementation (joycode_api.py §3 of REPORT.md).
func TestJoyCodeSignUnit(t *testing.T) {
	params := map[string]string{
		"appid":      "joycode_ide",
		"functionId": "chat_completions",
		"t":          "1789697637680",
	}
	got := signJoyCodeQuery(params, joyCodeDefaultHMAC)
	want := "68f1c8c46e5e9839d95281726e1c2e647d1edc3b94728d7d8a2988adcb311c32"
	if got != want {
		t.Fatalf("sign mismatch:\n got %s\nwant %s", got, want)
	}
}

// TestJoyCodeSignSkipsEmpty checks that empty params are excluded before
// sorting (matching the Python reference: `if v not in ("", None)`).
func TestJoyCodeSignSkipsEmpty(t *testing.T) {
	full := map[string]string{"appid": "joycode_ide", "functionId": "fn", "t": "1"}
	empty := map[string]string{"appid": "joycode_ide", "functionId": "fn", "t": "1", "extra": ""}
	if signJoyCodeQuery(full, "k") != signJoyCodeQuery(empty, "k") {
		t.Fatal("empty params must be ignored in signing")
	}
}

// TestJoyCodeNewUUID checks shape only.
func TestJoyCodeNewUUID(t *testing.T) {
	u := newUUID()
	if len(u) != 36 || strings.Count(u, "-") != 4 {
		t.Fatalf("bad uuid: %s", u)
	}
}

// liveJoyCodeConfig builds a provider config from env vars so `go test` can
// exercise the real gateway without hardcoding credentials:
//
//	JOYCODE_PKEY=<ptKey> JOYCODE_TENANT=<tenant> go test -run TestJoyCodeLive -v
func liveJoyCodeConfig() (ProviderConfig, bool) {
	pkey := os.Getenv("JOYCODE_PKEY")
	if pkey == "" {
		return ProviderConfig{}, false
	}
	return ProviderConfig{
		ID:          "joycode-test",
		Name:        "JoyCode (test)",
		Type:        "joycode",
		ApiEndpoint: "api-ai.jd.com",
		ApiKey:      pkey,
		Models:      []string{"JoyAI-Code-1.5"},
		Options:     map[string]string{"tenant": os.Getenv("JOYCODE_TENANT")},
	}, true
}

// TestJoyCodeLive runs the full flow against the real gateway:
// model list -> prepare token -> non-streaming chat -> streaming chat.
func TestJoyCodeLive(t *testing.T) {
	cfg, ok := liveJoyCodeConfig()
	if !ok {
		t.Skip("JOYCODE_PKEY not set")
	}
	p, err := NewJoyCodeProvider(cfg)
	if err != nil {
		t.Fatal(err)
	}
	jp, ok := p.(*JoyCodeProvider)
	if !ok {
		t.Fatal("provider is not *JoyCodeProvider")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 120*time.Second)
	defer cancel()

	// 1. Model list
	jp.mu.Lock()
	mm := len(jp.modelMap)
	jp.mu.Unlock()
	t.Logf("model map entries after startup fetch: %d, models: %v", mm, p.SupportedModels())
	if mm == 0 {
		t.Fatal("model list fetch returned no mappings")
	}

	messages := []Message{{Role: "user", Content: "用一句话回答：你是什么模型？"}}

	// 2. Non-streaming
	nonStream := &ProviderRequest{Model: "JoyAI-Code-1.5", Messages: messages, Stream: false}
	resp, err := p.SendRequest(ctx, nonStream)
	if err != nil {
		t.Fatalf("non-streaming chat: %v", err)
	}
	if resp.Content == "" {
		t.Fatal("non-streaming chat returned empty content")
	}
	t.Logf("non-streaming reply (%d chars): %.200s", len(resp.Content), resp.Content)

	// 3. Streaming
	stream := &ProviderRequest{Model: "JoyAI-Code-1.5", Messages: messages, Stream: true}
	chunks, err := p.SendStreamRequest(ctx, stream)
	if err != nil {
		t.Fatalf("streaming chat: %v", err)
	}
	var sb strings.Builder
	done := false
	for chunk := range chunks {
		if chunk.Error != nil {
			t.Fatalf("stream error: %v", chunk.Error)
		}
		if chunk.Done {
			done = true
			break
		}
		sb.WriteString(chunk.Delta)
	}
	if !done {
		t.Fatal("stream closed without Done")
	}
	if sb.Len() == 0 {
		t.Fatal("streaming chat produced no content")
	}
	t.Logf("streaming reply (%d chars): %.200s", sb.Len(), sb.String())

	// 4. chatApiModel resolution (GLM-5.3 -> GLM-5.3-agent style)
	jp.mu.Lock()
	mapping := jp.modelMap["GLM-5.3"]
	jp.mu.Unlock()
	if mapping == "" {
		t.Logf("GLM-5.3 not in model map (may be absent for this account) — skipping resolution check")
	} else if mapping == "GLM-5.3" {
		t.Fatalf("GLM-5.3 expected to map to a chatApiModel, got identity: %s", mapping)
	} else {
		t.Logf("GLM-5.3 -> %s (resolution OK)", mapping)
	}
}

// TestJoyCodeLiveRawBody exercises the exact data path the reverse proxy's
// /v1/chat/completions endpoint uses: an OpenAI-format RawBody handed to the
// provider (what the openai->joycode passthrough translator produces), with
// the display label as the model name — verifying label->chatApiModel
// resolution + RawBody rebuild + prepare + chat.
func TestJoyCodeLiveRawBody(t *testing.T) {
	cfg, ok := liveJoyCodeConfig()
	if !ok {
		t.Skip("JOYCODE_PKEY not set")
	}
	p, err := NewJoyCodeProvider(cfg)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 120*time.Second)
	defer cancel()

	// GLM-5.3 (display label) — exercises chatApiModel resolution through the
	// RawBody path. Falls back to JoyAI-Code-1.5 if the account lacks GLM.
	m := "GLM-5.3"
	jp := p.(*JoyCodeProvider)
	jp.mu.Lock()
	_, hasGLM := jp.modelMap[m]
	jp.mu.Unlock()
	if !hasGLM {
		m = "JoyAI-Code-1.5"
		t.Logf("GLM-5.3 not available on this account, using %s", m)
	}

	rawBody := []byte(`{"model":"` + m + `","stream":false,"messages":[{"role":"user","content":"用一个字回答：好"}]}`)
	req := &ProviderRequest{Model: m, Messages: []Message{{Role: "user", Content: "x"}}, Stream: false, RawBody: rawBody}
	resp, err := p.SendRequest(ctx, req)
	if err != nil {
		t.Fatalf("raw-body chat: %v", err)
	}
	if resp.Content == "" {
		t.Fatal("raw-body chat returned empty content")
	}
	t.Logf("raw-body reply for %s (%d chars): %s", m, len(resp.Content), truncate(resp.Content, 200))
}
