package handler

import (
	"encoding/json"
	"log"
	"strconv"
	"strings"
	"sync"

	"github.com/KevinLiangX/AntigravityProxyLauncher/mitm_proxy/config"
)

// The client (language_server) does not probe a model's context window: it reads
// it from the model catalog it fetched from Google. `fetchAvailableModels`
// returns `models[<modelId>] = ModelDetails`, whose `maxTokens` /
// `maxOutputTokens` are exactly what the agent budgets against — and what drives
// its checkpoint (context compaction) decisions.
//
// When a built-in model id is routed to a different backend (32k instead of 1M),
// the catalog keeps advertising the built-in window, so compaction never fires
// before the upstream rejects the request. These helpers rewrite that catalog in
// flight, per routing rule, so the client's idea of the window matches the model
// that actually answers.
//
// Configuration lives in the routing rule (RoutingRule.Options):
//
//	{
//	  "source_model_pattern": "claude-sonnet-5-5",
//	  "target_provider_id": "my-openai",
//	  "target_model": "qwen3-32b",
//	  "enabled": true,
//	  "options": { "context_window": "32000", "max_output_tokens": "8192" }
//	}
//
// `context_window` maps to ModelDetails.maxTokens, `max_output_tokens` maps to
// ModelDetails.maxOutputTokens. Either key may be omitted; omitted fields keep
// the upstream value.
const (
	optionContextWindow   = "context_window"
	optionMaxOutputTokens = "max_output_tokens"

	// defaultCheckpointThreshold is the token_threshold of all 12 shipped model
	// profiles (verified 50000 in 12/12, binary rodata). It is deliberately NOT
	// rewritten: the client's compaction trigger stays as shipped, so a declared
	// window above it (>= ~71k) compacts normally, and a smaller window only
	// compacts on budget overflow. Models without a profile fall back to a config
	// derived from their catalog maxTokens, so the value here is advisory only.
	defaultCheckpointThreshold int64 = 50000
)

// modelWindowOverride is the resolved window for one client-visible model id.
type modelWindowOverride struct {
	MaxTokens       int64
	HasMaxTokens    bool
	MaxOutputTokens int64
	HasMaxOutput    bool
}

// windowOverrideForModel resolves the override for a model id from the routing
// config. Matching mirrors the request path: exact source_type match first, then
// a wildcard source_type rule.
func (h *GeminiHandler) windowOverrideForModel(modelID string) (modelWindowOverride, bool) {
	if h.routingConfig == nil || strings.TrimSpace(modelID) == "" {
		return modelWindowOverride{}, false
	}
	rule := h.routingConfig.FindMatchingRule(modelID, "google")
	if rule == nil {
		rule = h.routingConfig.FindMatchingRule(modelID, "")
	}
	if rule == nil {
		return modelWindowOverride{}, false
	}
	// Built-in Gemini models keep Google's real catalog window: rewriting it would
	// make the client under-budget a model that is not actually routed anywhere.
	if rule.TargetProviderID == config.GeminiBuiltinProviderID {
		if hasWindowOptions(rule) {
			h.logWindowOnce("builtin:"+modelID, modelWindowOverride{})
		}
		return modelWindowOverride{}, false
	}
	return windowOverrideFromRule(rule)
}

// hasWindowOptions reports whether a rule carries either window key at all, so a
// built-in target is reported once even when the values are malformed.
func hasWindowOptions(rule *config.RoutingRule) bool {
	if rule == nil || len(rule.Options) == 0 {
		return false
	}
	_, hasWindow := rule.Options[optionContextWindow]
	_, hasOutput := rule.Options[optionMaxOutputTokens]
	return hasWindow || hasOutput
}

func windowOverrideFromRule(rule *config.RoutingRule) (modelWindowOverride, bool) {
	if rule == nil || len(rule.Options) == 0 {
		return modelWindowOverride{}, false
	}
	var ov modelWindowOverride
	if raw, ok := rule.Options[optionContextWindow]; ok {
		if v, err := strconv.ParseInt(strings.TrimSpace(raw), 10, 64); err == nil && v > 0 {
			ov.MaxTokens, ov.HasMaxTokens = v, true
		} else {
			log.Printf("[Gemini] model window: invalid %s=%q for %q (want positive integer)", optionContextWindow, raw, rule.SourceModelPattern)
		}
	}
	if raw, ok := rule.Options[optionMaxOutputTokens]; ok {
		if v, err := strconv.ParseInt(strings.TrimSpace(raw), 10, 64); err == nil && v > 0 {
			ov.MaxOutputTokens, ov.HasMaxOutput = v, true
		} else {
			log.Printf("[Gemini] model window: invalid %s=%q for %q (want positive integer)", optionMaxOutputTokens, raw, rule.SourceModelPattern)
		}
	}
	return ov, ov.HasMaxTokens || ov.HasMaxOutput
}

// applyModelWindowOverrides rewrites `maxTokens` / `maxOutputTokens` inside a
// fetchAvailableModels response body. Unknown fields are preserved verbatim as
// raw JSON, so a 1e6-sized value elsewhere is never mangled by float64
// round-tripping. The body is returned unchanged when nothing matched, when it
// is not a JSON object, or when no override applies.
func (h *GeminiHandler) applyModelWindowOverrides(body []byte) []byte {
	if len(body) == 0 || h.routingConfig == nil {
		return body
	}

	var top map[string]json.RawMessage
	if err := json.Unmarshal(body, &top); err != nil {
		return body
	}
	rawModels, ok := top["models"]
	if !ok {
		return body
	}
	var models map[string]json.RawMessage
	if err := json.Unmarshal(rawModels, &models); err != nil {
		return body
	}

	changed := false
	for modelID, rawDetails := range models {
		ov, ok := h.windowOverrideForModel(modelID)
		if !ok {
			continue
		}
		var details map[string]json.RawMessage
		if err := json.Unmarshal(rawDetails, &details); err != nil || len(details) == 0 {
			continue
		}
		if ov.HasMaxTokens {
			details["maxTokens"] = json.RawMessage(strconv.FormatInt(ov.MaxTokens, 10))
		}
		if ov.HasMaxOutput {
			details["maxOutputTokens"] = json.RawMessage(strconv.FormatInt(ov.MaxOutputTokens, 10))
		}
		if ov.HasMaxTokens && ov.HasMaxOutput && ov.MaxOutputTokens >= ov.MaxTokens {
			h.logWindowOnce("invalid:"+modelID, ov)
		}
		// A window at or below the shipped checkpoint trigger means the threshold is
		// unreachable: compaction can only happen through the budget-overflow path.
		if ov.HasMaxTokens && ov.MaxTokens <= defaultCheckpointThreshold {
			h.logWindowOnce("below-threshold:"+modelID, ov)
		}
		// Only the window was lowered: the upstream output allowance may now exceed
		// the whole window. Point at it instead of silently clamping the user's value.
		if ov.HasMaxTokens && !ov.HasMaxOutput {
			if upOut, hadOutput := parseJSONInt(details["maxOutputTokens"]); hadOutput && upOut >= ov.MaxTokens {
				h.logWindowOnce("output>window:"+modelID, modelWindowOverride{
					MaxTokens: ov.MaxTokens, HasMaxTokens: true,
					MaxOutputTokens: upOut, HasMaxOutput: true,
				})
			}
		}
		patched, err := json.Marshal(details)
		if err != nil {
			continue
		}
		models[modelID] = patched
		changed = true
		h.logWindowOnce(modelID, ov)
	}
	if !changed {
		return body
	}

	patchedModels, err := json.Marshal(models)
	if err != nil {
		return body
	}
	top["models"] = patchedModels
	out, err := json.Marshal(top)
	if err != nil {
		return body
	}
	return out
}

// windowLogSeen dedupes the per-response window log: fetchAvailableModels is
// polled repeatedly, so an unconditional log would spam once per poll per model.
var windowLogSeen sync.Map

// logWindowOnce logs the applied window for a model the first time (or after the
// values change), not on every catalog response.
func (h *GeminiHandler) logWindowOnce(key string, ov modelWindowOverride) {
	sig := rawOrDefault(ov.HasMaxTokens, ov.MaxTokens) + "/" + rawOrDefault(ov.HasMaxOutput, ov.MaxOutputTokens)
	if prev, ok := windowLogSeen.Load(key); ok && prev == sig {
		return
	}
	windowLogSeen.Store(key, sig)
	if strings.HasPrefix(key, "builtin:") {
		log.Printf("[Gemini] model window: %s targets the built-in Gemini provider; custom window ignored (built-in models keep the official window)",
			strings.TrimPrefix(key, "builtin:"))
		return
	}
	if strings.HasPrefix(key, "below-threshold:") {
		log.Printf("[Gemini] model window: %s declares maxTokens=%s, below the client's checkpoint trigger (%d); compaction will only run when the budget overflows",
			strings.TrimPrefix(key, "below-threshold:"), rawOrDefault(ov.HasMaxTokens, ov.MaxTokens), defaultCheckpointThreshold)
		return
	}
	if strings.HasPrefix(key, "output>window:") {
		log.Printf("[Gemini] model window: %s keeps upstream maxOutputTokens=%s but the window is %s; consider setting max_output_tokens",
			strings.TrimPrefix(key, "output>window:"), rawOrDefault(ov.HasMaxOutput, ov.MaxOutputTokens),
			rawOrDefault(ov.HasMaxTokens, ov.MaxTokens))
		return
	}
	if strings.HasPrefix(key, "invalid:") {
		log.Printf("[Gemini] model window: maxOutputTokens >= maxTokens for %s (%s); the client will reject or truncate",
			strings.TrimPrefix(key, "invalid:"), sig)
		return
	}
	log.Printf("[Gemini] model window: %s -> maxTokens=%s maxOutputTokens=%s", key,
		rawOrDefault(ov.HasMaxTokens, ov.MaxTokens), rawOrDefault(ov.HasMaxOutput, ov.MaxOutputTokens))
}

// parseJSONInt reads a JSON number (or numeric string) without going through
// float64, so large token counts stay exact.
func parseJSONInt(raw json.RawMessage) (int64, bool) {
	if len(raw) == 0 {
		return 0, false
	}
	text := strings.Trim(strings.TrimSpace(string(raw)), `"`)
	v, err := strconv.ParseInt(text, 10, 64)
	if err != nil {
		return 0, false
	}
	return v, true
}

func rawOrDefault(set bool, v int64) string {
	if !set {
		return "(unchanged)"
	}
	return strconv.FormatInt(v, 10)
}
