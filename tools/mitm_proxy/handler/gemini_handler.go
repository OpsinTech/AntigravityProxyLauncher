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

	"github.com/KevinLiangX/AntigravityProxyLauncher/mitm_proxy/provider"
	"github.com/KevinLiangX/AntigravityProxyLauncher/mitm_proxy/translator"
	"github.com/elazarl/goproxy"
)

type GeminiHandler struct {
	providerRegistry   *provider.Registry
	translatorRegistry *translator.Registry
	routingConfig      *RoutingConfig
}

func NewGeminiHandler(
	providerRegistry *provider.Registry,
	translatorRegistry *translator.Registry,
	routingConfig *RoutingConfig,
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
	log.Printf("[Gemini] Intercepted API Call: %s %s", r.URL.Host, r.URL.Path)

	if !strings.Contains(r.URL.Path, "streamGenerateContent") &&
		!strings.Contains(r.URL.Path, "generateContent") {
		return h.handlePassthrough(r, ctx)
	}

	bodyBytes, err := io.ReadAll(io.LimitReader(r.Body, maxRequestBodySize))
	if err != nil {
		return r, goproxy.NewResponse(r, "text/plain", http.StatusBadRequest, "Failed to read body")
	}

	modelName := h.extractModelFromBody(bodyBytes)
	if modelName == "" {
		r.Body = io.NopCloser(bytes.NewBuffer(bodyBytes))
		return r, nil
	}

	rule := h.routingConfig.FindMatchingRule(modelName)
	if rule == nil {
		r.Body = io.NopCloser(bytes.NewBuffer(bodyBytes))
		return r, nil
	}

	log.Printf("[Gemini] Detected model: %s", modelName)

	providerConfig := h.routingConfig.GetProvider(rule.TargetProviderID)
	if providerConfig == nil || providerConfig.ApiKey == "" {
		log.Printf("[Gemini] Provider not configured: %s", rule.TargetProviderID)
		r.Body = io.NopCloser(bytes.NewBuffer(bodyBytes))
		return r, nil
	}

	trans := h.translatorRegistry.FindTranslator("gemini", providerConfig.Type)
	if trans == nil {
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
				if events != nil {
					pw.Write(events)
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
	var detect struct {
		Model string `json:"model"`
	}
	if err := json.Unmarshal(body, &detect); err == nil && detect.Model != "" {
		return detect.Model
	}

	var wrapped struct {
		Model string `json:"model"`
	}
	if err := json.Unmarshal(body, &wrapped); err == nil && wrapped.Model != "" {
		return wrapped.Model
	}

	return ""
}
