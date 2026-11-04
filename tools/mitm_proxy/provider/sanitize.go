package provider

import (
	"encoding/json"
	"log"
)

// neutralSystemPrompt 用来替换被上游判定为"第三方客户端"的 system 提示词。
const neutralSystemPrompt = "You are a helpful coding assistant."

// sanitizeSystemPrompt 把 system 消息的内容原样搬到紧随其后的 user 消息里，
// system 本身换成一句中性文案。
//
// 背景：CodeBuddy / WorkBuddy 网关会对 system 提示词做客户端指纹校验，命中已知
// 第三方 agent（如 DeepSeek Harness、Claude Code）的模板就直接返回
// 400 code 11128「Illegal API invocation from an unapproved channel」。
// 实测该校验只看 system 角色：同一段文本放进 user 消息即放行，因此这里
// 保留全部指令内容，只改变它在消息序列中的位置，避免削弱模型的工具使用能力。
//
// 仅在 provider 配置 options.sanitize_system_prompt = "true" 时生效，
// 默认不影响其他 provider 与模型。
//
// 以下情况原样返回，避免破坏请求：
//   - 未开启开关
//   - 首条消息不是 system，或 system 内容不是纯文本（多模态/结构化）
//   - JSON 解析失败
func sanitizeSystemPrompt(rawBody []byte, cfg ProviderConfig) []byte {
	if cfg.Options["sanitize_system_prompt"] != "true" {
		return rawBody
	}

	var body map[string]json.RawMessage
	if err := json.Unmarshal(rawBody, &body); err != nil {
		return rawBody
	}

	rawMessages, ok := body["messages"]
	if !ok {
		return rawBody
	}
	var messages []map[string]json.RawMessage
	if err := json.Unmarshal(rawMessages, &messages); err != nil || len(messages) == 0 {
		return rawBody
	}

	var role string
	if err := json.Unmarshal(messages[0]["role"], &role); err != nil || role != "system" {
		return rawBody
	}

	var content string
	if err := json.Unmarshal(messages[0]["content"], &content); err != nil || content == "" {
		return rawBody
	}

	newSystem, err := json.Marshal(map[string]string{"role": "system", "content": neutralSystemPrompt})
	if err != nil {
		return rawBody
	}
	moved, err := json.Marshal(map[string]string{"role": "user", "content": content})
	if err != nil {
		return rawBody
	}

	rebuilt := make([]json.RawMessage, 0, len(messages)+1)
	rebuilt = append(rebuilt, newSystem, moved)
	for _, message := range messages[1:] {
		encoded, err := json.Marshal(message)
		if err != nil {
			return rawBody
		}
		rebuilt = append(rebuilt, encoded)
	}

	encodedMessages, err := json.Marshal(rebuilt)
	if err != nil {
		return rawBody
	}
	body["messages"] = encodedMessages

	out, err := json.Marshal(body)
	if err != nil {
		return rawBody
	}

	log.Printf("[OpenAI:%s] sanitize: system prompt (%d 字符) 已移入 user 消息", cfg.ID, len(content))
	return out
}
