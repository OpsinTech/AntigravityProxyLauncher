package provider

import (
	"encoding/json"
	"testing"
)

const fingerprint = "You are an AI agent powered by DeepSeek Harness."

func decodeMessages(t *testing.T, raw []byte) []map[string]any {
	t.Helper()
	var body struct {
		Messages []map[string]any `json:"messages"`
	}
	if err := json.Unmarshal(raw, &body); err != nil {
		t.Fatalf("unmarshal result: %v", err)
	}
	return body.Messages
}

func TestSanitizeSystemPromptDisabled(t *testing.T) {
	raw := []byte(`{"model":"m","messages":[{"role":"system","content":"` + fingerprint + `"},{"role":"user","content":"hi"}]}`)
	cfg := ProviderConfig{ID: "codebuddy", Options: map[string]string{"api_path": "/v2/chat/completions"}}

	if got := string(sanitizeSystemPrompt(raw, cfg)); got != string(raw) {
		t.Fatalf("未开启开关时不应修改请求体\n got: %s", got)
	}
}

func TestSanitizeSystemPromptSkipsWhenNoFingerprint(t *testing.T) {
	raw := []byte(`{"model":"m","messages":[{"role":"system","content":"You are Antigravity assistant."},{"role":"user","content":"hi"}]}`)
	cfg := ProviderConfig{ID: "codebuddy", Options: map[string]string{"sanitize_system_prompt": "true"}}

	if got := string(sanitizeSystemPrompt(raw, cfg)); got != string(raw) {
		t.Fatalf("没有命中指纹时不应修改请求体")
	}
}

func TestSanitizeSystemPromptMovesSystemIntoUser(t *testing.T) {
	raw := []byte(`{"model":"m","max_tokens":8,"messages":[{"role":"system","content":"` + fingerprint + `\nLINE2"},{"role":"user","content":"hi"},{"role":"assistant","content":"yo"}]}`)
	cfg := ProviderConfig{ID: "codebuddy", Options: map[string]string{"sanitize_system_prompt": "true"}}

	messages := decodeMessages(t, sanitizeSystemPrompt(raw, cfg))
	if len(messages) != 4 {
		t.Fatalf("期望 4 条消息，得到 %d", len(messages))
	}
	if messages[0]["content"] == fingerprint+"\nLINE2" {
		t.Fatalf("system 内容应被替换为中性文案")
	}
	if messages[1]["role"] != "user" || messages[1]["content"] != fingerprint+"\nLINE2" {
		t.Fatalf("原始 system 内容应原样移到第二条 user 消息，得到 %v", messages[1])
	}
	if messages[2]["content"] != "hi" || messages[3]["content"] != "yo" {
		t.Fatalf("其余消息顺序应保持不变")
	}
}

func TestSanitizeSystemPromptCaseInsensitiveFingerprint(t *testing.T) {
	raw := []byte(`{"messages":[{"role":"system","content":"you are an ai agent powered by deepseek harness"},{"role":"user","content":"hi"}]}`)
	cfg := ProviderConfig{ID: "codebuddy", Options: map[string]string{"sanitize_system_prompt": "true"}}

	messages := decodeMessages(t, sanitizeSystemPrompt(raw, cfg))
	if len(messages) != 3 {
		t.Fatalf("大小写不同的指纹也应触发迁移，实际消息数 %d", len(messages))
	}
}

func TestSanitizeSystemPromptKeepsOtherTopLevelFields(t *testing.T) {
	raw := []byte(`{"model":"space-bunny","max_completion_tokens":128000,"store":false,"stream":true,"messages":[{"role":"system","content":"` + fingerprint + `"},{"role":"user","content":"hi"}]}`)
	cfg := ProviderConfig{ID: "codebuddy", Options: map[string]string{"sanitize_system_prompt": "true"}}

	var body map[string]any
	if err := json.Unmarshal(sanitizeSystemPrompt(raw, cfg), &body); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if body["model"] != "space-bunny" || body["stream"] != true || body["store"] != false {
		t.Fatalf("顶层字段不应丢失: %v", body)
	}
	if body["max_completion_tokens"] != float64(128000) {
		t.Fatalf("max_completion_tokens 不应丢失: %v", body["max_completion_tokens"])
	}
}

func TestSanitizeSystemPromptSkipsUnexpectedShapes(t *testing.T) {
	cfg := ProviderConfig{ID: "codebuddy", Options: map[string]string{"sanitize_system_prompt": "true"}}

	cases := map[string]string{
		"首条不是 system": `{"messages":[{"role":"user","content":"` + fingerprint + `"}]}`,
		"system 非纯文本": `{"messages":[{"role":"system","content":[{"type":"text","text":"` + fingerprint + `"}]},{"role":"user","content":"hi"}]}`,
		"没有 messages": `{"model":"m","note":"` + fingerprint + `"}`,
		"空 messages":  `{"messages":[],"note":"` + fingerprint + `"}`,
		"非法 JSON":     `{"messages":`,
	}
	for name, raw := range cases {
		if got := string(sanitizeSystemPrompt([]byte(raw), cfg)); got != raw {
			t.Fatalf("%s: 不应修改请求体\n got: %s", name, got)
		}
	}
}
