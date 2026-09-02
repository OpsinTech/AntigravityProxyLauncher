package provider

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"strings"
	"time"
)

// OpenAIProvider implements the Provider interface for OpenAI-compatible APIs
// This works with DeepSeek, Xiaomi (if OpenAI-compatible), and other similar providers
type OpenAIProvider struct {
	config       ProviderConfig
	httpClient   *http.Client
	apiPath      string
	authHeader   string
	authPrefix   string
	extraHeaders map[string]string
	scheme       string // "http" or "https", default "https"
}

// OpenAIRequest represents an OpenAI API request
type OpenAIRequest struct {
	Model    string          `json:"model"`
	Messages []Message       `json:"messages"`
	Stream   bool            `json:"stream"`
	Tools    []Tool          `json:"tools,omitempty"`
	Thinking *ThinkingConfig `json:"thinking,omitempty"`
}

// ThinkingConfig disables or enables deep thinking mode (DeepSeek-specific)
type ThinkingConfig struct {
	Type string `json:"type"`
}

// OpenAIResponse represents an OpenAI API response
type OpenAIResponse struct {
	Choices []OpenAIChoice `json:"choices"`
	Usage   *Usage         `json:"usage,omitempty"`
}

// OpenAIChoice represents a choice in the response
type OpenAIChoice struct {
	Message OpenAIMessage `json:"message"`
}

// OpenAIMessage represents a message in the response
type OpenAIMessage struct {
	Role      string     `json:"role"`
	Content   string     `json:"content"`
	ToolCalls []ToolCall `json:"tool_calls,omitempty"`
}

// OpenAIStreamResponse represents a streaming response
type OpenAIStreamResponse struct {
	Choices []OpenAIStreamChoice `json:"choices"`
	Usage   *Usage               `json:"usage,omitempty"`
}

// OpenAIStreamChoice represents a choice in a streaming response
type OpenAIStreamChoice struct {
	Delta        OpenAIDelta `json:"delta"`
	FinishReason string      `json:"finish_reason"`
}

// OpenAIDelta represents a delta in a streaming response
type OpenAIDelta struct {
	Role      string     `json:"role,omitempty"`
	Content   string     `json:"content,omitempty"`
	ToolCalls []ToolCall `json:"tool_calls,omitempty"`
}

// NewOpenAIProvider creates a new OpenAI-compatible provider
func NewOpenAIProvider(config ProviderConfig) (Provider, error) {
	if config.ApiEndpoint == "" {
		return nil, fmt.Errorf("api_endpoint is required for OpenAI provider")
	}

	// Set defaults for options
	apiPath := "/v1/chat/completions"
	authHeader := "Authorization"
	authPrefix := "Bearer "
	scheme := "https"

	extraHeaders := make(map[string]string)

	if config.Options != nil {
		if v, ok := config.Options["api_path"]; ok {
			apiPath = v
		}
		if v, ok := config.Options["auth_header"]; ok {
			authHeader = v
		}
		if v, ok := config.Options["auth_prefix"]; ok {
			authPrefix = v
		}
		if v, ok := config.Options["scheme"]; ok && (v == "http" || v == "https") {
			scheme = v
		}
		// Parse extra_headers if present (JSON key-value map)
		if v, ok := config.Options["extra_headers"]; ok && v != "" {
			if err := json.Unmarshal([]byte(v), &extraHeaders); err != nil {
				log.Printf("[OpenAI:%s] Failed to parse extra_headers, ignoring: %v", config.ID, err)
			}
		}
	}

	// If api_endpoint already carries a scheme prefix (e.g. "http://localhost:11434"),
	// extract it and strip it from the host. Explicit options.scheme takes precedence.
	endpoint := config.ApiEndpoint
	if idx := strings.Index(endpoint, "://"); idx != -1 {
		s := endpoint[:idx]
		if s == "http" || s == "https" {
			if scheme == "https" {
				scheme = s
			}
		}
		config.ApiEndpoint = endpoint[idx+3:]
	}

	p := &OpenAIProvider{
		config:       config,
		httpClient:   &http.Client{},
		apiPath:      apiPath,
		authHeader:   authHeader,
		authPrefix:   authPrefix,
		extraHeaders: extraHeaders,
		scheme:       scheme,
	}
	p.autoFetchModels()
	return p, nil
}

func (p *OpenAIProvider) ID() string {
	return p.config.ID
}

// autoFetchModels fetches the model list from the provider's OpenAI-compatible
// /v1/models endpoint when options["auto_models"] == "true". This is intended for
// local model servers (ollama / vllm / llama.cpp) whose model set is determined by
// what is loaded at runtime. On success it overrides the configured models list;
// on failure it falls back to the configured models and logs a warning.
func (p *OpenAIProvider) autoFetchModels() {
	if p.config.Options == nil || p.config.Options["auto_models"] != "true" {
		return
	}
	url := fmt.Sprintf("%s://%s/v1/models", p.scheme, p.config.ApiEndpoint)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	httpReq, err := http.NewRequestWithContext(ctx, "GET", url, nil)
	if err != nil {
		log.Printf("[OpenAI:%s] Failed to build auto_models request: %v", p.config.ID, err)
		return
	}
	if p.config.ApiKey != "" {
		httpReq.Header.Set(p.authHeader, p.authPrefix+p.config.ApiKey)
	}
	for k, v := range p.extraHeaders {
		httpReq.Header.Set(k, v)
	}

	resp, err := p.httpClient.Do(httpReq)
	if err != nil {
		log.Printf("[OpenAI:%s] auto_models fetch failed (%s), keeping configured models", p.config.ID, url)
		return
	}
	defer resp.Body.Close()

	if resp.StatusCode >= 400 {
		log.Printf("[OpenAI:%s] auto_models fetch returned status %d, keeping configured models", p.config.ID, resp.StatusCode)
		return
	}

	var list struct {
		Data []struct {
			ID string `json:"id"`
		} `json:"data"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&list); err != nil {
		log.Printf("[OpenAI:%s] auto_models parse failed: %v", p.config.ID, err)
		return
	}

	var models []string
	for _, m := range list.Data {
		if m.ID != "" {
			models = append(models, m.ID)
		}
	}
	if len(models) == 0 {
		log.Printf("[OpenAI:%s] auto_models returned empty list, keeping configured models", p.config.ID)
		return
	}
	p.config.Models = models
	log.Printf("[OpenAI:%s] auto_models fetched %d models from %s", p.config.ID, len(models), url)
}

func (p *OpenAIProvider) Name() string {
	return p.config.Name
}

func (p *OpenAIProvider) Type() string {
	return "openai"
}

// thinkingConfig returns the thinking config for the provider.
// Returns nil by default (omits the field from JSON requests).
//
// Behavior:
//   - If options["thinking"] is explicitly set, that value is used as-is
//     (e.g. "enabled" for DeepSeek reasoning models, "disabled" to force off).
//   - If not set, we auto-disable thinking for known DeepSeek reasoning models
//     (deepseek-v4-flash, deepseek-v4-pro, deepseek-reasoner, etc.). These models
//     are reasoning models by default and DeepSeek's API requires `reasoning_content`
//     to be echoed back on multi-turn requests; since we don't preserve it, leaving
//     thinking on causes a 400 ("The `reasoning_content` in the thinking mode must
//     be passed back to the API"). Auto-disabling avoids that without sacrificing
//     normal chat capability.
func (p *OpenAIProvider) thinkingConfig() *ThinkingConfig {
	if p.config.Options != nil {
		if v, ok := p.config.Options["thinking"]; ok && v != "" {
			return &ThinkingConfig{Type: v}
		}
	}
	// Auto-disable thinking for DeepSeek reasoning models unless explicitly enabled.
	if isDeepSeekReasoningModel(p.config.Models, p.config.ApiEndpoint) {
		return &ThinkingConfig{Type: "disabled"}
	}
	// Return nil → omitempty drops the field from JSON
	return nil
}

// isDeepSeekReasoningModel reports whether the provider is a DeepSeek endpoint
// serving reasoning models (deepseek-v4-flash/pro, deepseek-reasoner, etc.).
// Reasoning models require reasoning_content echo-back; we disable thinking by
// default to avoid the 400 error when we don't preserve reasoning_content.
func isDeepSeekReasoningModel(models []string, apiEndpoint string) bool {
	endpointLower := strings.ToLower(apiEndpoint)
	if !strings.Contains(endpointLower, "deepseek") {
		return false
	}
	for _, m := range models {
		ml := strings.ToLower(m)
		if strings.Contains(ml, "v4-flash") ||
			strings.Contains(ml, "v4-pro") ||
			strings.Contains(ml, "reasoner") {
			return true
		}
	}
	return false
}

func (p *OpenAIProvider) SupportedModels() []string {
	return p.config.Models
}

func (p *OpenAIProvider) IsModelSupported(model string) bool {
	modelLower := strings.ToLower(model)
	for _, m := range p.config.Models {
		if strings.ToLower(m) == modelLower {
			return true
		}
	}
	return false
}

func (p *OpenAIProvider) SendRequest(ctx context.Context, req *ProviderRequest) (*ProviderResponse, error) {
	var reqBytes []byte
	var err error

	// For same-format passthrough, use the original raw body
	if len(req.RawBody) > 0 {
		reqBytes = ensureThinkingDisabledForDeepSeek(req.RawBody, p.config)
	} else {
		openAIReq := OpenAIRequest{
			Model:    req.Model,
			Messages: req.Messages,
			Stream:   false,
			Tools:    req.Tools,
			Thinking: p.thinkingConfig(),
		}
		reqBytes, err = json.Marshal(openAIReq)
		if err != nil {
			return nil, fmt.Errorf("failed to marshal request: %w", err)
		}
	}

	url := fmt.Sprintf("%s://%s%s", p.scheme, p.config.ApiEndpoint, p.apiPath)
	httpReq, err := http.NewRequestWithContext(ctx, "POST", url, bytes.NewBuffer(reqBytes))
	if err != nil {
		return nil, fmt.Errorf("failed to create request: %w", err)
	}

	httpReq.Header.Set("Content-Type", "application/json")
	if p.config.ApiKey != "" {
		httpReq.Header.Set(p.authHeader, p.authPrefix+p.config.ApiKey)
	}
	for k, v := range p.extraHeaders {
		httpReq.Header.Set(k, v)
	}

	resp, err := p.httpClient.Do(httpReq)
	if err != nil {
		return nil, fmt.Errorf("request failed: %w", err)
	}
	defer resp.Body.Close()

	bodyBytes, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("failed to read response: %w", err)
	}

	if resp.StatusCode >= 400 {
		return nil, fmt.Errorf("API error (status %d): %s", resp.StatusCode, string(bodyBytes))
	}

	var openAIResp OpenAIResponse
	if err := json.Unmarshal(bodyBytes, &openAIResp); err != nil {
		return nil, fmt.Errorf("failed to unmarshal response: %w", err)
	}

	if len(openAIResp.Choices) == 0 {
		return nil, fmt.Errorf("no choices in response")
	}

	choice := openAIResp.Choices[0]
	providerResp := &ProviderResponse{
		Content:     choice.Message.Content,
		ToolCalls:   choice.Message.ToolCalls,
		RawResponse: bodyBytes,
	}

	if openAIResp.Usage != nil {
		providerResp.Usage = *openAIResp.Usage
	}

	return providerResp, nil
}

func (p *OpenAIProvider) SendStreamRequest(ctx context.Context, req *ProviderRequest) (<-chan StreamChunk, error) {
	var reqBytes []byte
	var err error

	// For same-format passthrough, use the original raw body (with model
	// already substituted) to preserve all fields like temperature,
	// max_tokens, content format, etc. that would be lost in struct marshaling.
	if len(req.RawBody) > 0 {
		reqBytes = ensureThinkingDisabledForDeepSeek(req.RawBody, p.config)
		log.Printf("[OpenAI:%s] Using raw body passthrough (len=%d)", p.config.ID, len(reqBytes))
	} else {
		openAIReq := OpenAIRequest{
			Model:    req.Model,
			Messages: req.Messages,
			Stream:   true,
			Tools:    req.Tools,
			Thinking: p.thinkingConfig(),
		}
		reqBytes, err = json.Marshal(openAIReq)
		if err != nil {
			return nil, fmt.Errorf("failed to marshal request: %w", err)
		}
	}

	log.Printf("[OpenAI:%s] Request: model=%s, stream=%v, tools=%d, messages=%d",
		p.config.ID, req.Model, req.Stream, len(req.Tools), len(req.Messages))

	if os.Getenv("MITM_DEBUG") == "true" {
		reqBodyStr := string(reqBytes)
		if len(reqBodyStr) > 2000 {
			reqBodyStr = reqBodyStr[:2000] + "...(truncated)"
		}
		log.Printf("[OpenAI:%s] [DEBUG] Request body: %s", p.config.ID, reqBodyStr)
	}

	url := fmt.Sprintf("%s://%s%s", p.scheme, p.config.ApiEndpoint, p.apiPath)
	httpReq, err := http.NewRequestWithContext(ctx, "POST", url, bytes.NewBuffer(reqBytes))
	if err != nil {
		return nil, fmt.Errorf("failed to create request: %w", err)
	}

	httpReq.Header.Set("Content-Type", "application/json")
	if p.config.ApiKey != "" {
		httpReq.Header.Set(p.authHeader, p.authPrefix+p.config.ApiKey)
	}
	for k, v := range p.extraHeaders {
		httpReq.Header.Set(k, v)
	}

	resp, err := p.httpClient.Do(httpReq)
	if err != nil {
		return nil, fmt.Errorf("request failed: %w", err)
	}

	if resp.StatusCode >= 400 {
		bodyBytes, _ := io.ReadAll(resp.Body)
		resp.Body.Close()
		return nil, fmt.Errorf("API error (status %d): %s", resp.StatusCode, string(bodyBytes))
	}

	chunks := make(chan StreamChunk, 100)
	go p.processStream(ctx, resp.Body, chunks)

	return chunks, nil
}

// ensureThinkingDisabledForDeepSeek patches a raw request body for DeepSeek
// reasoning models. DeepSeek's API requires `reasoning_content` to be echoed
// back when thinking mode is enabled; since translators don't preserve it,
// we force thinking off unless the user explicitly opted in via options.
// Returns the original bytes unchanged for non-DeepSeek reasoning providers.
func ensureThinkingDisabledForDeepSeek(rawBody []byte, cfg ProviderConfig) []byte {
	if !isDeepSeekReasoningModel(cfg.Models, cfg.ApiEndpoint) {
		return rawBody
	}
	// Respect explicit opt-in.
	if v, ok := cfg.Options["thinking"]; ok && strings.EqualFold(v, "enabled") {
		return rawBody
	}
	var m map[string]interface{}
	if err := json.Unmarshal(rawBody, &m); err != nil {
		return rawBody
	}
	// Don't override an existing explicit thinking setting in the body.
	if _, exists := m["thinking"]; exists {
		return rawBody
	}
	m["thinking"] = map[string]interface{}{"type": "disabled"}
	patched, err := json.Marshal(m)
	if err != nil {
		return rawBody
	}
	return patched
}

func (p *OpenAIProvider) processStream(ctx context.Context, body io.ReadCloser, chunks chan<- StreamChunk) {
	defer body.Close()
	defer close(chunks)

	// Non-blocking send: respects context cancellation and avoids goroutine leak
	// when the consumer has stopped reading.
	send := func(chunk StreamChunk) bool {
		select {
		case <-ctx.Done():
			return false
		case chunks <- chunk:
			return true
		}
	}

	scanner := bufio.NewScanner(body)
	buf := make([]byte, 0, 1024*1024)
	scanner.Buffer(buf, 1024*1024)
	chunkCount := 0
	for scanner.Scan() {
		// Check context before processing each line
		select {
		case <-ctx.Done():
			log.Printf("[OpenAI:%s] Stream cancelled by context, chunks=%d", p.config.ID, chunkCount)
			return
		default:
		}

		line := scanner.Text()
		if !strings.HasPrefix(line, "data: ") {
			if line != "" && chunkCount == 0 {
				log.Printf("[OpenAI:%s] Non-SSE response line: %s", p.config.ID, line)
			}
			continue
		}

		dataStr := strings.TrimPrefix(line, "data: ")
		if dataStr == "[DONE]" {
			send(StreamChunk{Done: true})
			log.Printf("[OpenAI:%s] Stream completed normally, chunks=%d", p.config.ID, chunkCount)
			return
		}

		// Debug: log first chunk content
		if chunkCount == 0 && os.Getenv("MITM_DEBUG") == "true" {
			log.Printf("[OpenAI:%s] [DEBUG] First chunk raw: %s", p.config.ID, dataStr)
		}

		var streamResp OpenAIStreamResponse
		if err := json.Unmarshal([]byte(dataStr), &streamResp); err != nil {
			log.Printf("[OpenAI:%s] Failed to parse stream chunk: %v", p.config.ID, err)
			continue
		}

		if len(streamResp.Choices) == 0 {
			continue
		}

		delta := streamResp.Choices[0].Delta
		chunk := StreamChunk{
			Delta:        delta.Content,
			ToolCalls:    delta.ToolCalls,
			FinishReason: streamResp.Choices[0].FinishReason,
		}

		if streamResp.Usage != nil {
			chunk.Usage = streamResp.Usage
		}

		chunkCount++
		if !send(chunk) {
			log.Printf("[OpenAI:%s] Stream send cancelled (consumer gone), chunks=%d", p.config.ID, chunkCount)
			return
		}
	}

	// If we get here without [DONE], the scanner stopped
	if err := scanner.Err(); err != nil {
		log.Printf("[OpenAI:%s] Stream interrupted: %v, chunks=%d", p.config.ID, err, chunkCount)
		send(StreamChunk{Error: fmt.Errorf("stream interrupted: %w", err)})
	} else {
		log.Printf("[OpenAI:%s] Stream ended without [DONE], chunks=%d", p.config.ID, chunkCount)
		send(StreamChunk{Done: true})
	}
}

// RegisterOpenAIProvider registers the OpenAI provider factory with the registry
func RegisterOpenAIProvider(registry *Registry) {
	registry.RegisterFactory("openai", func(config ProviderConfig) (Provider, error) {
		return NewOpenAIProvider(config)
	})
}
