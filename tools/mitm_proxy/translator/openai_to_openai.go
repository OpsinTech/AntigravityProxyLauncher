package translator

import (
	"encoding/json"
	"fmt"
	"strings"

	"github.com/KevinLiangX/AntigravityProxyLauncher/mitm_proxy/provider"
)

// OpenAIToOpenAI translates between OpenAI-format APIs.
// This handles both passthrough (same format) and model name substitution.
type OpenAIToOpenAI struct{}

// RegisterOpenAIToOpenAI registers the OpenAI→OpenAI translator.
func RegisterOpenAIToOpenAI(registry *Registry) {
	registry.Register(&OpenAIToOpenAI{})
}

func (t *OpenAIToOpenAI) SourceFormat() string { return "openai" }

func (t *OpenAIToOpenAI) TargetFormat() string { return "openai" }

func (t *OpenAIToOpenAI) CanTranslate(source, target string) bool {
	return source == "openai" && target == "openai"
}

// TranslateRequest converts an OpenAI-format request body to a ProviderRequest,
// substituting the target model name.
// For same-format (OpenAI→OpenAI) passthrough, preserves the original request body
// structure including content format, tool definitions, and other fields — only the
// model name is replaced. This avoids data loss from stripping multimodal content
// arrays or discarding unknown fields.
func (t *OpenAIToOpenAI) TranslateRequest(sourceReq []byte, targetModel string) (*provider.ProviderRequest, error) {
	// For same-format passthrough, preserve the raw request body.
	// Only substitute the model name; everything else passes through as-is.
	// Use a generic map to preserve all fields, then marshal back.
	var rawReq map[string]interface{}
	if err := json.Unmarshal(sourceReq, &rawReq); err != nil {
		return nil, fmt.Errorf("failed to parse OpenAI request: %w", err)
	}

	// Extract messages for the ProviderRequest (needed for LLMRouter keyword matching)
	messages := extractMessagesForRouting(rawReq)

	// Extract tools
	var tools []provider.Tool
	if rawTools, ok := rawReq["tools"]; ok {
		toolsBytes, _ := json.Marshal(rawTools)
		json.Unmarshal(toolsBytes, &tools)
	}

	// Extract stream flag
	stream := false
	if s, ok := rawReq["stream"]; ok {
		if b, ok := s.(bool); ok {
			stream = b
		}
	}

	// Build the raw body with model name substituted for same-format passthrough.
	// This preserves all original fields (temperature, max_tokens, etc.)
	// and content format (string vs array) that would be lost in struct marshaling.
	rawReq["model"] = targetModel
	rawBody, err := json.Marshal(rawReq)
	if err != nil {
		return nil, fmt.Errorf("failed to marshal passthrough request: %w", err)
	}

	return &provider.ProviderRequest{
		Model:    targetModel,
		Messages: messages,
		Stream:   stream,
		Tools:    tools,
		RawBody:  rawBody,
	}, nil
}

// extractMessagesForRouting extracts simplified messages from the raw request
// for use by LLMRouter keyword matching. Only needs Role and text Content.
func extractMessagesForRouting(rawReq map[string]interface{}) []provider.Message {
	rawMsgs, ok := rawReq["messages"]
	if !ok {
		return nil
	}
	msgList, ok := rawMsgs.([]interface{})
	if !ok {
		return nil
	}

	messages := make([]provider.Message, 0, len(msgList))
	for _, rawMsg := range msgList {
		msgMap, ok := rawMsg.(map[string]interface{})
		if !ok {
			continue
		}
		role, _ := msgMap["role"].(string)
		content := extractContentFromRaw(msgMap["content"])
		messages = append(messages, provider.Message{
			Role:    role,
			Content: content,
		})
	}
	return messages
}

// extractContentFromRaw extracts text from a raw content field (string or array).
func extractContentFromRaw(content interface{}) string {
	if content == nil {
		return ""
	}
	// String content
	if s, ok := content.(string); ok {
		return s
	}
	// Array content: [{"type":"text","text":"..."}, ...]
	if arr, ok := content.([]interface{}); ok {
		var texts []string
		for _, item := range arr {
			if itemMap, ok := item.(map[string]interface{}); ok {
				if t, _ := itemMap["type"].(string); t == "text" {
					if text, _ := itemMap["text"].(string); text != "" {
						texts = append(texts, text)
					}
				}
			}
		}
		return strings.Join(texts, "")
	}
	return ""
}

// extractContentText converts a content field that may be a plain string
// or an array of content parts (multimodal format) into a plain string.
func extractContentText(raw json.RawMessage) string {
	if len(raw) == 0 {
		return ""
	}

	// Try plain string first
	var str string
	if json.Unmarshal(raw, &str) == nil {
		return str
	}

	// Try array format: [{"type":"text","text":"..."}, ...]
	var parts []struct {
		Type string `json:"type"`
		Text string `json:"text"`
	}
	if json.Unmarshal(raw, &parts) != nil {
		// Neither format matched, return raw as fallback
		return string(raw)
	}

	var texts []string
	for _, p := range parts {
		if p.Type == "text" && p.Text != "" {
			texts = append(texts, p.Text)
		}
	}
	return strings.Join(texts, "")
}

// TranslateResponse converts a ProviderResponse back to OpenAI-format JSON,
// using the source model name in the response.
func (t *OpenAIToOpenAI) TranslateResponse(resp *provider.ProviderResponse, sourceModel string) ([]byte, error) {
	oaiResp := map[string]interface{}{
		"id":      "chatcmpl-" + sourceModel,
		"object":  "chat.completion",
		"model":   sourceModel,
		"choices": []map[string]interface{}{
			{
				"index": 0,
				"message": map[string]interface{}{
					"role":    "assistant",
					"content": resp.Content,
				},
				"finish_reason": "stop",
			},
		},
		"usage": map[string]interface{}{
			"prompt_tokens":     resp.Usage.PromptTokens,
			"completion_tokens": resp.Usage.CompletionTokens,
			"total_tokens":      resp.Usage.TotalTokens,
		},
	}

	if len(resp.ToolCalls) > 0 {
		choice := oaiResp["choices"].([]map[string]interface{})[0]
		choice["message"].(map[string]interface{})["tool_calls"] = resp.ToolCalls
	}

	return json.Marshal(oaiResp)
}

// TranslateStreamChunk converts a Provider StreamChunk to OpenAI SSE format,
// using the source model name.
func (t *OpenAIToOpenAI) TranslateStreamChunk(chunk *provider.StreamChunk, sourceModel string, state *StreamState) ([]byte, error) {
	if chunk.Done {
		// OpenAI's streaming protocol terminates with a chunk carrying a
		// non-empty finish_reason before [DONE]. Strict clients (e.g. pi-ai)
		// treat a stream that ends without one as truncated, so always emit
		// the terminal chunk first. Echo the upstream finish_reason when the
		// provider sent one (stop/tool_calls/length); default to "stop" for
		// upstreams that end with bare [DONE].
		finishReason := chunk.FinishReason
		if finishReason == "" {
			finishReason = "stop"
		}
		oaiChunk := map[string]interface{}{
			"id":      "chatcmpl-" + sourceModel,
			"object":  "chat.completion.chunk",
			"model":   sourceModel,
			"choices": []map[string]interface{}{
				{
					"index":         0,
					"delta":         map[string]interface{}{},
					"finish_reason": finishReason,
				},
			},
		}
		data, err := json.Marshal(oaiChunk)
		if err != nil {
			return nil, fmt.Errorf("failed to marshal terminal SSE chunk: %w", err)
		}
		events := append([]byte("data: "), append(data, '\n', '\n')...)
		return append(events, []byte("data: [DONE]\n\n")...), nil
	}

	if chunk.Error != nil {
		return nil, chunk.Error
	}

	// Build standard OpenAI SSE chunk
	oaiChunk := map[string]interface{}{
		"id":      "chatcmpl-" + sourceModel,
		"object":  "chat.completion.chunk",
		"model":   sourceModel,
		"choices": []map[string]interface{}{
			{
				"index": 0,
				"delta": map[string]interface{}{
					"content": chunk.Delta,
				},
				"finish_reason": nil,
			},
		},
	}

	if len(chunk.ToolCalls) > 0 {
		choice := oaiChunk["choices"].([]map[string]interface{})[0]
		choice["delta"].(map[string]interface{})["tool_calls"] = chunk.ToolCalls
	}

	if chunk.Usage != nil {
		oaiChunk["usage"] = chunk.Usage
	}

	data, err := json.Marshal(oaiChunk)
	if err != nil {
		return nil, fmt.Errorf("failed to marshal SSE chunk: %w", err)
	}

	return append([]byte("data: "), append(data, '\n', '\n')...), nil
}
