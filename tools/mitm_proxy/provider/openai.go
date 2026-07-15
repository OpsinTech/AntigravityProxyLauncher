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
	Delta OpenAIDelta `json:"delta"`
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
		// Parse extra_headers if present (JSON key-value map)
		if v, ok := config.Options["extra_headers"]; ok && v != "" {
			if err := json.Unmarshal([]byte(v), &extraHeaders); err != nil {
				log.Printf("[OpenAI:%s] Failed to parse extra_headers, ignoring: %v", config.ID, err)
			}
		}
	}

	return &OpenAIProvider{
		config:       config,
		httpClient:   &http.Client{},
		apiPath:      apiPath,
		authHeader:   authHeader,
		authPrefix:   authPrefix,
		extraHeaders: extraHeaders,
	}, nil
}

func (p *OpenAIProvider) ID() string {
	return p.config.ID
}

func (p *OpenAIProvider) Name() string {
	return p.config.Name
}

func (p *OpenAIProvider) Type() string {
	return "openai"
}

// thinkingConfig returns the thinking config for the provider.
// Returns nil by default (omits the field from JSON requests).
// Only returns a value when the provider option "thinking" is explicitly set
// (e.g. "enabled" for DeepSeek).
func (p *OpenAIProvider) thinkingConfig() *ThinkingConfig {
	if p.config.Options != nil {
		if v, ok := p.config.Options["thinking"]; ok {
			return &ThinkingConfig{Type: v}
		}
	}
	// Return nil → omitempty drops the field from JSON
	// Prevents "Unknown parameter: 'thinking'" errors on providers that
	// don't support it (OfoxAI, most OpenAI-compatible gateways).
	return nil
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
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()

	openAIReq := OpenAIRequest{
		Model:    req.Model,
		Messages: req.Messages,
		Stream:   false,
		Tools:    req.Tools,
		Thinking: p.thinkingConfig(),
	}

	reqBytes, err := json.Marshal(openAIReq)
	if err != nil {
		return nil, fmt.Errorf("failed to marshal request: %w", err)
	}

	url := fmt.Sprintf("https://%s%s", p.config.ApiEndpoint, p.apiPath)
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
	openAIReq := OpenAIRequest{
		Model:    req.Model,
		Messages: req.Messages,
		Stream:   true,
		Tools:    req.Tools,
		Thinking: p.thinkingConfig(),
	}

	reqBytes, err := json.Marshal(openAIReq)
	if err != nil {
		return nil, fmt.Errorf("failed to marshal request: %w", err)
	}

	log.Printf("[OpenAI:%s] Request body keys: model=%s, stream=%v, tools=%d, messages=%d, thinking=%v",
		p.config.ID, openAIReq.Model, openAIReq.Stream, len(openAIReq.Tools), len(openAIReq.Messages),
		openAIReq.Thinking != nil)

	url := fmt.Sprintf("https://%s%s", p.config.ApiEndpoint, p.apiPath)
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
			continue
		}

		dataStr := strings.TrimPrefix(line, "data: ")
		if dataStr == "[DONE]" {
			send(StreamChunk{Done: true})
			log.Printf("[OpenAI:%s] Stream completed normally, chunks=%d", p.config.ID, chunkCount)
			return
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
			Delta:     delta.Content,
			ToolCalls: delta.ToolCalls,
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
