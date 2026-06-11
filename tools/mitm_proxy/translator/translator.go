package translator

import (
	"github.com/KevinLiangX/AntigravityProxyLauncher/mitm_proxy/provider"
)

// Translator defines the interface for translating between different API formats
type Translator interface {
	// SourceFormat returns the source API format (e.g., "anthropic", "gemini")
	SourceFormat() string

	// TargetFormat returns the target API format (e.g., "openai", "xiaomi")
	TargetFormat() string

	// TranslateRequest translates a request from source format to provider format
	TranslateRequest(sourceReq []byte, targetModel string) (*provider.ProviderRequest, error)

	// TranslateResponse translates a provider response back to source format
	TranslateResponse(resp *provider.ProviderResponse, sourceModel string) ([]byte, error)

	// TranslateStreamChunk translates a streaming chunk back to source format
	TranslateStreamChunk(chunk *provider.StreamChunk, sourceModel string, state *StreamState) ([]byte, error)

	// CanTranslate checks if this translator can handle the given source/target combination
	CanTranslate(source, target string) bool
}

// StreamState maintains state across streaming chunks
type StreamState struct {
	ToolCallID       string
	ToolCallIndex    int
	FullText         string
	PromptTokens     int
	CompletionTokens int
	// Gemini-specific: track function call state for streaming
	FunctionCallName string
	FunctionCallArgs string
	HasFunctionCall  bool
	// Anthropic-specific: track whether content_block_start has been sent
	TextBlockStarted bool
}

// NewStreamState creates a new stream state
func NewStreamState() *StreamState {
	return &StreamState{}
}

// Registry manages available translators
type Registry struct {
	translators []Translator
}

// NewRegistry creates a new translator registry
func NewRegistry() *Registry {
	return &Registry{
		translators: make([]Translator, 0),
	}
}

// Register adds a translator to the registry
func (r *Registry) Register(t Translator) {
	r.translators = append(r.translators, t)
}

// FindTranslator finds a translator for the given source and target formats
func (r *Registry) FindTranslator(source, target string) Translator {
	for _, t := range r.translators {
		if t.CanTranslate(source, target) {
			return t
		}
	}
	return nil
}
