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

// OpenAI 新版协议用 developer 取代 system。只处理 system 会让 developer 客户端
// 的提示词原样漏给上游，命中指纹后返回 400 code 11128。
func TestSanitizeSystemPromptHandlesDeveloperRole(t *testing.T) {
	raw := []byte(`{"model":"hy3","messages":[{"role":"developer","content":"You are Codex, a coding agent running in the Codex CLI."},{"role":"user","content":"hi"}]}`)
	cfg := ProviderConfig{ID: "codebuddy", Options: map[string]string{"sanitize_system_prompt": "true"}}

	messages := decodeMessages(t, sanitizeSystemPrompt(raw, cfg))
	if len(messages) != 3 {
		t.Fatalf("期望 3 条消息，得到 %d: %v", len(messages), messages)
	}
	if messages[0]["role"] != "system" {
		t.Fatalf("占位消息必须降级成 system（网关不接受 developer），得到 %v", messages[0]["role"])
	}
	if messages[0]["content"] == "You are Codex, a coding agent running in the Codex CLI." {
		t.Fatalf("developer 内容应被替换为中性文案")
	}
	if messages[1]["role"] != "user" || messages[1]["content"] != "You are Codex, a coding agent running in the Codex CLI." {
		t.Fatalf("原始 developer 内容应原样移到 user 消息，得到 %v", messages[1])
	}
	for i, message := range messages {
		if message["role"] == "developer" {
			t.Fatalf("第 %d 条仍是 developer 角色，网关会直接回 11128", i)
		}
	}
}

// 开头连续出现多条指令消息（system + developer 混用）时，必须全部搬走，
// 否则后面那条仍然带着原始提示词被上游指纹命中。
func TestSanitizeSystemPromptMergesLeadingInstructionMessages(t *testing.T) {
	raw := []byte(`{"messages":[{"role":"system","content":"SYS1"},{"role":"developer","content":"SYS2"},{"role":"user","content":"hi"}]}`)
	cfg := ProviderConfig{ID: "codebuddy", Options: map[string]string{"sanitize_system_prompt": "true"}}

	messages := decodeMessages(t, sanitizeSystemPrompt(raw, cfg))
	if len(messages) != 3 {
		t.Fatalf("期望 3 条消息（1 占位 + 1 搬运 + 原 user），得到 %d: %v", len(messages), messages)
	}
	if messages[0]["role"] != "system" || messages[0]["content"] == "SYS1" {
		t.Fatalf("占位消息应为中性 system，得到 %v", messages[0])
	}
	if messages[1]["content"] != "SYS1\n\nSYS2" {
		t.Fatalf("两条指令内容应按顺序合并进 user，得到 %v", messages[1]["content"])
	}
	if messages[2]["content"] != "hi" {
		t.Fatalf("原始 user 消息应保留，得到 %v", messages[2])
	}
}
