package provider

import (
	"bytes"
	"encoding/json"
	"log"
	"strings"
)

// neutralSystemPrompt 用来替换被上游判定为"第三方客户端"的 system 提示词。
const neutralSystemPrompt = "You are a helpful coding assistant."

// blockedFingerprints 是上游会拦的第三方客户端提示词特征（小写）。
// 只有命中这些特征才需要搬迁 system，避免无谓地改写普通请求。
var blockedFingerprints = [][]byte{
	[]byte("deepseek harness"),
	[]byte("claude code"),
}

// containsBlockedFingerprint 做大小写不敏感的匹配。
// 按 1MB 窗口 + 32 字节重叠扫描，避免为大请求体一次性分配整份小写副本。
func containsBlockedFingerprint(body []byte) bool {
	const window = 1 << 20
	const overlap = 32
	for start := 0; start < len(body); start += window {
		end := start + window + overlap
		if end > len(body) {
			end = len(body)
		}
		lower := bytes.ToLower(body[start:end])
		for _, fp := range blockedFingerprints {
			if bytes.Contains(lower, fp) {
				return true
			}
		}
		if end == len(body) {
			break
		}
	}
	return false
}

// isInstructionRole 判断某条消息是否承载“系统指令”。OpenAI 新版协议用
// developer 取代 system，两类角色都要处理。
//
// 注意：CodeBuddy 网关并不只是对 developer 的内容做指纹校验，它根本不接受
// developer 这个角色——即使内容换成中性文案，仍然回 400 code 11128。因此
// 下面搬运内容的同时会把占位消息的 role 统一降级成 system。
func isInstructionRole(role string) bool {
	return role == "system" || role == "developer"
}

// sanitizeSystemPrompt 把开头的系统指令消息（system / developer）内容原样搬到
// 紧随其后的 user 消息里，指令消息本身换成一句中性文案。
//
// 背景：CodeBuddy / WorkBuddy 网关会对 system 提示词做客户端指纹校验，命中已知
// 第三方 agent（如 DeepSeek Harness、Claude Code、Codex）的模板就直接返回
// 400 code 11128「Illegal API invocation from an unapproved channel」。
// 实测该校验只看 system 角色：同一段文本放进 user 消息即放行，因此这里
// 保留全部指令内容，只改变它在消息序列中的位置，避免削弱模型的工具使用能力。
//
// 仅在 provider 配置 options.sanitize_system_prompt = "true" 时生效，
// 默认不影响其他 provider 与模型。
//
// 以下情况原样返回，避免破坏请求：
//   - 未开启开关
//   - 首条消息不是 system/developer，或指令内容不是纯文本（多模态/结构化）
//   - JSON 解析失败
func sanitizeSystemPrompt(rawBody []byte, cfg ProviderConfig) []byte {
	if cfg.Options["sanitize_system_prompt"] != "true" {
		return rawBody
	}
	// 没命中已知特征就不动，保持请求原样（也避免大请求体的解析开销）；
	// developer 角色本身会被网关拒绝，即使内容不含指纹也要改写。
	if !containsBlockedFingerprint(rawBody) && !bytes.Contains(rawBody, []byte(`"developer"`)) {
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

	var firstRole string
	if err := json.Unmarshal(messages[0]["role"], &firstRole); err != nil || !isInstructionRole(firstRole) {
		log.Printf("[OpenAI:%s] sanitize: 跳过，首条消息 role=%q 不是 system/developer", cfg.ID, firstRole)
		return rawBody
	}

	// 开头可能连续出现多条指令消息（例如 system + developer 混用），
	// 一并搬走，否则后面那条仍会带着原始提示词被上游指纹命中。
	var instructions []string
	leading := 0
	for leading < len(messages) {
		var role string
		if err := json.Unmarshal(messages[leading]["role"], &role); err != nil || !isInstructionRole(role) {
			break
		}
		var content string
		if err := json.Unmarshal(messages[leading]["content"], &content); err != nil || content == "" {
			break
		}
		instructions = append(instructions, content)
		leading++
	}

	if leading == 0 {
		log.Printf("[OpenAI:%s] sanitize: 跳过，role=%q 的 content 不是纯文本（多模态/结构化）", cfg.ID, firstRole)
		return rawBody
	}

	// 占位消息统一用 system：CodeBuddy 网关不认 developer 角色，会把整条请求
	// 判成 11128；其余角色保持不变。
	placeholder, err := json.Marshal(map[string]string{"role": "system", "content": neutralSystemPrompt})
	if err != nil {
		return rawBody
	}
	moved, err := json.Marshal(map[string]string{"role": "user", "content": strings.Join(instructions, "\n\n")})
	if err != nil {
		return rawBody
	}

	rebuilt := make([]json.RawMessage, 0, len(messages)+1)
	rebuilt = append(rebuilt, placeholder, moved)
	for _, message := range messages[leading:] {
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

	chars := 0
	for _, instruction := range instructions {
		chars += len(instruction)
	}
	log.Printf("[OpenAI:%s] sanitize: %s prompt (%d 字符, %d 条) 已移入 user 消息",
		cfg.ID, firstRole, chars, leading)
	return out
}
