package config

import (
	"encoding/json"
	"log"
	"os"
	"strings"

	"github.com/KevinLiangX/AntigravityProxyLauncher/mitm_proxy/provider"
)

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
type RoutingRule struct {
	SourceModelPattern string `json:"source_model_pattern"`
	TargetModel        string `json:"target_model"`
	TargetProviderID   string `json:"target_provider_id"`
	Enabled            bool   `json:"enabled"`
	Priority           int    `json:"priority,omitempty"`
}

// ModelRouting holds the complete routing configuration.
type ModelRouting struct {
	Version   string         `json:"version"`
	Providers []ProviderEntry `json:"providers"`
	Rules     []RoutingRule   `json:"routing_rules"`
}

// RoutingConfig holds routing rules and provider entries for handler usage.
type RoutingConfig struct {
	Rules     []RoutingRule
	Providers []ProviderEntry
}

// FindMatchingRule finds the first enabled rule matching the given model name.
// Matches by exact model name first, then by source_model_pattern substring.
func (c *RoutingConfig) FindMatchingRule(model string) *RoutingRule {
	modelLower := strings.ToLower(model)
	// First pass: exact match on model name (enabled only)
	for i := range c.Rules {
			if c.Rules[i].SourceModelPattern == "" {
				continue
			}
		if c.Rules[i].Enabled && strings.ToLower(c.Rules[i].SourceModelPattern) == modelLower {
			return &c.Rules[i]
		}
	}
	// Second pass: substring match (enabled only)
	for i := range c.Rules {
			if c.Rules[i].SourceModelPattern == "" {
				continue
			}
		if c.Rules[i].Enabled && strings.Contains(modelLower, strings.ToLower(c.Rules[i].SourceModelPattern)) {
			return &c.Rules[i]
		}
	}
	return nil
}

// GetProvider returns a ProviderEntry by ID (only if enabled).
func (c *RoutingConfig) GetProvider(providerID string) *ProviderEntry {
	for i := range c.Providers {
		if c.Providers[i].ID == providerID && c.Providers[i].Enabled {
			return &c.Providers[i]
		}
	}
	return nil
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
	}
}

// LoadModelRouting loads model routing configuration from the MODEL_ROUTING_CONFIG env var
// or from ~/.config/antigravity/model_routing.json.
func LoadModelRouting() *ModelRouting {
	configPath := os.Getenv("MODEL_ROUTING_CONFIG")
	if configPath == "" {
		configPath = os.Getenv("MR_CONFIG")
	}
	if configPath == "" {
		home, err := os.UserHomeDir()
		if err == nil {
			configPath = home + "/.config/antigravity/model_routing.json"
		}
	}

	routing := &ModelRouting{}

	if configPath == "" {
		log.Println("[Config] No MODEL_ROUTING_CONFIG path available")
		return routing
	}

	data, err := os.ReadFile(configPath)
	if err != nil {
		log.Printf("[Config] Cannot read model routing config at %s: %v", configPath, err)
		return routing
	}

	if err := json.Unmarshal(data, routing); err != nil {
		log.Printf("[Config] Failed to parse model routing config: %v", err)
		return &ModelRouting{}
	}

	log.Printf("[Config] Loaded model routing: %d providers, %d rules", len(routing.Providers), len(routing.Rules))
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
