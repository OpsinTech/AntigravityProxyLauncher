package provider

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"
)

func benchBody(sizeBytes int) []byte {
	chunk := strings.Repeat("指令内容 xyz。", sizeBytes/24)
	body := map[string]any{
		"model":  "space-bunny",
		"stream": true,
		"messages": []map[string]any{
			{"role": "system", "content": "You are an AI agent powered by DeepSeek Harness.\n\n" + chunk},
			{"role": "user", "content": chunk},
		},
	}
	raw, _ := json.Marshal(body)
	return raw
}

func BenchmarkSanitizeSystemPrompt7MB(b *testing.B) {
	raw := benchBody(7 * 1024 * 1024)
	cfg := ProviderConfig{ID: "codebuddy", Options: map[string]string{"sanitize_system_prompt": "true"}}
	b.SetBytes(int64(len(raw)))
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_ = sanitizeSystemPrompt(raw, cfg)
	}
}

func BenchmarkSanitizeSystemPrompt7MBNoFingerprint(b *testing.B) {
	raw := benchBody(7 * 1024 * 1024)
	// 去掉指纹
	copy(raw, bytes.ReplaceAll(raw, []byte("DeepSeek Harness"), []byte("Acme Assistant   ")))
	cfg := ProviderConfig{ID: "codebuddy", Options: map[string]string{"sanitize_system_prompt": "true"}}
	b.SetBytes(int64(len(raw)))
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_ = sanitizeSystemPrompt(raw, cfg)
	}
}
