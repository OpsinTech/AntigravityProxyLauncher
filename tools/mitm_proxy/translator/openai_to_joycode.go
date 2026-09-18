package translator

// JoyCode speaks the OpenAI wire format behind its signed gateway, so the
// openai/gemini/anthropic translators work unchanged — only the target
// format label differs. These thin re-targets keep the single source of
// truth for translation logic in the *ToOpenAI translators.

// OpenAIToJoyCode translates OpenAI format requests for JoyCode providers
// (raw-body passthrough with model substitution).
type OpenAIToJoyCode struct{ *OpenAIToOpenAI }

func (t *OpenAIToJoyCode) TargetFormat() string { return "joycode" }

func (t *OpenAIToJoyCode) CanTranslate(source, target string) bool {
	return source == "openai" && target == "joycode"
}

// GeminiToJoyCode translates Gemini format requests for JoyCode providers.
type GeminiToJoyCode struct{ *GeminiToOpenAI }

func (t *GeminiToJoyCode) TargetFormat() string { return "joycode" }

func (t *GeminiToJoyCode) CanTranslate(source, target string) bool {
	return source == "gemini" && target == "joycode"
}

// AnthropicToJoyCode translates Anthropic format requests for JoyCode providers.
type AnthropicToJoyCode struct{ *AnthropicToOpenAI }

func (t *AnthropicToJoyCode) TargetFormat() string { return "joycode" }

func (t *AnthropicToJoyCode) CanTranslate(source, target string) bool {
	return source == "anthropic" && target == "joycode"
}

// RegisterJoyCodeTranslators registers all three source formats targeting
// the "joycode" provider type.
func RegisterJoyCodeTranslators(registry *Registry) {
	registry.Register(&OpenAIToJoyCode{})
	registry.Register(&GeminiToJoyCode{})
	registry.Register(&AnthropicToJoyCode{})
}
