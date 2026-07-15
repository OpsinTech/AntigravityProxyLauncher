package handler

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"log"
	"net/http"
	"strings"
	"time"

	"github.com/KevinLiangX/AntigravityProxyLauncher/mitm_proxy/config"
	"github.com/KevinLiangX/AntigravityProxyLauncher/mitm_proxy/provider"
	"github.com/KevinLiangX/AntigravityProxyLauncher/mitm_proxy/translator"
	"github.com/elazarl/goproxy"
)

// OpenAIHandler intercepts OpenAI-format API requests and routes them
// through configured providers.
type OpenAIHandler struct {
	providerRegistry   *provider.Registry
	translatorRegistry *translator.Registry
	routingConfig      *config.RoutingConfig
}

func NewOpenAIHandler(
	providerRegistry *provider.Registry,
	translatorRegistry *translator.Registry,
	routingConfig *config.RoutingConfig,
) *OpenAIHandler {
	return &OpenAIHandler{
		providerRegistry:   providerRegistry,
		translatorRegistry: translatorRegistry,
		routingConfig:      routingConfig,
	}
}

func (h *OpenAIHandler) Name() string {
	return "OpenAI"
}

// Match checks if the request is an OpenAI-format chat completions request.
// Matches on: api.openai.com, any host with /chat/completions in path,
// or any known OpenAI-compatible endpoint patterns.
func (h *OpenAIHandler) Match(req *http.Request) bool {
	reqHost := req.URL.Host
	if reqHost == "" {
		reqHost = req.Host
	}
	if host, _, ok := strings.Cut(reqHost, ":"); ok {
		reqHost = host
	}

	// Match by host: openai.com or common OpenAI-compatible gateways
	openAIHosts := []string{"api.openai.com", "openai.com"}
	for _, h := range openAIHosts {
		if strings.Contains(reqHost, h) {
			return true
		}
	}

	// Match by path: any /chat/completions endpoint (generic OpenAI-compatible)
	if strings.Contains(req.URL.Path, "chat/completions") {
		return true
	}

	return false
}

func (h *OpenAIHandler) Handle(r *http.Request, ctx *goproxy.ProxyCtx) (*http.Request, *http.Response) {
	log.Printf("[OpenAI] Intercepted: %s %s", r.URL.Host, r.URL.Path)

	bodyBytes, err := io.ReadAll(io.LimitReader(r.Body, maxRequestBodySize))
	if err != nil {
		log.Printf("[OpenAI] Failed to read body: %v", err)
		return r, goproxy.NewResponse(r, "text/plain", http.StatusBadRequest, "Failed to read body")
	}

	// Extract model from OpenAI-format body
	var modelDetect struct {
		Model string `json:"model"`
	}
	if err := json.Unmarshal(bodyBytes, &modelDetect); err != nil || modelDetect.Model == "" {
		r.Body = io.NopCloser(bytes.NewBuffer(bodyBytes))
		return r, nil
	}

	log.Printf("[OpenAI] Detected model: %s", modelDetect.Model)

	// Find matching routing rule
	rule := h.routingConfig.FindMatchingRule(modelDetect.Model, "openai")
	if rule == nil {
		// Fallback: match rules without source_type restriction (wildcard)
		rule = h.routingConfig.FindMatchingRule(modelDetect.Model, "")
	}
	if rule == nil {
		r.Body = io.NopCloser(bytes.NewBuffer(bodyBytes))
		return r, nil
	}

	log.Printf("[OpenAI] Rule matched: %s -> %s @ %s", modelDetect.Model, rule.TargetModel, rule.TargetProviderID)

	// Look up provider
	providerConfig := h.routingConfig.GetProvider(rule.TargetProviderID)
	if providerConfig == nil || providerConfig.ApiKey == "" {
		log.Printf("[OpenAI] Provider not configured: %s", rule.TargetProviderID)
		r.Body = io.NopCloser(bytes.NewBuffer(bodyBytes))
		return r, nil
	}

	// Find translator (openai → provider type)
	trans := h.translatorRegistry.FindTranslator("openai", providerConfig.Type)
	if trans == nil {
		log.Printf("[OpenAI] No translator for openai->%s", providerConfig.Type)
		r.Body = io.NopCloser(bytes.NewBuffer(bodyBytes))
		return r, nil
	}

	p, err := h.providerRegistry.GetProvider(rule.TargetProviderID)
	if err != nil {
		log.Printf("[OpenAI] Provider not found: %s", rule.TargetProviderID)
		r.Body = io.NopCloser(bytes.NewBuffer(bodyBytes))
		return r, nil
	}

	// Translate request
	providerReq, err := trans.TranslateRequest(bodyBytes, rule.TargetModel)
	if err != nil {
		log.Printf("[OpenAI] Translation failed: %v", err)
		r.Body = io.NopCloser(bytes.NewBuffer(bodyBytes))
		return r, nil
	}

	log.Printf("[OpenAI] Translating %s -> %s (provider: %s)", modelDetect.Model, rule.TargetModel, rule.TargetProviderID)

	if providerReq.Stream {
		streamCtx, streamCancel := context.WithTimeout(context.Background(), 5*time.Minute)
		return h.handleStreamRequest(r, streamCtx, streamCancel, p, providerReq, trans, modelDetect.Model)
	}
	reqCtx, reqCancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer reqCancel()
	return h.handleNonStreamRequest(r, reqCtx, p, providerReq, trans, modelDetect.Model)
}

func (h *OpenAIHandler) handleNonStreamRequest(
	r *http.Request,
	ctx context.Context,
	p provider.Provider,
	req *provider.ProviderRequest,
	t translator.Translator,
	sourceModel string,
) (*http.Request, *http.Response) {
	resp, err := p.SendRequest(ctx, req)
	if err != nil {
		log.Printf("[OpenAI] Provider error: %v", err)
		return r, goproxy.NewResponse(r, "text/plain", http.StatusBadGateway, "Upstream provider error")
	}

	// For OpenAI→OpenAI translation with streaming-only providers (e.g. CodeBuddy),
	// SendRequest may fail. We let it bubble up as an error.
	oaiRespBytes, err := t.TranslateResponse(resp, sourceModel)
	if err != nil {
		log.Printf("[OpenAI] Response translation failed: %v", err)
		return r, goproxy.NewResponse(r, "text/plain", http.StatusInternalServerError, "Translation error")
	}

	return r, &http.Response{
		StatusCode: http.StatusOK,
		ProtoMajor: 1,
		ProtoMinor: 1,
		Header:     make(http.Header),
		Body:       io.NopCloser(bytes.NewBuffer(oaiRespBytes)),
		Request:    r,
	}
}

func (h *OpenAIHandler) handleStreamRequest(
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
		log.Printf("[OpenAI] Provider stream error: %v", err)
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
					log.Printf("[OpenAI] Stream error: %v", chunk.Error)
					return
				}

				if chunk.Usage != nil {
					state.PromptTokens = chunk.Usage.PromptTokens
					state.CompletionTokens = chunk.Usage.CompletionTokens
				}

				events, err := t.TranslateStreamChunk(&chunk, sourceModel, state)
				if err != nil {
					log.Printf("[OpenAI] Chunk translation failed: %v", err)
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
