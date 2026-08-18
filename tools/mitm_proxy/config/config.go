package config

import (
	"encoding/json"
	"log"
	"os"
	"strings"

	"github.com/KevinLiangX/AntigravityProxyLauncher/mitm_proxy/provider"
)

// LLMRouterSpecialID is the special target_provider_id that triggers LLMRouter routing.
const LLMRouterSpecialID = "llm_router"

// GeminiBuiltinProviderID is the special target_provider_id that routes the request
// to the app's built-in Gemini backend (passthrough with model substitution).
// The request keeps the original Google authentication and Gemini wrapped format;
// no third-party provider config or API key is required.
const GeminiBuiltinProviderID = "gemini_builtin"

// ProviderEntry describes a single AI provider for routing configuration.
type ProviderEntry struct {
	ID          string            `json:"id"`
	Name        string            `json:"name"`
	Type        string            `json:"type"`
	Enabled     bool              `json:"enabled"`
	ApiEndpoint string            `json:"api_endpoint"`
	ApiKey      string            `json:"api_key"`
	Models      []string          `json:"models"`
	Options     map[string]string `json:"options,omitempty"`
}

// RoutingRule maps a source model to a target provider+model.
// When TargetProviderID == "llm_router", the request enters the LLMRouter
// keyword-based routing subsystem instead of going to a fixed model.
type RoutingRule struct {
	SourceModelPattern string `json:"source_model_pattern"`
	SourceType         string `json:"source_type,omitempty"`
	TargetModel        string `json:"target_model"`
	TargetProviderID   string `json:"target_provider_id"`
	Enabled            bool   `json:"enabled"`
	Priority           int    `json:"priority,omitempty"`
}

// LLMRouterRule defines a keyword-based routing rule within the LLMRouter.
type LLMRouterRule struct {
	Keywords        []string `json:"keywords"`
	MatchMode       string   `json:"match_mode,omitempty"` // "any" (default) or "all"
	TargetModel     string   `json:"target_model"`
	TargetProviderID string  `json:"target_provider_id"`
	Enabled         bool     `json:"enabled"`
}

// LLMRouterConfig holds the LLMRouter configuration.
// The Enabled field is only used by the UI to control visibility of the
// LLMRouter config section; at runtime, once a routing rule targets
// "llm_router", the LLMRouter is implicitly active.
type LLMRouterConfig struct {
	Enabled           bool            `json:"enabled"`
	DefaultModel      string          `json:"default_model"`
	DefaultProviderID string          `json:"default_provider_id"`
	Rules             []LLMRouterRule `json:"rules"`
}

// ModelRouting holds the complete routing configuration.
type ModelRouting struct {
	Version    string          `json:"version"`
	Providers  []ProviderEntry `json:"providers"`
	Rules      []RoutingRule   `json:"routing_rules"`
	LLMRouter  *LLMRouterConfig `json:"llm_router,omitempty"`
}

// RoutingConfig holds routing rules and provider entries for handler usage.
type RoutingConfig struct {
	Rules     []RoutingRule
	Providers []ProviderEntry
	LLMRouter *LLMRouterConfig
}

// FindMatchingRule finds the first enabled rule matching the given model name and optional source type.
// If sourceType is non-empty, only rules with a matching source_type (or empty source_type as wildcard) are considered.
// Matches by exact model name first, then by source_model_pattern substring.
func (c *RoutingConfig) FindMatchingRule(model string, sourceType string) *RoutingRule {
	modelLower := strings.ToLower(model)
	// First pass: exact match on model name (enabled only, filtered by source_type)
	for i := range c.Rules {
		if c.Rules[i].SourceModelPattern == "" {
			continue
		}
		if !c.Rules[i].Enabled {
			continue
		}
		if !ruleMatchesSourceType(c.Rules[i], sourceType) {
			continue
		}
		if strings.ToLower(c.Rules[i].SourceModelPattern) == modelLower {
			return &c.Rules[i]
		}
	}
	// Second pass: substring match (enabled only, filtered by source_type)
	for i := range c.Rules {
		if c.Rules[i].SourceModelPattern == "" {
			continue
		}
		if !c.Rules[i].Enabled {
			continue
		}
		if !ruleMatchesSourceType(c.Rules[i], sourceType) {
			continue
		}
		if strings.Contains(modelLower, strings.ToLower(c.Rules[i].SourceModelPattern)) {
			return &c.Rules[i]
		}
	}
	return nil
}

// FindLLMRouterMatch matches the request content against LLMRouter keyword rules.
// Returns the matched rule, or nil if no rule matches (caller should use default).
// The LLMRouter is considered active as long as it exists — there is no runtime
// "enabled" check; the Enabled field is purely a UI concern.
func (c *RoutingConfig) FindLLMRouterMatch(content string) *LLMRouterRule {
	if c.LLMRouter == nil {
		return nil
	}
	contentLower := strings.ToLower(content)
	if contentLower == "" {
		return nil
	}
	for i := range c.LLMRouter.Rules {
		rule := &c.LLMRouter.Rules[i]
		if !rule.Enabled || len(rule.Keywords) == 0 {
			continue
		}
		mode := rule.MatchMode
		if mode == "" {
			mode = "any"
		}
		if matchKeywords(rule.Keywords, contentLower, mode) {
			return rule
		}
	}
	return nil
}

// GetLLMRouterDefault returns the default provider+model for LLMRouter.
// Returns empty strings if LLMRouter is not configured.
func (c *RoutingConfig) GetLLMRouterDefault() (providerID string, model string) {
	if c.LLMRouter == nil {
		return "", ""
	}
	return c.LLMRouter.DefaultProviderID, c.LLMRouter.DefaultModel
}

// ResolveLLMRouterTarget checks if a routing rule targets the LLMRouter.
// If it does, it resolves the actual provider+model via keyword matching
// (falling back to the LLMRouter default). If the rule targets a concrete
// provider, the original values are returned unchanged.
// gemini_builtin is honored only for Gemini-format requests: it carries the
// IDE's Google auth and Gemini wrapped format, so exposing it to OpenAI- or
// Anthropic-format clients would end in "provider not configured". Those
// formats skip such keyword matches and fall through to the default.
// Returns empty strings if LLMRouter resolution fails (no match + no default),
// signaling the caller to passthrough.
func (c *RoutingConfig) ResolveLLMRouterTarget(rule *RoutingRule, bodyBytes []byte, format string) (providerID string, model string) {
	if rule.TargetProviderID != LLMRouterSpecialID {
		return rule.TargetProviderID, rule.TargetModel
	}
	// Only match against the LATEST user message to avoid false triggers from
	// historical conversation context (e.g. a past message mentioning "CSS" or
	// "前端" would otherwise route all subsequent requests to hy3).
	content := ExtractLatestUserContent(bodyBytes, format)
	log.Printf("[LLMRouter] Resolving target from latest user message, length=%d", len(content))
	if matched := c.FindLLMRouterMatch(content); matched != nil {
		if matched.TargetProviderID == GeminiBuiltinProviderID && format != "gemini" {
			log.Printf("[LLMRouter] Keyword match %q targets %s (IDE-only), skipping for %s-format request, using default",
				matched.Keywords, GeminiBuiltinProviderID, format)
		} else {
			log.Printf("[LLMRouter] Keyword match -> provider=%s model=%s", matched.TargetProviderID, matched.TargetModel)
			return matched.TargetProviderID, matched.TargetModel
		}
	}
	defProvider, defModel := c.GetLLMRouterDefault()
	if defProvider != "" && defModel != "" {
		log.Printf("[LLMRouter] No keyword match, using default -> provider=%s model=%s", defProvider, defModel)
	}
	return defProvider, defModel
}

// matchKeywords checks if content matches keywords by the given mode.
func matchKeywords(keywords []string, contentLower string, mode string) bool {
	for _, kw := range keywords {
		kwLower := strings.ToLower(kw)
		matched := strings.Contains(contentLower, kwLower)
		if mode == "any" && matched {
			return true
		}
		if mode == "all" && !matched {
			return false
		}
	}
	return mode == "all"
}

// ruleMatchesSourceType returns true if the rule should be considered for the given source type.
// A rule with empty SourceType acts as a wildcard and matches any source type.
// A rule with a non-empty SourceType only matches when sourceType equals it exactly.
func ruleMatchesSourceType(rule RoutingRule, sourceType string) bool {
	if sourceType == "" {
		return true // No source type filter requested, match all
	}
	if rule.SourceType == "" {
		return true // Rule has no source_type restriction, act as wildcard
	}
	return rule.SourceType == sourceType
}

// GetProvider returns a ProviderEntry by ID (only if enabled).
// When multiple entries share the same ID (different ecosystems), prefers the one with ApiKey.
func (c *RoutingConfig) GetProvider(providerID string) *ProviderEntry {
	var best *ProviderEntry
	for i := range c.Providers {
		if c.Providers[i].ID == providerID && c.Providers[i].Enabled {
			if best == nil || (c.Providers[i].ApiKey != "" && best.ApiKey == "") {
				best = &c.Providers[i]
			}
		}
	}
	return best
}

// EnabledRules returns only enabled rules.
func (c *RoutingConfig) EnabledRules() []RoutingRule {
	var result []RoutingRule
	for _, r := range c.Rules {
		if r.Enabled {
			result = append(result, r)
		}
	}
	return result
}

// EnabledProviders returns only enabled providers.
func (c *RoutingConfig) EnabledProviders() []ProviderEntry {
	var result []ProviderEntry
	for _, p := range c.Providers {
		if p.Enabled {
			result = append(result, p)
		}
	}
	return result
}

// ToProviderConfigs converts enabled routing provider entries to provider.ProviderConfig list.
func (m *ModelRouting) ToProviderConfigs() []provider.ProviderConfig {
	configs := make([]provider.ProviderConfig, 0, len(m.Providers))
	for _, p := range m.Providers {
		if !p.Enabled {
			continue
		}
		configs = append(configs, provider.ProviderConfig{
			ID:          p.ID,
			Name:        p.Name,
			Type:        p.Type,
			ApiEndpoint: p.ApiEndpoint,
			ApiKey:      p.ApiKey,
			Models:      p.Models,
			Options:     p.Options,
		})
	}
	return configs
}

// ToHandlerRoutingConfig converts to a RoutingConfig for use by handlers.
func (m *ModelRouting) ToHandlerRoutingConfig() RoutingConfig {
	return RoutingConfig{
		Rules:     m.Rules,
		Providers: m.Providers,
		LLMRouter: m.LLMRouter,
	}
}

// LoadModelRouting loads model routing configuration from ~/.config/antigravity/model_routing.json
func LoadModelRouting() *ModelRouting {
	home, err := os.UserHomeDir()
	if err != nil {
		log.Println("[Config] Cannot get home dir")
		return &ModelRouting{}
	}

	configPath := home + "/.config/antigravity/model_routing.json"
	routing := &ModelRouting{}

	data, err := os.ReadFile(configPath)
	if err != nil {
		log.Printf("[Config] Cannot read model routing config at %s: %v", configPath, err)
		return routing
	}

	if err := json.Unmarshal(data, routing); err != nil {
		log.Printf("[Config] Failed to parse model routing config: %v", err)
		return &ModelRouting{}
	}

	llmRouterRules := 0
	if routing.LLMRouter != nil {
		llmRouterRules = len(routing.LLMRouter.Rules)
	}
	log.Printf("[Config] Loaded model routing: %d providers, %d rules, llm_router=%v (%d keyword rules)",
		len(routing.Providers), len(routing.Rules), routing.LLMRouter != nil, llmRouterRules)
	return routing
}

// IsModelRoutingEnabled checks proxy_config.json for mitm.model_routing_enabled.
func IsModelRoutingEnabled() bool {
	configPath := os.Getenv("PROXY_CONFIG")
	if configPath == "" {
		configPath = os.Getenv("ANTIGRAVITY_CONFIG")
	}
	if configPath == "" {
		home, _ := os.UserHomeDir()
		configPath = home + "/.config/antigravity/proxy_config.json"
	}

	data, err := os.ReadFile(configPath)
	if err != nil {
		log.Printf("[Config] Cannot read proxy_config at %s, defaulting to passthrough", configPath)
		return false
	}

	var cfg struct {
		Mitm struct {
			ModelRoutingEnabled *bool `json:"model_routing_enabled"`
		} `json:"mitm"`
	}
	if err := json.Unmarshal(data, &cfg); err != nil {
		return true
	}

	if cfg.Mitm.ModelRoutingEnabled != nil {
		return *cfg.Mitm.ModelRoutingEnabled
	}
	return false
}

// LoadMitmHosts loads custom MITM host list from proxy_config.json (mitm.hosts field).
// Returns nil if not configured — caller should use defaults.
func LoadMitmHosts() []string {
	configPath := os.Getenv("PROXY_CONFIG")
	if configPath == "" {
		configPath = os.Getenv("ANTIGRAVITY_CONFIG")
	}
	if configPath == "" {
		home, _ := os.UserHomeDir()
		configPath = home + "/.config/antigravity/proxy_config.json"
	}

	data, err := os.ReadFile(configPath)
	if err != nil {
		return nil
	}

	var cfg struct {
		Mitm struct {
			Hosts []string `json:"hosts"`
		} `json:"mitm"`
	}
	if err := json.Unmarshal(data, &cfg); err != nil {
		return nil
	}
	return cfg.Mitm.Hosts
}
