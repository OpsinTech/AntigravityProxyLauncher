package handler

import (
	"bytes"
	"compress/gzip"
	"context"
	"encoding/json"
	"io"
	"log"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/KevinLiangX/AntigravityProxyLauncher/mitm_proxy/config"
	"github.com/KevinLiangX/AntigravityProxyLauncher/mitm_proxy/provider"
	"github.com/KevinLiangX/AntigravityProxyLauncher/mitm_proxy/translator"
	"github.com/elazarl/goproxy"
)

type GeminiHandler struct {
	providerRegistry   *provider.Registry
	translatorRegistry *translator.Registry
	routingConfig      *config.RoutingConfig
}

func NewGeminiHandler(
	providerRegistry *provider.Registry,
	translatorRegistry *translator.Registry,
	routingConfig *config.RoutingConfig,
) *GeminiHandler {
	return &GeminiHandler{
		providerRegistry:   providerRegistry,
		translatorRegistry: translatorRegistry,
		routingConfig:      routingConfig,
	}
}

func (h *GeminiHandler) Name() string {
	return "Gemini"
}

func (h *GeminiHandler) Match(req *http.Request) bool {
	reqHost := req.URL.Host
	if reqHost == "" {
		reqHost = req.Host
	}
	if host, _, ok := strings.Cut(reqHost, ":"); ok {
		reqHost = host
	}
	return strings.Contains(reqHost, "generativelanguage.googleapis.com") ||
		strings.Contains(reqHost, "cloudcode-pa.googleapis.com")
}

func (h *GeminiHandler) Handle(r *http.Request, ctx *goproxy.ProxyCtx) (*http.Request, *http.Response) {
	// Fast bypass for non-POST requests (GET / HEAD / OPTIONS) — AI generation is always POST
	if r.Method != http.MethodPost && !strings.Contains(r.URL.Path, "fetchAvailableModels") {
		return r, nil
	}

	// Fast bypass for known internal auxiliary/telemetry RPCs that never carry model payloads
	if isNonModelRpc(r.URL.Path) {
		return r, nil
	}

	log.Printf("[Gemini] Intercepted: %s %s", r.URL.Host, r.URL.Path)

	// Always attempt to read body and extract model — don't restrict by path.
	// Cloud Code may use non-standard paths for content generation.
	bodyBytes, err := io.ReadAll(io.LimitReader(r.Body, maxRequestBodySize))
	if err != nil {
		log.Printf("[Gemini] Failed to read body, passing through: %v", err)
		return r, nil
	}

	modelName := h.extractModelFromBody(bodyBytes)
	if modelName == "" {
		r.Body = io.NopCloser(bytes.NewBuffer(bodyBytes))
		if strings.Contains(r.URL.Path, "fetchAvailableModels") {
			return h.handlePassthrough(r, ctx)
		}
		return r, nil
	}

	log.Printf("[Gemini] Detected model: %s, searching routing rules...", modelName)

	rule := h.routingConfig.FindMatchingRule(modelName, "google")
	if rule == nil {
		// Fallback: match rules without source_type restriction (wildcard)
		rule = h.routingConfig.FindMatchingRule(modelName, "")
	}

	var targetProviderID, targetModel string
	if rule != nil {
		targetProviderID, targetModel = h.routingConfig.ResolveLLMRouterTarget(rule, bodyBytes, "gemini")
	} else {
		// Direct model match: check if requested model matches any enabled provider's model (e.g. CodeBuddy)
		for _, p := range h.routingConfig.Providers {
			if !p.Enabled {
				continue
			}
			for _, m := range p.Models {
				if strings.EqualFold(m, modelName) {
					targetProviderID = p.ID
					targetModel = m
					break
				}
			}
			if targetProviderID != "" {
				break
			}
		}
	}

	if targetProviderID == "" || targetModel == "" {
		log.Printf("[Gemini] No routing rule or enabled provider matched for model=%s, passing through", modelName)
		bodyBytes = ensureThoughtSignatures(bodyBytes)
		r.Body = io.NopCloser(bytes.NewBuffer(bodyBytes))
		r.ContentLength = int64(len(bodyBytes))
		r.Header.Set("Content-Length", strconv.Itoa(len(bodyBytes)))
		return r, nil
	}

	log.Printf("[Gemini] Rule matched: %s -> %s @ %s", modelName, targetModel, targetProviderID)

	// Built-in Gemini routing: keep the original Google authentication and Gemini
	// wrapped request format, only substitute the model name, then passthrough.
	// No third-party provider config or API key is required.
	if targetProviderID == config.GeminiBuiltinProviderID {
		if targetModel != "" {
			patched := substituteGeminiModel(bodyBytes, targetModel)
			if patched == nil {
				log.Printf("[Gemini] Failed to substitute model for gemini_builtin, passing through")
				r.Body = io.NopCloser(bytes.NewBuffer(bodyBytes))
				return r, nil
			}
			log.Printf("[Gemini] gemini_builtin: substituting model %s -> %s", modelName, targetModel)
			bodyBytes = patched
		} else {
			log.Printf("[Gemini] gemini_builtin: no target model, passing through unchanged")
		}
		bodyBytes = ensureThoughtSignatures(bodyBytes)
		r.Body = io.NopCloser(bytes.NewBuffer(bodyBytes))
		r.ContentLength = int64(len(bodyBytes))
		r.Header.Set("Content-Length", strconv.Itoa(len(bodyBytes)))
		return r, nil
	}

	// Local model servers (ollama / vllm / llama.cpp) often need no API key,
	// so only a missing provider entry blocks routing here.
	providerConfig := h.routingConfig.GetProvider(targetProviderID)
	if providerConfig == nil {
		log.Printf("[Gemini] Provider not configured: %s", targetProviderID)
		r.Body = io.NopCloser(bytes.NewBuffer(bodyBytes))
		return r, nil
	}

	trans := h.translatorRegistry.FindTranslator("gemini", providerConfig.Type)
	if trans == nil {
		log.Printf("[Gemini] No translator for gemini->%s", providerConfig.Type)
		r.Body = io.NopCloser(bytes.NewBuffer(bodyBytes))
		return r, nil
	}

	p, err := h.providerRegistry.GetProvider(targetProviderID)
	if err != nil {
		log.Printf("[Gemini] Provider not found: %s", targetProviderID)
		r.Body = io.NopCloser(bytes.NewBuffer(bodyBytes))
		return r, nil
	}

	providerReq, err := trans.TranslateRequest(bodyBytes, targetModel)
	if err != nil {
		log.Printf("[Gemini] Translation failed: %v", err)
		r.Body = io.NopCloser(bytes.NewBuffer(bodyBytes))
		return r, nil
	}

	log.Printf("[Gemini] Translating %s -> %s (provider: %s)", modelName, targetModel, targetProviderID)

	if providerReq.Stream {
		streamCtx, streamCancel := context.WithTimeout(context.Background(), 30*time.Minute)
		return h.handleStreamRequest(r, streamCtx, streamCancel, p, providerReq, trans, modelName)
	}
	reqCtx, reqCancel := context.WithTimeout(context.Background(), 5*time.Minute)
	defer reqCancel()
	return h.handleNonStreamRequest(r, reqCtx, p, providerReq, trans, modelName)
}

func isNonModelRpc(path string) bool {
	nonModelPaths := []string{
		"listExperiments",
		"fetchUserInfo",
		"loadCodeAssist",
		"recordTelemetry",
		"recordEvent",
		"checkEligibility",
		"heartbeat",
		"notifications",
	}
	for _, p := range nonModelPaths {
		if strings.Contains(path, p) {
			return true
		}
	}
	return false
}

func (h *GeminiHandler) handlePassthrough(r *http.Request, ctx *goproxy.ProxyCtx) (*http.Request, *http.Response) {
	resp, err := ctx.RoundTrip(r)
	if err != nil {
		log.Printf("[Gemini] Passthrough error: %v", err)
		return r, goproxy.NewResponse(r, "text/plain", http.StatusBadGateway, "Upstream error")
	}
	if resp == nil || resp.Body == nil {
		log.Printf("[Gemini] Passthrough returned nil response or body")
		return r, goproxy.NewResponse(r, "text/plain", http.StatusBadGateway, "Upstream returned empty response")
	}

	// Never buffer streaming SSE or chunked responses
	if resp.Header.Get("Content-Type") == "text/event-stream" || strings.Contains(r.URL.Path, "streamGenerateContent") {
		return r, resp
	}

	bodyBytes, _ := io.ReadAll(resp.Body)
	resp.Body.Close()

	if len(bodyBytes) >= 2 && bodyBytes[0] == 0x1f && bodyBytes[1] == 0x8b {
		gr, gzErr := gzip.NewReader(bytes.NewReader(bodyBytes))
		if gzErr == nil {
			decompressed, err := io.ReadAll(gr)
			gr.Close()
			if err == nil && len(decompressed) > 0 {
				bodyBytes = decompressed
			}
		}
	}

	// Debug aid: log the model list returned by fetchAvailableModels so we can
	// discover the exact model IDs the Cloud Code backend accepts and watch for
	// model ID changes over time. Only the model ID + displayName are logged.
	if strings.Contains(r.URL.Path, "fetchAvailableModels") {
		log.Printf("[Gemini] fetchAvailableModels models: %s", summarizeAvailableModels(bodyBytes))
	}

	resp.Header.Del("Content-Encoding")
	resp.ContentLength = int64(len(bodyBytes))
	resp.Body = io.NopCloser(bytes.NewBuffer(bodyBytes))
	return r, resp
}

// summarizeAvailableModels parses a fetchAvailableModels response body and
// returns a compact "modelId => displayName" list for logging. Falls back to a
// truncated raw dump if the body cannot be parsed.
func summarizeAvailableModels(data []byte) string {
	var payload struct {
		Models map[string]struct {
			DisplayName string `json:"displayName"`
		} `json:"models"`
	}
	if err := json.Unmarshal(data, &payload); err != nil || payload.Models == nil {
		return truncateForLog(data, 2000)
	}

	var keys []string
	for id := range payload.Models {
		keys = append(keys, id)
	}
	sort.Strings(keys)

	var b strings.Builder
	b.WriteString("[" + strconv.Itoa(len(keys)) + "]")
	for _, id := range keys {
		name := payload.Models[id].DisplayName
		if name == "" {
			name = "-"
		}
		b.WriteString(" " + id + "=" + name + ";")
	}
	return b.String()
}

// truncateForLog truncates a byte slice to at most max bytes for logging.
func truncateForLog(data []byte, max int) string {
	if len(data) <= max {
		return string(data)
	}
	return string(data[:max]) + "...(truncated)"
}

func (h *GeminiHandler) handleNonStreamRequest(
	r *http.Request,
	ctx context.Context,
	p provider.Provider,
	req *provider.ProviderRequest,
	t translator.Translator,
	sourceModel string,
) (*http.Request, *http.Response) {
	resp, err := p.SendRequest(ctx, req)
	if err != nil {
		log.Printf("[Gemini] Provider error: %v", err)
		return r, goproxy.NewResponse(r, "text/plain", http.StatusBadGateway, "Upstream provider error")
	}

	geminiRespBytes, err := t.TranslateResponse(resp, sourceModel)
	if err != nil {
		log.Printf("[Gemini] Response translation failed: %v", err)
		return r, goproxy.NewResponse(r, "text/plain", http.StatusInternalServerError, "Translation error")
	}

	return r, &http.Response{
		StatusCode: http.StatusOK,
		ProtoMajor: 1,
		ProtoMinor: 1,
		Header:     make(http.Header),
		Body:       io.NopCloser(bytes.NewBuffer(geminiRespBytes)),
		Request:    r,
	}
}

func (h *GeminiHandler) handleStreamRequest(
	r *http.Request,
	ctx context.Context,
	cancel context.CancelFunc,
	p provider.Provider,
	req *provider.ProviderRequest,
	t translator.Translator,
	sourceModel string,
) (*http.Request, *http.Response) {
	chunks, err := p.SendStreamRequest(ctx, req)
	if err != nil {
		cancel()
		log.Printf("[Gemini] Provider stream error: %v", err)
		return r, goproxy.NewResponse(r, "text/plain", http.StatusBadGateway, "Upstream provider error")
	}

	pr, pw := io.Pipe()
	state := translator.NewStreamState()

	go func() {
		defer pw.Close()
		defer cancel()

		writePipe := func(data []byte) bool {
			_, err := pw.Write(data)
			return err == nil
		}

		for {
			select {
			case <-r.Context().Done():
				return
			case chunk, ok := <-chunks:
				if !ok {
					return
				}
				if chunk.Error != nil {
					log.Printf("[Gemini] Stream error: %v", chunk.Error)
					return
				}

				if chunk.Usage != nil {
					state.PromptTokens = chunk.Usage.PromptTokens
					state.CompletionTokens = chunk.Usage.CompletionTokens
				}

				events, err := t.TranslateStreamChunk(&chunk, sourceModel, state)
				if err != nil {
					log.Printf("[Gemini] Chunk translation failed: %v", err)
					continue
				}
				if events != nil && !writePipe(events) {
					return // client disconnected
				}
			}
		}
	}()

	return r, &http.Response{
		StatusCode: http.StatusOK,
		ProtoMajor: 1,
		ProtoMinor: 1,
		Header: http.Header{
			"Content-Type":  {"text/event-stream"},
			"Cache-Control": {"no-cache"},
			"Connection":    {"keep-alive"},
		},
		Body:          pr,
		Request:       r,
		ContentLength: -1,
	}
}

func (h *GeminiHandler) extractModelFromBody(body []byte) string {
	// Try top-level "model" field (Cloud Code wrapped format)
	var detect struct {
		Model string `json:"model"`
	}
	if err := json.Unmarshal(body, &detect); err == nil && detect.Model != "" {
		return detect.Model
	}

	// Try nested "request.model" (alternative wrapped format)
	var wrapped struct {
		Request struct {
			Model string `json:"model"`
		} `json:"request"`
	}
	if err := json.Unmarshal(body, &wrapped); err == nil && wrapped.Request.Model != "" {
		return wrapped.Request.Model
	}

	return ""
}

// substituteGeminiModel rewrites the "model" field of a Gemini (Cloud Code wrapped)
// request body to targetModel. Handles both top-level "model" and nested
// "request.model" formats. Returns nil if the body cannot be parsed or the model
// field is not found (caller should pass through unchanged).
func substituteGeminiModel(body []byte, targetModel string) []byte {
	var raw map[string]interface{}
	if err := json.Unmarshal(body, &raw); err != nil {
		return nil
	}

	modified := false

	// Top-level model field (Cloud Code wrapped format: {"model": "...", "request": {...}})
	if _, ok := raw["model"].(string); ok {
		raw["model"] = targetModel
		modified = true
	}

	// Nested request.model field
	if req, ok := raw["request"].(map[string]interface{}); ok {
		if _, ok := req["model"].(string); ok {
			req["model"] = targetModel
			modified = true
		}
	}

	if !modified {
		return nil
	}

	patched, err := json.Marshal(raw)
	if err != nil {
		return nil
	}
	return patched
}

// SentinelThoughtSignature is Google's official sentinel token to bypass validation
// when importing conversation history with function calls lacking thought signatures.
const SentinelThoughtSignature = "skip_thought_signature_validator"

// ensureThoughtSignatures scans the request body for any model turns containing
// functionCall parts that lack a thought_signature. If any are found, it injects
// Google's official sentinel value "skip_thought_signature_validator" to prevent
// HTTP 400 Bad Request errors when switching from third-party models to Gemini thinking models.
func ensureThoughtSignatures(body []byte) []byte {
	var raw map[string]interface{}
	if err := json.Unmarshal(body, &raw); err != nil {
		return body
	}

	var contents []interface{}
	// Check if wrapped in "request" (Cloud Code PA format: {"model": "...", "request": {"contents": [...]}})
	if reqMap, ok := raw["request"].(map[string]interface{}); ok {
		if c, ok := reqMap["contents"].([]interface{}); ok {
			contents = c
		}
	}
	// Direct Gemini format
	if contents == nil {
		if c, ok := raw["contents"].([]interface{}); ok {
			contents = c
		}
	}

	if len(contents) == 0 {
		return body
	}

	modifiedCount := 0
	for _, item := range contents {
		turn, ok := item.(map[string]interface{})
		if !ok {
			continue
		}
		role, _ := turn["role"].(string)
		if role != "model" {
			continue
		}
		parts, ok := turn["parts"].([]interface{})
		if !ok {
			continue
		}
		for _, p := range parts {
			partMap, ok := p.(map[string]interface{})
			if !ok {
				continue
			}
			if partMap["functionCall"] == nil {
				continue
			}
			sig1, _ := partMap["thought_signature"].(string)
			sig2, _ := partMap["thoughtSignature"].(string)
			if sig1 == "" && sig2 == "" {
				partMap["thought_signature"] = SentinelThoughtSignature
				delete(partMap, "thoughtSignature")
				modifiedCount++
			} else if sig2 != "" && sig1 == "" {
				partMap["thought_signature"] = sig2
				delete(partMap, "thoughtSignature")
				modifiedCount++
			} else if sig1 != "" && sig2 != "" {
				delete(partMap, "thoughtSignature")
				modifiedCount++
			}
		}
	}

	if modifiedCount == 0 {
		return body
	}

	patched, err := json.Marshal(raw)
	if err != nil {
		return body
	}
	log.Printf("[Gemini] Injected %s into %d functionCall part(s) lacking thought signature",
		SentinelThoughtSignature, modifiedCount)
	return patched
}
