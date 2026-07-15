package handler

import (
	"bytes"
	"compress/gzip"
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
	log.Printf("[Gemini] Intercepted: %s %s", r.URL.Host, r.URL.Path)

	// Always attempt to read body and extract model — don't restrict by path.
	// Cloud Code may use non-standard paths for content generation.
	bodyBytes, err := io.ReadAll(io.LimitReader(r.Body, maxRequestBodySize))
	if err != nil {
		log.Printf("[Gemini] Failed to read body, passing through: %v", err)
		return h.handlePassthrough(r, ctx)
	}

	modelName := h.extractModelFromBody(bodyBytes)
	if modelName == "" {
		log.Printf("[Gemini] No model in body, passing through: %s", r.URL.Path)
		r.Body = io.NopCloser(bytes.NewBuffer(bodyBytes))
		return r, nil
	}

	log.Printf("[Gemini] Detected model: %s, searching routing rules...", modelName)

	rule := h.routingConfig.FindMatchingRule(modelName, "google")
	if rule == nil {
		// Fallback: match rules without source_type restriction (wildcard)
		rule = h.routingConfig.FindMatchingRule(modelName, "")
	}
	if rule == nil {
		log.Printf("[Gemini] No routing rule matched for model=%s, passing through", modelName)
		r.Body = io.NopCloser(bytes.NewBuffer(bodyBytes))
		return r, nil
	}

	log.Printf("[Gemini] Rule matched: %s -> %s @ %s", modelName, rule.TargetModel, rule.TargetProviderID)

	providerConfig := h.routingConfig.GetProvider(rule.TargetProviderID)
	if providerConfig == nil || providerConfig.ApiKey == "" {
		log.Printf("[Gemini] Provider not configured or missing API key: %s", rule.TargetProviderID)
		r.Body = io.NopCloser(bytes.NewBuffer(bodyBytes))
		return r, nil
	}

	trans := h.translatorRegistry.FindTranslator("gemini", providerConfig.Type)
	if trans == nil {
		log.Printf("[Gemini] No translator for gemini->%s", providerConfig.Type)
		r.Body = io.NopCloser(bytes.NewBuffer(bodyBytes))
		return r, nil
	}

	p, err := h.providerRegistry.GetProvider(rule.TargetProviderID)
	if err != nil {
		log.Printf("[Gemini] Provider not found: %s", rule.TargetProviderID)
		r.Body = io.NopCloser(bytes.NewBuffer(bodyBytes))
		return r, nil
	}

	providerReq, err := trans.TranslateRequest(bodyBytes, rule.TargetModel)
	if err != nil {
		log.Printf("[Gemini] Translation failed: %v", err)
		r.Body = io.NopCloser(bytes.NewBuffer(bodyBytes))
		return r, nil
	}

	log.Printf("[Gemini] Translating %s -> %s (provider: %s)", modelName, rule.TargetModel, rule.TargetProviderID)

	if providerReq.Stream {
		streamCtx, streamCancel := context.WithTimeout(context.Background(), 5*time.Minute)
		return h.handleStreamRequest(r, streamCtx, streamCancel, p, providerReq, trans, modelName)
	}
	reqCtx, reqCancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer reqCancel()
	return h.handleNonStreamRequest(r, reqCtx, p, providerReq, trans, modelName)
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

	resp.Header.Del("Content-Encoding")
	resp.ContentLength = int64(len(bodyBytes))
	resp.Body = io.NopCloser(bytes.NewBuffer(bodyBytes))
	return r, resp
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
