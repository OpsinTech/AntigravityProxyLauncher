package provider

import (
	"encoding/json"
	"log"
)

// bodyBreakdownThreshold 超过这个大小才打印体积构成，避免给每条请求增加日志噪音。
const bodyBreakdownThreshold = 256 << 10

// logBodyBreakdown 在请求体偏大时打印消息 / 工具定义各自的体积占比。
//
// 上游对超长上下文只会回一句 code 11115「prompt is too long: 100001 tokens >
// 100000 maximum」——那个 100001 是 limit+1 的哨兵值，不反映真实 token 数，
// 光看日志无法判断到底是历史消息还是工具 schema 撑爆的。这一行把两者分开，
// 让 11115 的排查不必再靠猜。
func logBodyBreakdown(tag string, body []byte) {
	if len(body) < bodyBreakdownThreshold {
		return
	}

	var parts map[string]json.RawMessage
	if err := json.Unmarshal(body, &parts); err != nil {
		return
	}

	var tools []json.RawMessage
	_ = json.Unmarshal(parts["tools"], &tools)
	var messages []json.RawMessage
	_ = json.Unmarshal(parts["messages"], &messages)

	toolsBytes := len(parts["tools"])
	messagesBytes := len(parts["messages"])
	log.Printf("[OpenAI:%s] body %d KB = messages %d KB (%d 条) + tools %d KB (%d 个) + 其他 %d KB",
		tag,
		len(body)/1024,
		messagesBytes/1024, len(messages),
		toolsBytes/1024, len(tools),
		(len(body)-toolsBytes-messagesBytes)/1024,
	)
}
