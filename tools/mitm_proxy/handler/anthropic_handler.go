package handler

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
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

const maxRequestBodySize = 10 * 1024 * 1024 // 10MB

type AnthropicHandler struct {
	providerRegistry   *provider.Registry
	translatorRegistry *translator.Registry
	routingConfig      *RoutingConfig
}

func NewAnthropicHandler(
	providerRegistry *provider.Registry,
	translatorRegistry *translator.Registry,
	routingConfig *RoutingConfig,
) *AnthropicHandler {
	return &AnthropicHandler{
		providerRegistry:   providerRegistry,
		translatorRegistry: translatorRegistry,
		routingConfig:      routingConfig,
	}
}

func (h *AnthropicHandler) Name() string {
	return "Anthropic"
}

func (h *AnthropicHandler) Match(req *http.Request) bool {
	reqHost := req.URL.Host
	if reqHost == "" {
		reqHost = req.Host
	}
	if host, _, ok := strings.Cut(reqHost, ":"); ok {
		reqHost = host
	}
	return strings.Contains(reqHost, "anthropic.com") && strings.Contains(req.URL.Path, "messages")
}

func (h *AnthropicHandler) Handle(r *http.Request, ctx *goproxy.ProxyCtx) (*http.Request, *http.Response) {
	log.Printf("[Anthropic] Intercepted API Call: %s", r.URL.Path)

	bodyBytes, err := io.ReadAll(io.LimitReader(r.Body, maxRequestBodySize))
	if err != nil {
		return r, goproxy.NewResponse(r, "text/plain", http.StatusBadRequest, "Failed to read body")
	}

	var modelDetect struct {
		Model string `json:"model"`
	}
	if err := json.Unmarshal(bodyBytes, &modelDetect); err != nil || modelDetect.Model == "" {
		r.Body = io.NopCloser(bytes.NewBuffer(bodyBytes))
		return r, nil
	}

	log.Printf("[Anthropic] Detected model: %s", modelDetect.Model)

	rule := h.routingConfig.FindMatchingRule(modelDetect.Model)
	if rule == nil {
		r.Body = io.NopCloser(bytes.NewBuffer(bodyBytes))
		return r, nil
	}

	providerConfig := h.routingConfig.GetProvider(rule.TargetProviderID)
	if providerConfig == nil || providerConfig.ApiKey == "" {
		log.Printf("[Anthropic] Provider not configured: %s", rule.TargetProviderID)
		r.Body = io.NopCloser(bytes.NewBuffer(bodyBytes))
		return r, nil
	}

	trans := h.translatorRegistry.FindTranslator("anthropic", providerConfig.Type)
	if trans == nil {
		r.Body = io.NopCloser(bytes.NewBuffer(bodyBytes))
		return r, nil
	}

	p, err := h.providerRegistry.GetProvider(rule.TargetProviderID)
	if err != nil {
		log.Printf("[Anthropic] Provider not found: %s", rule.TargetProviderID)
		r.Body = io.NopCloser(bytes.NewBuffer(bodyBytes))
		return r, nil
	}

	providerReq, err := trans.TranslateRequest(bodyBytes, rule.TargetModel)
	if err != nil {
		log.Printf("[Anthropic] Translation failed: %v", err)
		r.Body = io.NopCloser(bytes.NewBuffer(bodyBytes))
		return r, nil
	}

	log.Printf("[Anthropic] Translating %s -> %s (provider: %s)", modelDetect.Model, rule.TargetModel, rule.TargetProviderID)

	if providerReq.Stream {
		streamCtx, streamCancel := context.WithTimeout(context.Background(), 5*time.Minute)
		return h.handleStreamRequest(r, streamCtx, streamCancel, p, providerReq, trans, modelDetect.Model)
	}
	reqCtx, reqCancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer reqCancel()
	return h.handleNonStreamRequest(r, reqCtx, p, providerReq, trans, modelDetect.Model)
}

func (h *AnthropicHandler) handleNonStreamRequest(
	r *http.Request,
	ctx context.Context,
	p provider.Provider,
	req *provider.ProviderRequest,
	t translator.Translator,
	sourceModel string,
) (*http.Request, *http.Response) {
	resp, err := p.SendRequest(ctx, req)
	if err != nil {
		log.Printf("[Anthropic] Provider error: %v", err)
		return r, goproxy.NewResponse(r, "text/plain", http.StatusBadGateway, "Upstream provider error")
	}

	anthRespBytes, err := t.TranslateResponse(resp, sourceModel)
	if err != nil {
		log.Printf("[Anthropic] Response translation failed: %v", err)
		return r, goproxy.NewResponse(r, "text/plain", http.StatusInternalServerError, "Translation error")
	}

	return r, &http.Response{
		StatusCode: http.StatusOK,
		ProtoMajor: 1,
		ProtoMinor: 1,
		Header:     make(http.Header),
		Body:       io.NopCloser(bytes.NewBuffer(anthRespBytes)),
		Request:    r,
	}
}

func (h *AnthropicHandler) handleStreamRequest(
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
		log.Printf("[Anthropic] Provider stream error: %v", err)
		return r, goproxy.NewResponse(r, "text/plain", http.StatusBadGateway, "Upstream provider error")
	}

	pr, pw := io.Pipe()
	state := translator.NewStreamState()
	msgID := newMsgID()

	go func() {
		defer pw.Close()
		defer cancel()

		startMsg := map[string]interface{}{
			"type": "message_start",
			"message": map[string]interface{}{
				"id":      msgID,
				"type":    "message",
				"role":    "assistant",
				"content": []interface{}{},
				"model":   sourceModel,
			},
		}
		smBytes, _ := json.Marshal(startMsg)
		pw.Write([]byte("event: message_start\ndata: "))
		pw.Write(smBytes)
		pw.Write([]byte("\n\n"))

		for {
			select {
			case <-r.Context().Done():
				return // client disconnected
			case chunk, ok := <-chunks:
				if !ok {
					return
				}
				if chunk.Error != nil {
					log.Printf("[Anthropic] Stream error: %v", chunk.Error)
					return
				}

				if chunk.Usage != nil {
					state.PromptTokens = chunk.Usage.PromptTokens
					state.CompletionTokens = chunk.Usage.CompletionTokens
				}

				events, err := t.TranslateStreamChunk(&chunk, sourceModel, state)
				if err != nil {
					log.Printf("[Anthropic] Chunk translation failed: %v", err)
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

func newMsgID() string {
	b := make([]byte, 12)
	rand.Read(b)
	return "msg_" + hex.EncodeToString(b)
}
