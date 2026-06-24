package provider

import (
	"context"
	"fmt"
	"log"
)

// ProviderConfig holds configuration for a single AI provider.
type ProviderConfig struct {
	ID          string            `json:"id"`
	Name        string            `json:"name"`
	Type        string            `json:"type"`
	ApiEndpoint string            `json:"api_endpoint"`
	ApiKey      string            `json:"api_key"`
	Models      []string          `json:"models"`
	Options     map[string]string `json:"options,omitempty"`
}

// Message represents a chat message.
type Message struct {
	Role       string     `json:"role"`
	Content    string     `json:"content,omitempty"`
	ToolCalls  []ToolCall `json:"tool_calls,omitempty"`
	ToolCallId string     `json:"tool_call_id,omitempty"`
}

// Tool represents a tool definition.
type Tool struct {
	Type     string      `json:"type"`
	Function FunctionDef `json:"function"`
}

// FunctionDef defines a function signature.
type FunctionDef struct {
	Name        string                 `json:"name"`
	Description string                 `json:"description,omitempty"`
	Parameters  map[string]interface{} `json:"parameters,omitempty"`
}

// ToolCall represents a tool call from the model.
type ToolCall struct {
	Id       string       `json:"id"`
	Type     string       `json:"type"`
	Function ToolFunction `json:"function"`
}

// ToolFunction holds the function call details.
type ToolFunction struct {
	Name      string `json:"name"`
	Arguments string `json:"arguments"`
}

// Usage tracks token usage.
type Usage struct {
	PromptTokens     int `json:"prompt_tokens"`
	CompletionTokens int `json:"completion_tokens"`
	TotalTokens      int `json:"total_tokens"`
}

// ProviderRequest is the normalized request sent to a provider.
type ProviderRequest struct {
	Model    string    `json:"model"`
	Messages []Message `json:"messages"`
	Stream   bool      `json:"stream"`
	Tools    []Tool    `json:"tools,omitempty"`
}

// ProviderResponse is the normalized response from a provider.
type ProviderResponse struct {
	Content     string     `json:"content"`
	ToolCalls   []ToolCall `json:"tool_calls,omitempty"`
	Usage       Usage      `json:"usage"`
	RawResponse []byte     `json:"-"`
}

// StreamChunk represents a single chunk from a streaming response.
type StreamChunk struct {
	Delta     string     `json:"delta"`
	ToolCalls []ToolCall `json:"tool_calls,omitempty"`
	Usage     *Usage     `json:"usage,omitempty"`
	Done      bool       `json:"done"`
	Error     error      `json:"-"`
}

// Provider defines the interface for an AI API provider.
type Provider interface {
	ID() string
	Name() string
	Type() string
	SupportedModels() []string
	IsModelSupported(model string) bool
	SendRequest(ctx context.Context, req *ProviderRequest) (*ProviderResponse, error)
	SendStreamRequest(ctx context.Context, req *ProviderRequest) (<-chan StreamChunk, error)
}

// ProviderFactory creates a Provider from its config.
type ProviderFactory func(config ProviderConfig) (Provider, error)

// Registry manages provider factories and active provider instances.
type Registry struct {
	factories map[string]ProviderFactory
	providers map[string]Provider
}

// NewRegistry creates a new provider registry.
func NewRegistry() *Registry {
	return &Registry{
		factories: make(map[string]ProviderFactory),
		providers: make(map[string]Provider),
	}
}

// RegisterFactory registers a provider factory for a given type.
func (r *Registry) RegisterFactory(providerType string, factory ProviderFactory) {
	r.factories[providerType] = factory
}

// GetProvider returns an active provider by ID.
func (r *Registry) GetProvider(id string) (Provider, error) {
	if p, ok := r.providers[id]; ok {
		return p, nil
	}
	return nil, fmt.Errorf("provider not found: %s", id)
}

// LoadProvidersFromConfig creates providers from a list of configs.
func (r *Registry) LoadProvidersFromConfig(configs []ProviderConfig) {
	for _, cfg := range configs {
		factory, ok := r.factories[cfg.Type]
		if !ok {
			log.Printf("[Provider] Unknown provider type: %s (id=%s)", cfg.Type, cfg.ID)
			continue
		}
		p, err := factory(cfg)
		if err != nil {
			log.Printf("[Provider] Failed to create provider %s: %v", cfg.ID, err)
			continue
		}
		r.providers[cfg.ID] = p
		log.Printf("[Provider] Registered provider: %s (type=%s, models=%v)", cfg.ID, cfg.Type, cfg.Models)
	}
}
