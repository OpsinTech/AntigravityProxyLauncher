package config

import (
	"encoding/json"
	"log"
	"os"
	"strings"
	"time"

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
	SourceType         string `json:"source_type,omitempty"`
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

// IsLicenseValid checks patch_metadata.json for a valid (non-expired) license.
// Returns true if no license info is present (unlicensed mode — backward compatible).
func IsLicenseValid() bool {
	// Find metadata file
	metadataPath := os.Getenv("ANTIGRAVITY_METADATA")
	if metadataPath == "" {
		home, _ := os.UserHomeDir()
		// Try common locations
		baseDir := home + "/Library/Application Support/AntigravityProxy/"
		appIds := []string{"antigravity", "antigravityIDE", "gemini", "agy", "claudeCode", "codex"}
		var latestTime time.Time
		for _, appId := range appIds {
			dir := baseDir + appId + "/metadata/"
			entries, err := os.ReadDir(dir)
			if err != nil {
				continue
			}
			for _, entry := range entries {
				if strings.HasPrefix(entry.Name(), "launcher_patch_metadata_") && strings.HasSuffix(entry.Name(), ".json") {
					info, err := entry.Info()
					if err != nil {
						continue
					}
					if info.ModTime().After(latestTime) {
						latestTime = info.ModTime()
						metadataPath = dir + entry.Name()
					}
				}
			}
		}
	}

	if metadataPath == "" {
		return true // No metadata, allow (unlicensed)
	}

	data, err := os.ReadFile(metadataPath)
	if err != nil {
		return true // Can't read, allow
	}

	var meta struct {
		LicenseExpiresAt *float64 `json:"license_expires_at"`
		LicenseHMAC      string  `json:"license_hmac"`
		LicenseMachineId string  `json:"license_machine_id"`
	}
	if err := json.Unmarshal(data, &meta); err != nil {
		return true // Parse error, allow (old format)
	}

	if meta.LicenseExpiresAt == nil || meta.LicenseHMAC == "" {
		return true // No license fields, allow
	}

	// Check expiration
	now := time.Now().Unix()
	if now > int64(*meta.LicenseExpiresAt) {
		log.Printf("[Config] License expired at %v", time.Unix(int64(*meta.LicenseExpiresAt), 0))
		return false
	}

	return true
}
