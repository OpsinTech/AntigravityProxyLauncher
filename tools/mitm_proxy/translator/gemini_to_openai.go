package translator

import (
	"encoding/json"
	"fmt"
	"log"
	"strings"

	"github.com/KevinLiangX/AntigravityProxyLauncher/mitm_proxy/provider"
)

// GeminiToOpenAI translates Gemini API format to OpenAI format
type GeminiToOpenAI struct{}

// NewGeminiToOpenAI creates a new Gemini to OpenAI translator
func NewGeminiToOpenAI() *GeminiToOpenAI {
	return &GeminiToOpenAI{}
}

func (t *GeminiToOpenAI) SourceFormat() string {
	return "gemini"
}

func (t *GeminiToOpenAI) TargetFormat() string {
	return "openai"
}

func (t *GeminiToOpenAI) CanTranslate(source, target string) bool {
	return source == "gemini" && target == "openai"
}

// GeminiRequest represents a Gemini API request
type GeminiRequest struct {
	Model             string                 `json:"model,omitempty"`
	Contents          []GeminiContent        `json:"contents"`
	SystemInstruction *GeminiInstruction     `json:"systemInstruction,omitempty"`
	GenerationConfig  map[string]interface{} `json:"generationConfig,omitempty"`
	Tools             []GeminiTool           `json:"tools,omitempty"`
}

// GeminiContent represents content in a Gemini request
type GeminiContent struct {
	Role  string       `json:"role"`
	Parts []GeminiPart `json:"parts"`
}

// GeminiInstruction represents system instruction
type GeminiInstruction struct {
	Parts []GeminiPart `json:"parts"`
}

// GeminiPart represents a part in Gemini content
type GeminiPart struct {
	Text             string                 `json:"text,omitempty"`
	FunctionCall     *GeminiFunctionCall    `json:"functionCall,omitempty"`
	FunctionResponse *GeminiFunctionResponse `json:"functionResponse,omitempty"`
}

// GeminiFunctionCall represents a function call in Gemini
type GeminiFunctionCall struct {
	Name string                 `json:"name"`
	Args map[string]interface{} `json:"args"`
}

// GeminiFunctionResponse represents a function response in Gemini
type GeminiFunctionResponse struct {
	Name     string      `json:"name"`
	Response interface{} `json:"response"`
}

// GeminiTool represents a tool in Gemini
type GeminiTool struct {
	FunctionDeclarations []GeminiFunctionDeclaration `json:"functionDeclarations"`
}

// GeminiFunctionDeclaration represents a function declaration in Gemini
type GeminiFunctionDeclaration struct {
	Name        string                 `json:"name"`
	Description string                 `json:"description,omitempty"`
	Parameters  map[string]interface{} `json:"parameters,omitempty"`
}

// AntigravityWrappedRequest represents the wrapped format used by Google Cloud Code API
type AntigravityWrappedRequest struct {
	Project     string                 `json:"project"`
	Model       string                 `json:"model"`
	UserAgent   string                 `json:"userAgent,omitempty"`
	RequestType string                 `json:"requestType,omitempty"`
	RequestId   string                 `json:"requestId,omitempty"`
	Request     map[string]interface{} `json:"request"`
}

func (t *GeminiToOpenAI) TranslateRequest(sourceReq []byte, targetModel string) (*provider.ProviderRequest, error) {
	var geminiReq GeminiRequest

	// Try direct Gemini format first
	if err := json.Unmarshal(sourceReq, &geminiReq); err != nil || len(geminiReq.Contents) == 0 {
		// Try Antigravity wrapped format
		var wrapped AntigravityWrappedRequest
		if err := json.Unmarshal(sourceReq, &wrapped); err == nil && wrapped.Request != nil {
			innerBytes, _ := json.Marshal(wrapped.Request)
			json.Unmarshal(innerBytes, &geminiReq)
		}
	}

	if len(geminiReq.Contents) == 0 {
		return nil, fmt.Errorf("failed to parse Gemini request: no contents")
	}

	req := &provider.ProviderRequest{
		Model:  targetModel,
		Stream: true,
	}

	// Convert system instruction
	if geminiReq.SystemInstruction != nil {
		sysStr := ""
		for _, part := range geminiReq.SystemInstruction.Parts {
			sysStr += part.Text
		}
		if sysStr != "" {
			req.Messages = append(req.Messages, provider.Message{
				Role:    "system",
				Content: sysStr,
			})
		}
	}

	// Convert tool definitions
	for _, tool := range geminiReq.Tools {
		for _, fd := range tool.FunctionDeclarations {
			req.Tools = append(req.Tools, provider.Tool{
				Type: "function",
				Function: provider.FunctionDef{
					Name:        fd.Name,
					Description: fd.Description,
					Parameters:  normalizeToolSchema(fd.Parameters),
				},
			})
		}
	}

	// Convert contents/messages
	funcCallCounters := make(map[string]int)
	var funcCallQueues []string

	for _, content := range geminiReq.Contents {
		role := content.Role
		if role == "model" {
			role = "assistant"
		}

		oMsg := provider.Message{Role: role}
		var toolResults []provider.Message

		// First pass: collect functionCall IDs
		for _, part := range content.Parts {
			if part.FunctionCall != nil {
				funcCallCounters[part.FunctionCall.Name]++
				callID := fmt.Sprintf("%s_%d", part.FunctionCall.Name, funcCallCounters[part.FunctionCall.Name])
				funcCallQueues = append(funcCallQueues, callID)
			}
		}

		// Second pass: build messages with matching IDs
		callIdx := 0
		for _, part := range content.Parts {
			if part.Text != "" {
				oMsg.Content += part.Text
			}
			if part.FunctionCall != nil {
				callID := funcCallQueues[callIdx]
				callIdx++
				argsBytes, _ := json.Marshal(part.FunctionCall.Args)
				oMsg.ToolCalls = append(oMsg.ToolCalls, provider.ToolCall{
					Id:   callID,
					Type: "function",
					Function: provider.ToolFunction{
						Name:      part.FunctionCall.Name,
						Arguments: string(argsBytes),
					},
				})
			}
			if part.FunctionResponse != nil {
				var matchedID string
				for i, cid := range funcCallQueues {
					if strings.HasPrefix(cid, part.FunctionResponse.Name+"_") {
						matchedID = cid
						funcCallQueues = append(funcCallQueues[:i], funcCallQueues[i+1:]...)
						break
					}
				}
				if matchedID == "" {
					matchedID = fmt.Sprintf("%s_response", part.FunctionResponse.Name)
				}
				respStr := ""
				switch v := part.FunctionResponse.Response.(type) {
				case string:
					respStr = v
				default:
					b, _ := json.Marshal(v)
					respStr = string(b)
				}
				toolResults = append(toolResults, provider.Message{
					Role:       "tool",
					ToolCallId: matchedID,
					Content:    respStr,
				})
			}
		}

		if oMsg.Content != "" || len(oMsg.ToolCalls) > 0 {
			req.Messages = append(req.Messages, oMsg)
		}
		req.Messages = append(req.Messages, toolResults...)
	}

	log.Printf("[Translator] Translated Gemini request: Model=%s, ToolsCount=%d", req.Model, len(req.Tools))
	return req, nil
}

func (t *GeminiToOpenAI) TranslateResponse(resp *provider.ProviderResponse, sourceModel string) ([]byte, error) {
	// Gemini response format
	geminiResp := map[string]interface{}{
		"candidates": []map[string]interface{}{
			{
				"content": map[string]interface{}{
					"parts": []map[string]interface{}{
						{"text": resp.Content},
					},
					"role": "model",
				},
				"index": 0,
			},
		},
	}

	return json.Marshal(geminiResp)
}

func (t *GeminiToOpenAI) TranslateStreamChunk(chunk *provider.StreamChunk, sourceModel string, state *StreamState) ([]byte, error) {
	// Handle tool calls: silently accumulate args until Done.
	// Emitting early with incomplete args confuses the IDE's stream handler
	// and triggers premature tool validation (e.g. "AbsolutePath is required").
	if len(chunk.ToolCalls) > 0 {
		for _, tc := range chunk.ToolCalls {
			if tc.Id != "" {
				state.FunctionCallName = tc.Function.Name
				state.FunctionCallArgs = tc.Function.Arguments
				state.HasFunctionCall = true
			} else if tc.Function.Arguments != "" {
				state.FunctionCallArgs += tc.Function.Arguments
			}
		}
		return nil, nil
	}

	if chunk.Delta != "" {
		state.FullText += chunk.Delta

		event := map[string]interface{}{
			"response": map[string]interface{}{
				"candidates": []interface{}{
					map[string]interface{}{
						"content": map[string]interface{}{
							"parts": []map[string]interface{}{
								{"text": chunk.Delta},
							},
							"role": "model",
						},
						"index": 0,
					},
				},
			},
		}
		eb, _ := json.Marshal(event)
		return []byte("data: " + string(eb) + "\n\n"), nil
	}

	if chunk.Done {
		finishReason := "STOP"

		// Only include functionCall if present; never include accumulated text
		// (the IDE already has it from delta chunks).
		parts := make([]map[string]interface{}, 0, 1)
		if state.HasFunctionCall {
			var args interface{}
			if state.FunctionCallArgs != "" {
				json.Unmarshal([]byte(state.FunctionCallArgs), &args)
			}
			if args == nil {
				args = map[string]interface{}{}
			}
			log.Printf("[Translator] Gemini functionCall final: name=%s, args=%v", state.FunctionCallName, args)
			parts = append(parts, map[string]interface{}{
				"functionCall": map[string]interface{}{
					"name": state.FunctionCallName,
					"args": args,
				},
			})
		}

		event := map[string]interface{}{
			"response": map[string]interface{}{
				"candidates": []interface{}{
					map[string]interface{}{
						"content": map[string]interface{}{
							"parts": parts,
							"role":  "model",
						},
						"index":        0,
						"finishReason": finishReason,
					},
				},
				"usageMetadata": map[string]interface{}{
					"promptTokenCount":     state.PromptTokens,
					"candidatesTokenCount": state.CompletionTokens,
					"totalTokenCount":      state.PromptTokens + state.CompletionTokens,
				},
			},
		}
		eb, _ := json.Marshal(event)
		return []byte("data: " + string(eb) + "\n\n"), nil
	}

	return nil, nil
}


// normalizeToolSchema converts Gemini-style types to JSON Schema types
func normalizeToolSchema(schema map[string]interface{}) map[string]interface{} {
	if schema == nil {
		return map[string]interface{}{"type": "object", "properties": map[string]interface{}{}}
	}
	result := make(map[string]interface{})
	for k, v := range schema {
		if k == "type" {
			if s, ok := v.(string); ok {
				switch s {
				case "STRING":
					result[k] = "string"
				case "NUMBER":
					result[k] = "number"
				case "INTEGER":
					result[k] = "integer"
				case "BOOLEAN":
					result[k] = "boolean"
				case "OBJECT":
					result[k] = "object"
				case "ARRAY":
					result[k] = "array"
				default:
					result[k] = v
				}
			} else {
				result[k] = v
			}
		} else if k == "properties" || k == "additionalProperties" {
			if props, ok := v.(map[string]interface{}); ok {
				normalized := make(map[string]interface{})
				for pk, pv := range props {
					if m, ok := pv.(map[string]interface{}); ok {
						normalized[pk] = normalizeToolSchema(m)
					} else {
						normalized[pk] = pv
					}
				}
				result[k] = normalized
			} else {
				result[k] = v
			}
		} else if k == "items" {
			if m, ok := v.(map[string]interface{}); ok {
				result[k] = normalizeToolSchema(m)
			} else if arr, ok := v.([]interface{}); ok {
				normalized := make([]interface{}, len(arr))
				for i, item := range arr {
					if m, ok := item.(map[string]interface{}); ok {
						normalized[i] = normalizeToolSchema(m)
					} else {
						normalized[i] = item
					}
				}
				result[k] = normalized
			} else {
				result[k] = v
			}
		} else if k == "anyOf" || k == "oneOf" || k == "allOf" {
			if arr, ok := v.([]interface{}); ok {
				normalized := make([]interface{}, len(arr))
				for i, item := range arr {
					if m, ok := item.(map[string]interface{}); ok {
						normalized[i] = normalizeToolSchema(m)
					} else {
						normalized[i] = item
					}
				}
				result[k] = normalized
			} else {
				result[k] = v
			}
		} else if k == "$defs" {
			if defs, ok := v.(map[string]interface{}); ok {
				normalized := make(map[string]interface{})
				for dk, dv := range defs {
					if m, ok := dv.(map[string]interface{}); ok {
						normalized[dk] = normalizeToolSchema(m)
					} else {
						normalized[dk] = dv
					}
				}
				result[k] = normalized
			} else {
				result[k] = v
			}
		} else {
			result[k] = v
		}
	}
	return result
}

// RegisterGeminiToOpenAI registers the translator with the registry
func RegisterGeminiToOpenAI(registry *Registry) {
	registry.Register(NewGeminiToOpenAI())
}

// IsGeminiModel checks if a model name looks like a Gemini model
func IsGeminiModel(model string) bool {
	modelLower := strings.ToLower(model)
	return strings.HasPrefix(modelLower, "gemini-") ||
		strings.Contains(modelLower, "google")
}
