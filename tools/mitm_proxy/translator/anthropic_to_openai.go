package translator

import (
	"encoding/json"
	"fmt"
	"log"
	"strings"

	"github.com/KevinLiangX/AntigravityProxyLauncher/mitm_proxy/provider"
)

// AnthropicToOpenAI translates Anthropic API format to OpenAI format
type AnthropicToOpenAI struct{}

// NewAnthropicToOpenAI creates a new Anthropic to OpenAI translator
func NewAnthropicToOpenAI() *AnthropicToOpenAI {
	return &AnthropicToOpenAI{}
}

func (t *AnthropicToOpenAI) SourceFormat() string {
	return "anthropic"
}

func (t *AnthropicToOpenAI) TargetFormat() string {
	return "openai"
}

func (t *AnthropicToOpenAI) CanTranslate(source, target string) bool {
	return source == "anthropic" && target == "openai"
}

// AnthropicRequest represents an Anthropic API request
type AnthropicRequest struct {
	Model     string             `json:"model"`
	Messages  []AnthropicMessage `json:"messages"`
	System    interface{}        `json:"system,omitempty"`
	Tools     []AnthropicTool    `json:"tools,omitempty"`
	Stream    bool               `json:"stream,omitempty"`
	MaxTokens int                `json:"max_tokens,omitempty"`
}

// AnthropicMessage represents an Anthropic message.
// Content can be a string or []interface{} — we handle both.
type AnthropicMessage struct {
	Role    string          `json:"role"`
	Content json.RawMessage `json:"content"`
}

func (m *AnthropicMessage) ContentAsArray() []interface{} {
	if len(m.Content) == 0 {
		return nil
	}
	// Try as array first
	var arr []interface{}
	if json.Unmarshal(m.Content, &arr) == nil {
		return arr
	}
	// Try as string, wrap in text block
	var str string
	if json.Unmarshal(m.Content, &str) == nil {
		return []interface{}{
			map[string]interface{}{"type": "text", "text": str},
		}
	}
	return nil
}

// AnthropicTool represents an Anthropic tool
type AnthropicTool struct {
	Name        string                 `json:"name"`
	Description string                 `json:"description,omitempty"`
	InputSchema map[string]interface{} `json:"input_schema"`
}

func (t *AnthropicToOpenAI) TranslateRequest(sourceReq []byte, targetModel string) (*provider.ProviderRequest, error) {
	var anthReq AnthropicRequest
	if err := json.Unmarshal(sourceReq, &anthReq); err != nil {
		return nil, fmt.Errorf("failed to parse Anthropic request: %w", err)
	}

	req := &provider.ProviderRequest{
		Model:  targetModel,
		Stream: anthReq.Stream,
	}

	// Map system prompt
	if anthReq.System != nil {
		sysStr := ""
		switch v := anthReq.System.(type) {
		case string:
			sysStr = v
		case []interface{}:
			for _, block := range v {
				if bm, ok := block.(map[string]interface{}); ok {
					if text, ok := bm["text"].(string); ok {
						sysStr += text + "\n"
					}
				}
			}
		}
		if sysStr != "" {
			req.Messages = append(req.Messages, provider.Message{
				Role:    "system",
				Content: sysStr,
			})
		}
	}

	// Map tools
	for _, tool := range anthReq.Tools {
		req.Tools = append(req.Tools, provider.Tool{
			Type: "function",
			Function: provider.FunctionDef{
				Name:        tool.Name,
				Description: tool.Description,
				Parameters:  tool.InputSchema,
			},
		})
	}

	// Map messages
	for _, m := range anthReq.Messages {
		oMsg := provider.Message{Role: m.Role}
		var textContent string

		for _, rawBlock := range m.ContentAsArray() {
			block, ok := rawBlock.(map[string]interface{})
			if !ok {
				if strBlock, ok := rawBlock.(string); ok {
					textContent += strBlock
				}
				continue
			}

			bType, _ := block["type"].(string)
			switch bType {
			case "text":
				if t, ok := block["text"].(string); ok {
					textContent += t
				}
			case "tool_use":
				id, _ := block["id"].(string)
				name, _ := block["name"].(string)
				input, _ := block["input"].(map[string]interface{})
				inputBytes, _ := json.Marshal(input)
				oMsg.ToolCalls = append(oMsg.ToolCalls, provider.ToolCall{
					Id:   id,
					Type: "function",
					Function: provider.ToolFunction{
						Name:      name,
						Arguments: string(inputBytes),
					},
				})
			case "tool_result":
				toolUseId, _ := block["tool_use_id"].(string)
				contentStr := extractToolResultContent(block)

				// Push the previous message if it has content
				if textContent != "" || len(oMsg.ToolCalls) > 0 {
					oMsg.Content = textContent
					req.Messages = append(req.Messages, oMsg)
					oMsg = provider.Message{Role: m.Role}
					textContent = ""
				}

				req.Messages = append(req.Messages, provider.Message{
					Role:       "tool",
					ToolCallId: toolUseId,
					Content:    contentStr,
				})
			}
		}

		// Append remaining
		if textContent != "" || len(oMsg.ToolCalls) > 0 {
			oMsg.Content = textContent
			req.Messages = append(req.Messages, oMsg)
		}
	}

	log.Printf("[Translator] Translated Anthropic request: Model=%s, ToolsCount=%d", req.Model, len(req.Tools))
	return req, nil
}

func (t *AnthropicToOpenAI) TranslateResponse(resp *provider.ProviderResponse, sourceModel string) ([]byte, error) {
	// Anthropic non-streaming response format
	anthResp := map[string]interface{}{
		"id":   "msg_123",
		"type": "message",
		"role": "assistant",
		"content": []map[string]interface{}{
			{
				"type": "text",
				"text": resp.Content,
			},
		},
		"model":       sourceModel,
		"stop_reason": "end_turn",
	}

	// Add tool calls if present
	if len(resp.ToolCalls) > 0 {
		content := anthResp["content"].([]map[string]interface{})
		for _, tc := range resp.ToolCalls {
			var input map[string]interface{}
			json.Unmarshal([]byte(tc.Function.Arguments), &input)
			content = append(content, map[string]interface{}{
				"type":  "tool_use",
				"id":    tc.Id,
				"name":  tc.Function.Name,
				"input": input,
			})
		}
		anthResp["content"] = content
	}

	return json.Marshal(anthResp)
}

func (t *AnthropicToOpenAI) TranslateStreamChunk(chunk *provider.StreamChunk, sourceModel string, state *StreamState) ([]byte, error) {
	var events []byte

	// Handle tool calls
	if len(chunk.ToolCalls) > 0 {
		// Close text content block before starting tool_use blocks
		if state.TextBlockStarted && state.ToolCallID == "" {
			events = append(events, []byte("event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n")...)
		}

		for _, tc := range chunk.ToolCalls {
			idx := state.ToolCallIndex
			if tc.Id != "" {
				state.ToolCallID = tc.Id
				event := map[string]interface{}{
					"type":  "content_block_start",
					"index": idx,
					"content_block": map[string]interface{}{
						"type":  "tool_use",
						"id":    tc.Id,
						"name":  tc.Function.Name,
						"input": map[string]interface{}{},
					},
				}
				eb, _ := json.Marshal(event)
				events = append(events, []byte("event: content_block_start\ndata: ")...)
				events = append(events, eb...)
				events = append(events, []byte("\n\n")...)
				state.ToolCallIndex++
			}
			if tc.Function.Arguments != "" {
				event := map[string]interface{}{
					"type":  "content_block_delta",
					"index": idx,
					"delta": map[string]interface{}{
						"type":         "input_json_delta",
						"partial_json": tc.Function.Arguments,
					},
				}
				eb, _ := json.Marshal(event)
				events = append(events, []byte("event: content_block_delta\ndata: ")...)
				events = append(events, eb...)
				events = append(events, []byte("\n\n")...)
			}
		}
		return events, nil
	}

	// Handle text content
	if chunk.Delta != "" {
		if !state.TextBlockStarted {
			state.TextBlockStarted = true
			startEvent := map[string]interface{}{
				"type":  "content_block_start",
				"index": 0,
				"content_block": map[string]interface{}{
					"type": "text",
					"text": "",
				},
			}
			se, _ := json.Marshal(startEvent)
			events = append(events, []byte("event: content_block_start\ndata: ")...)
			events = append(events, se...)
			events = append(events, []byte("\n\n")...)
		}

		event := map[string]interface{}{
			"type":  "content_block_delta",
			"index": 0,
			"delta": map[string]interface{}{
				"type": "text_delta",
				"text": chunk.Delta,
			},
		}
		eb, _ := json.Marshal(event)
		events = append(events, []byte("event: content_block_delta\ndata: ")...)
		events = append(events, eb...)
		events = append(events, []byte("\n\n")...)
	}

	// Handle done
	if chunk.Done {
		if state.ToolCallID != "" || state.TextBlockStarted {
			events = append(events, []byte("event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n")...)
		}
		// Send message_delta with usage before message_stop
		deltaEvent := map[string]interface{}{
			"type": "message_delta",
			"delta": map[string]interface{}{
				"stop_reason": "end_turn",
			},
			"usage": map[string]interface{}{
				"output_tokens": state.CompletionTokens,
			},
		}
		de, _ := json.Marshal(deltaEvent)
		events = append(events, []byte("event: message_delta\ndata: ")...)
		events = append(events, de...)
		events = append(events, []byte("\n\n")...)

		events = append(events, []byte("event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n")...)
	}

	return events, nil
}

func extractToolResultContent(block map[string]interface{}) string {
	contentStr := ""
	if content, ok := block["content"].(string); ok {
		contentStr = content
	} else if contentArr, ok := block["content"].([]interface{}); ok {
		for _, ca := range contentArr {
			if cam, ok := ca.(map[string]interface{}); ok {
				if t, ok := cam["text"].(string); ok {
					contentStr += t
				}
			}
		}
	}
	return contentStr
}

// RegisterAnthropicToOpenAI registers the translator with the registry
func RegisterAnthropicToOpenAI(registry *Registry) {
	registry.Register(NewAnthropicToOpenAI())
}

// IsAnthropicModel checks if a model name looks like an Anthropic model
func IsAnthropicModel(model string) bool {
	modelLower := strings.ToLower(model)
	return strings.HasPrefix(modelLower, "claude-") ||
		strings.Contains(modelLower, "anthropic")
}
