package translator

import (
	"encoding/json"
	"fmt"

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
func (t *OpenAIToOpenAI) TranslateRequest(sourceReq []byte, targetModel string) (*provider.ProviderRequest, error) {
	var oaiReq struct {
		Model    string            `json:"model"`
		Messages []provider.Message `json:"messages"`
		Stream   bool              `json:"stream"`
		Tools    []provider.Tool   `json:"tools,omitempty"`
	}
	if err := json.Unmarshal(sourceReq, &oaiReq); err != nil {
		return nil, fmt.Errorf("failed to parse OpenAI request: %w", err)
	}

	return &provider.ProviderRequest{
		Model:    targetModel,
		Messages: oaiReq.Messages,
		Stream:   oaiReq.Stream,
		Tools:    oaiReq.Tools,
	}, nil
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
		return []byte("data: [DONE]\n\n"), nil
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
