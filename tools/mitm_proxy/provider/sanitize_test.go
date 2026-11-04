package provider

import (
	"encoding/json"
	"testing"
)

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
	raw := []byte(`{"model":"m","messages":[{"role":"system","content":"SYS"},{"role":"user","content":"hi"}]}`)
	cfg := ProviderConfig{ID: "codebuddy", Options: map[string]string{"api_path": "/v2/chat/completions"}}

	got := sanitizeSystemPrompt(raw, cfg)
	if string(got) != string(raw) {
		t.Fatalf("未开启开关时不应修改请求体\n got: %s", got)
	}
}

func TestSanitizeSystemPromptMovesSystemIntoUser(t *testing.T) {
	raw := []byte(`{"model":"m","max_tokens":8,"messages":[{"role":"system","content":"SYS\nLINE2"},{"role":"user","content":"hi"},{"role":"assistant","content":"yo"}]}`)
	cfg := ProviderConfig{ID: "codebuddy", Options: map[string]string{"sanitize_system_prompt": "true"}}

	messages := decodeMessages(t, sanitizeSystemPrompt(raw, cfg))
	if len(messages) != 4 {
		t.Fatalf("期望 4 条消息，得到 %d", len(messages))
	}
	if messages[0]["role"] != "system" {
		t.Fatalf("首条仍应是 system")
	}
	if messages[0]["content"] == "SYS\nLINE2" {
		t.Fatalf("system 内容应被替换为中性文案")
	}
	if messages[1]["role"] != "user" || messages[1]["content"] != "SYS\nLINE2" {
		t.Fatalf("原始 system 内容应原样移到第二条 user 消息，得到 %v", messages[1])
	}
	if messages[2]["content"] != "hi" || messages[3]["content"] != "yo" {
		t.Fatalf("其余消息顺序应保持不变")
	}
}

func TestSanitizeSystemPromptKeepsOtherTopLevelFields(t *testing.T) {
	raw := []byte(`{"model":"space-bunny","max_completion_tokens":128000,"store":false,"stream":true,"messages":[{"role":"system","content":"SYS"},{"role":"user","content":"hi"}]}`)
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
		"首条不是 system": `{"messages":[{"role":"user","content":"hi"}]}`,
		"system 非纯文本": `{"messages":[{"role":"system","content":[{"type":"text","text":"SYS"}]},{"role":"user","content":"hi"}]}`,
		"没有 messages": `{"model":"m"}`,
		"空 messages":  `{"messages":[]}`,
		"非法 JSON":    `{"messages":`,
	}
	for name, raw := range cases {
		if got := string(sanitizeSystemPrompt([]byte(raw), cfg)); got != raw {
			t.Fatalf("%s: 不应修改请求体\n got: %s", name, got)
		}
	}
}
