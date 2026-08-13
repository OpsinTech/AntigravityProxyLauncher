package config

import (
	"encoding/json"
	"strings"
)

// ExtractTextContent extracts all text content from an API request body
// for keyword matching. format must be "anthropic", "gemini", or "openai".
func ExtractTextContent(body []byte, format string) string {
	switch format {
	case "anthropic":
		return extractAnthropicContent(body)
	case "gemini":
		return extractGeminiContent(body)
	default:
		return extractOpenAIContent(body)
	}
}

// ExtractLatestUserContent extracts text from ONLY the most recent user message
// of an API request body, for keyword matching. This avoids false keyword
// triggers caused by historical conversation context (e.g. a past message that
// mentioned "CSS" or "前端" causing all future requests to route to hy3).
// format must be "anthropic", "gemini", or "openai".
func ExtractLatestUserContent(body []byte, format string) string {
	switch format {
	case "anthropic":
		return extractLatestAnthropicUserContent(body)
	case "gemini":
		return extractLatestGeminiUserContent(body)
	default:
		return extractLatestOpenAIUserContent(body)
	}
}

// extractLatestOpenAIUserContent returns the content of the last user message.
func extractLatestOpenAIUserContent(body []byte) string {
	var req struct {
		Messages []struct {
			Role    string          `json:"role"`
			Content json.RawMessage `json:"content"`
		} `json:"messages"`
	}
	if err := json.Unmarshal(body, &req); err != nil {
		return ""
	}
	for i := len(req.Messages) - 1; i >= 0; i-- {
		if req.Messages[i].Role == "user" {
			return extractContentString(req.Messages[i].Content)
		}
	}
	return ""
}

// extractLatestAnthropicUserContent returns the content of the last user message.
func extractLatestAnthropicUserContent(body []byte) string {
	var req struct {
		Messages []struct {
			Role    string          `json:"role"`
			Content json.RawMessage `json:"content"`
		} `json:"messages"`
	}
	if err := json.Unmarshal(body, &req); err != nil {
		return ""
	}
	for i := len(req.Messages) - 1; i >= 0; i-- {
		if req.Messages[i].Role == "user" {
			return extractContentString(req.Messages[i].Content)
		}
	}
	return ""
}

// extractLatestGeminiUserContent returns the text of the last user-turned content.
// Gemini uses "user" role in contents[]; systemInstruction is ignored.
func extractLatestGeminiUserContent(body []byte) string {
	var req struct {
		Contents []struct {
			Role  string `json:"role"`
			Parts []struct {
				Text string `json:"text"`
			} `json:"parts"`
		} `json:"contents"`
		Request json.RawMessage `json:"request"`
	}
	if err := json.Unmarshal(body, &req); err != nil {
		return ""
	}
	// Handle Antigravity wrapped request field ({"model": "...", "request": {"contents": [...]}}).
	if len(req.Contents) == 0 && len(req.Request) > 0 {
		var w2 struct {
			Contents []struct {
				Role  string `json:"role"`
				Parts []struct {
					Text string `json:"text"`
				} `json:"parts"`
			} `json:"contents"`
		}
		if err := json.Unmarshal(req.Request, &w2); err == nil {
			req.Contents = w2.Contents
		}
	}
	for i := len(req.Contents) - 1; i >= 0; i-- {
		if req.Contents[i].Role == "user" {
			var texts []string
			for _, p := range req.Contents[i].Parts {
				if p.Text != "" {
					texts = append(texts, p.Text)
				}
			}
			return strings.Join(texts, "\n")
		}
	}
	return ""
}

// extractOpenAIContent extracts text from an OpenAI-format request.
// messages[].content is expected to be a string.
func extractOpenAIContent(body []byte) string {
	var req struct {
		Messages []struct {
			Role    string          `json:"role"`
			Content json.RawMessage `json:"content"`
		} `json:"messages"`
	}
	if err := json.Unmarshal(body, &req); err != nil {
		return ""
	}
	var parts []string
	for _, msg := range req.Messages {
		// Skip system messages so the model's own system prompt does not
		// falsely trigger keyword rules.
		if msg.Role == "system" {
			continue
		}
		text := extractContentString(msg.Content)
		if text != "" {
			parts = append(parts, text)
		}
	}
	return strings.Join(parts, "\n")
}

// extractAnthropicContent extracts text from an Anthropic-format request.
// messages[].content can be a string or an array of {type:"text", text:"..."}.
// The system field can also be a string or an array of text blocks.
func extractAnthropicContent(body []byte) string {
	var req struct {
		System   json.RawMessage `json:"system"`
		Messages []struct {
			Role    string          `json:"role"`
			Content json.RawMessage `json:"content"`
		} `json:"messages"`
	}
	if err := json.Unmarshal(body, &req); err != nil {
		return ""
	}
	var parts []string

	// Extract messages ONLY (system prompt excluded from keyword matching).
	for _, msg := range req.Messages {
		// Skip system messages.
		if msg.Role == "system" {
			continue
		}
		text := extractContentString(msg.Content)
		if text != "" {
			parts = append(parts, text)
		}
	}
	return strings.Join(parts, "\n")
}

// extractGeminiContent extracts text from a Gemini-format request.
// contents[].parts[].text and systemInstruction.parts[].text.
func extractGeminiContent(body []byte) string {
	var req struct {
		Contents []struct {
			Role  string `json:"role"`
			Parts []struct {
				Text string `json:"text"`
			} `json:"parts"`
		} `json:"contents"`
		SystemInstruction *struct {
			Parts []struct {
				Text string `json:"text"`
			} `json:"parts"`
		} `json:"systemInstruction"`
		Request json.RawMessage `json:"request"`
	}
	if err := json.Unmarshal(body, &req); err != nil {
		return ""
	}

	// If top-level contents are empty, try the Antigravity wrapped request
	// field ({"model": "...", "request": {"contents": [...]}}).
	if len(req.Contents) == 0 && len(req.Request) > 0 {
		var wrapped struct {
			Contents []struct {
				Role  string `json:"role"`
				Parts []struct {
					Text string `json:"text"`
				} `json:"parts"`
			} `json:"contents"`
			SystemInstruction *struct {
				Parts []struct {
					Text string `json:"text"`
				} `json:"parts"`
			} `json:"systemInstruction"`
		}
		if err := json.Unmarshal(req.Request, &wrapped); err == nil {
			req.Contents = wrapped.Contents
			req.SystemInstruction = wrapped.SystemInstruction
		}
	}

	var parts []string

	// Extract contents ONLY (system instruction is excluded from keyword
	// matching so that the model's own system prompt does not falsely
	// trigger keyword rules).
	for _, content := range req.Contents {
		for _, part := range content.Parts {
			if part.Text != "" {
				parts = append(parts, part.Text)
			}
		}
	}
	return strings.Join(parts, "\n")
}

// extractContentString handles content fields that can be either a plain string
// or an array of content blocks with {type:"text", text:"..."}.
func extractContentString(raw json.RawMessage) string {
	if len(raw) == 0 {
		return ""
	}
	// Try as string first
	var str string
	if json.Unmarshal(raw, &str) == nil {
		return str
	}
	// Try as array of content blocks
	var blocks []struct {
		Type string `json:"type"`
		Text string `json:"text"`
	}
	if json.Unmarshal(raw, &blocks) == nil {
		var texts []string
		for _, b := range blocks {
			if b.Text != "" {
				texts = append(texts, b.Text)
			}
		}
		return strings.Join(texts, "\n")
	}
	return ""
}
