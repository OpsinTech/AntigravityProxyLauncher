package provider

import (
	"bufio"
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"sort"
	"strings"
	"sync"
	"time"
)

// JoyCodeProvider implements the Provider interface for the JoyCode IDE's
// private "color gateway" API (JD).
//
// Unlike plain OpenAI-compatible endpoints, JoyCode is NOT reachable with a
// static base URL + Bearer key:
//
//  1. Every request goes to  https://<host>/api?appid=...&functionId=<fn>&t=<ms>&sign=<hex>
//     where sign = HMAC-SHA256(key, sorted-non-empty-values joined by "&").
//  2. Auth is via the IDE login credential: ptKey / loginType / tenant headers
//     (ptKey is stored in this provider's ApiKey field by the launcher UI).
//  3. Chat completions require a queue token: POST model_runtime_prepare first
//     (~60s validity), then chat_completions with an X-Model-Token header.
//  4. The chat endpoint speaks OpenAI wire format, but some models require the
//     chatApiModel name (e.g. "GLM-5.3-agent") instead of the display label
//     ("GLM-5.3"); the provider resolves the mapping from joycode_modelList.
//
// Provider config mapping (launcher UI fields -> gateway inputs):
//   - apiEndpoint -> gateway host (default api-ai.jd.com)
//   - apiKey      -> ptKey login credential (base64)
//   - options["tenant"]  -> tenant header (URL-encoded)
//   - options["appid"]   -> appid query param (default joycode_ide)
//   - options["hmac_key"]-> signing key (default is the one from client 3.0.10)
//   - options["auto_models"] == "true" -> overwrite the configured model list
//     with the live joycode_modelList labels at startup
type JoyCodeProvider struct {
	config     ProviderConfig
	httpClient *http.Client

	baseHost  string
	scheme    string
	ptKey     string
	loginType string
	tenant    string
	appid     string
	hmacKey   string

	mu         sync.Mutex
	modelMap   map[string]string // label -> chatApiModel
	mapTried   bool
	tokenCache map[string]joyCodeToken
}

type joyCodeToken struct {
	token     string
	chatId    string
	expiresAt time.Time
}

// Defaults (reverse-engineered from JoyCode.app 3.0.10; see
// /Users/kevinliangx/Workspace/KevinLiangX/joycode/REPORT.md §3).
const (
	joyCodeDefaultHost   = "api-ai.jd.com"
	joyCodeDefaultAppid  = "joycode_ide"
	joyCodeDefaultHMAC   = "0691a3f0b37b4a85aeb63ad0fc7db3ed"
	joyCodeTokenTTL      = 50 * time.Second // tokens are ~60s valid; refresh early
	joyCodeGatewayPath   = "/api"
)

// functionId -> gateway function routing
const (
	fnModelList     = "joycode_modelList"
	fnModelPrepare  = "model_runtime_prepare"
	fnChatCompletions = "chat_completions"
)

// NewJoyCodeProvider creates a JoyCode provider from its config.
// The model list (and the label->chatApiModel map) is fetched eagerly when
// the login credential looks usable; failures are non-fatal (the configured
// models are kept, names pass through unresolved).
func NewJoyCodeProvider(config ProviderConfig) (Provider, error) {
	if config.ApiKey == "" {
		log.Printf("[JoyCode:%s] Warning: no ptKey (api_key) configured; requests will be rejected", config.ID)
	}

	host := strings.TrimSpace(config.ApiEndpoint)
	if host == "" {
		host = joyCodeDefaultHost
	}
	scheme := "https"
	if idx := strings.Index(host, "://"); idx != -1 {
		if s := host[:idx]; s == "http" || s == "https" {
			scheme = s
		}
		host = host[idx+3:]
	}
	host = strings.TrimSuffix(host, "/")

	appid := joyCodeDefaultAppid
	hmacKey := joyCodeDefaultHMAC
	tenant := ""
	if config.Options != nil {
		if v := config.Options["appid"]; v != "" {
			appid = v
		}
		if v := config.Options["hmac_key"]; v != "" {
			hmacKey = v
		}
		tenant = config.Options["tenant"]
	}

	p := &JoyCodeProvider{
		config:     config,
		httpClient: &http.Client{},
		baseHost:   host,
		scheme:     scheme,
		ptKey:      config.ApiKey,
		loginType:  "", // IDE scenario sends an empty loginType
		tenant:     tenant,
		appid:      appid,
		hmacKey:    hmacKey,
		modelMap:   make(map[string]string),
		tokenCache: make(map[string]joyCodeToken),
	}

	if p.ptKey == "" {
		log.Printf("[JoyCode:%s] Skipping startup model fetch: ptKey not set", config.ID)
		return p, nil
	}
	// Always fetch the label->chatApiModel map: chat calls REQUIRE chatApiModel
	// for several models (e.g. GLM-5.3 -> GLM-5.3-agent). auto_models only
	// controls whether the live list also replaces the configured model list.
	p.autoFetchModels()
	return p, nil
}

// autoFetchModels pulls the live model list. It always refreshes the
// label->chatApiModel map; with auto_models it also replaces config.Models.
func (p *JoyCodeProvider) autoFetchModels() {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if ok := p.fetchModelList(ctx); ok {
		log.Printf("[JoyCode:%s] Fetched %d models (%d label->chatApiModel mappings) from %s",
			p.ID(), len(p.config.Models), len(p.modelMap), p.baseHost)
	} else {
		log.Printf("[JoyCode:%s] Startup model fetch failed, keeping configured models (%d)",
			p.ID(), len(p.config.Models))
	}
}

// ensureModelMap lazily loads the label->chatApiModel mapping on first use.
func (p *JoyCodeProvider) ensureModelMap(ctx context.Context) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.mapTried {
		return
	}
	p.mapTried = true
	if len(p.modelMap) == 0 {
		if !p.fetchModelListLocked(ctx) {
			log.Printf("[JoyCode:%s] Model map unavailable; model names will pass through unresolved", p.ID())
		}
	}
}

func (p *JoyCodeProvider) ID() string {
	return p.config.ID
}

func (p *JoyCodeProvider) Name() string {
	return p.config.Name
}

func (p *JoyCodeProvider) Type() string {
	return "joycode"
}

func (p *JoyCodeProvider) SupportedModels() []string {
	return p.config.Models
}

func (p *JoyCodeProvider) IsModelSupported(model string) bool {
	modelLower := strings.ToLower(model)
	for _, m := range p.config.Models {
		if strings.ToLower(m) == modelLower {
			return true
		}
	}
	// Also accept the raw chatApiModel names.
	p.mu.Lock()
	defer p.mu.Unlock()
	for _, api := range p.modelMap {
		if strings.ToLower(api) == modelLower {
			return true
		}
	}
	return false
}

// resolveModel maps a display label to the chatApiModel the chat endpoint
// requires (identity when the name is already a chatApiModel or unknown).
func (p *JoyCodeProvider) resolveModel(model string) string {
	p.mu.Lock()
	defer p.mu.Unlock()
	if api, ok := p.modelMap[model]; ok {
		return api
	}
	return model
}

// signJoyCodeQuery replicates the client's gateway signature:
// sort non-empty params by key, join their VALUES with "&", HMAC-SHA256 hex.
func signJoyCodeQuery(params map[string]string, key string) string {
	keys := make([]string, 0, len(params))
	for k, v := range params {
		if v == "" {
			continue
		}
		keys = append(keys, k)
	}
	sort.Strings(keys)
	vals := make([]string, 0, len(keys))
	for _, k := range keys {
		vals = append(vals, params[k])
	}
	msg := strings.Join(vals, "&")
	mac := hmac.New(sha256.New, []byte(key))
	mac.Write([]byte(msg))
	return hex.EncodeToString(mac.Sum(nil))
}

// gatewayURL builds the signed gateway URL for a functionId.
func (p *JoyCodeProvider) gatewayURL(functionID string) string {
	params := map[string]string{
		"appid":      p.appid,
		"functionId": functionID,
		"t":          fmt.Sprintf("%d", time.Now().UnixMilli()),
	}
	qs := url.Values{}
	for k, v := range params {
		qs.Set(k, v)
	}
	return fmt.Sprintf("%s://%s%s?%s&sign=%s",
		p.scheme, p.baseHost, joyCodeGatewayPath, qs.Encode(), signJoyCodeQuery(params, p.hmacKey))
}

// newUUID returns an RFC 4122 v4 UUID string (no external dependency).
func newUUID() string {
	b := make([]byte, 16)
	_, _ = rand.Read(b)
	b[6] = (b[6] & 0x0f) | 0x40
	b[8] = (b[8] & 0x3f) | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:16])
}

// doGateway posts a JSON body to a gateway function and returns the raw
// response. Extra headers (e.g. X-Model-Token) are applied on top of the
// standard auth headers. The caller owns and must close resp.Body.
func (p *JoyCodeProvider) doGateway(ctx context.Context, functionID string, body []byte, extraHeaders map[string]string) (*http.Response, error) {
	httpReq, err := http.NewRequestWithContext(ctx, "POST", p.gatewayURL(functionID), strings.NewReader(string(body)))
	if err != nil {
		return nil, fmt.Errorf("failed to create request: %w", err)
	}
	httpReq.Header.Set("Content-Type", "application/json; charset=UTF-8")
	httpReq.Header.Set("ptKey", p.ptKey)
	httpReq.Header.Set("loginType", p.loginType)
	if p.tenant != "" {
		httpReq.Header.Set("tenant", url.QueryEscape(p.tenant))
	}
	for k, v := range extraHeaders {
		httpReq.Header.Set(k, v)
	}
	httpReq.Header.Set("x-ms-client-request-id", newUUID())

	resp, err := p.httpClient.Do(httpReq)
	if err != nil {
		return nil, fmt.Errorf("request failed: %w", err)
	}
	if resp.StatusCode >= 400 {
		defer resp.Body.Close()
		b, _ := io.ReadAll(resp.Body)
		return nil, fmt.Errorf("API error (status %d): %s", resp.StatusCode, string(b))
	}
	return resp, nil
}

// decodeEnvelope checks the {"code":0,"data":...} envelope used by all
// non-streaming gateway endpoints. code 0 and absent (pure OpenAI responses)
// are both success.
func decodeEnvelope(data []byte) (code int, hasCode bool, dataField json.RawMessage, message string) {
	var env struct {
		Code    *int            `json:"code"`
		Data    json.RawMessage `json:"data"`
		Message string          `json:"message"`
	}
	if err := json.Unmarshal(data, &env); err == nil && env.Code != nil {
		return *env.Code, true, env.Data, env.Message
	}
	return 0, false, data, ""
}

// fetchModelList refreshes the label->chatApiModel map and (for auto_models)
// the configured model list. Returns true on success.
func (p *JoyCodeProvider) fetchModelList(ctx context.Context) bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.fetchModelListLocked(ctx)
}

func (p *JoyCodeProvider) fetchModelListLocked(ctx context.Context) bool {
	resp, err := p.doGateway(ctx, fnModelList, []byte("{}"), nil)
	if err != nil {
		log.Printf("[JoyCode:%s] modelList failed: %v", p.ID(), err)
		return false
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return false
	}
	code, hasCode, dataField, message := decodeEnvelope(body)
	if hasCode && code != 0 {
		log.Printf("[JoyCode:%s] modelList code=%d message=%s", p.ID(), code, message)
		return false
	}
	var entries []struct {
		Label        string `json:"label"`
		ChatApiModel string `json:"chatApiModel"`
	}
	if err := json.Unmarshal(dataField, &entries); err != nil {
		log.Printf("[JoyCode:%s] modelList parse failed: %v", p.ID(), err)
		return false
	}
	if len(entries) == 0 {
		return false
	}
	newMap := make(map[string]string, len(entries))
	labels := make([]string, 0, len(entries))
	for _, e := range entries {
		if e.Label == "" {
			continue
		}
		labels = append(labels, e.Label)
		api := e.ChatApiModel
		if api == "" {
			api = e.Label
		}
		newMap[e.Label] = api
	}
	p.modelMap = newMap
	p.mapTried = true
	if p.config.Options == nil || p.config.Options["auto_models"] == "true" {
		p.config.Models = labels
	}
	return true
}

// getModelToken acquires (or reuses) the queue token for a model.
func (p *JoyCodeProvider) getModelToken(ctx context.Context, model string) (string, string, error) {
	p.mu.Lock()
	if e, ok := p.tokenCache[model]; ok && time.Now().Before(e.expiresAt) {
		p.mu.Unlock()
		return e.token, e.chatId, nil
	}
	p.mu.Unlock()

	chatId := newUUID()
	body, _ := json.Marshal(map[string]string{
		"chatId":       chatId,
		"model":        model,
		"chatApiModel": model,
	})
	resp, err := p.doGateway(ctx, fnModelPrepare, body, nil)
	if err != nil {
		return "", "", fmt.Errorf("model prepare failed: %w", err)
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(resp.Body)
	if err != nil {
		return "", "", fmt.Errorf("model prepare: read response failed: %w", err)
	}
	code, hasCode, dataField, message := decodeEnvelope(data)
	if hasCode && code != 0 {
		return "", "", fmt.Errorf("model prepare code=%d: %s", code, message)
	}
	var prep struct {
		Token       string `json:"token"`
		TokenStatus string `json:"tokenStatus"`
	}
	if err := json.Unmarshal(dataField, &prep); err != nil || prep.Token == "" {
		return "", "", fmt.Errorf("model prepare: unexpected response: %s", string(data))
	}

	p.mu.Lock()
	p.tokenCache[model] = joyCodeToken{
		token:     prep.Token,
		chatId:    chatId,
		expiresAt: time.Now().Add(joyCodeTokenTTL),
	}
	p.mu.Unlock()
	log.Printf("[JoyCode:%s] prepare ok: model=%s status=%s", p.ID(), model, prep.TokenStatus)
	return prep.Token, chatId, nil
}

// buildChatBody assembles the OpenAI-format chat body. RawBody passthrough
// (openai->joycode translator) preserves all original fields; struct-based
// requests (gemini/anthropic translators) are rebuilt from normalized fields.
func (p *JoyCodeProvider) buildChatBody(req *ProviderRequest, model, chatId string) ([]byte, error) {
	if len(req.RawBody) > 0 {
		var m map[string]interface{}
		if err := json.Unmarshal(req.RawBody, &m); err != nil {
			return nil, fmt.Errorf("failed to parse raw body: %w", err)
		}
		m["model"] = model
		m["chatId"] = chatId
		m["stream"] = req.Stream
		out, err := json.Marshal(m)
		return out, err
	}
	body := map[string]interface{}{
		"model":    model,
		"chatId":   chatId,
		"messages": req.Messages,
		"stream":   req.Stream,
	}
	if len(req.Tools) > 0 {
		body["tools"] = req.Tools
	}
	return json.Marshal(body)
}

func (p *JoyCodeProvider) SendRequest(ctx context.Context, req *ProviderRequest) (*ProviderResponse, error) {
	model := p.resolveModel(req.Model)
	p.ensureModelMap(ctx)
	// Re-resolve after the map may have loaded lazily.
	model = p.resolveModel(req.Model)

	token, chatId, err := p.getModelToken(ctx, model)
	if err != nil {
		return nil, err
	}

	body, err := p.buildChatBody(req, model, chatId)
	if err != nil {
		return nil, err
	}

	resp, err := p.doGateway(ctx, fnChatCompletions, body, map[string]string{"X-Model-Token": token})
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("failed to read response: %w", err)
	}

	// A 2xx response may still carry an envelope error (code != 0).
	if code, hasCode, _, message := decodeEnvelope(data); hasCode && code != 0 {
		return nil, fmt.Errorf("chat failed (code=%d): %s", code, message)
	}

	var chatResp OpenAIResponse
	if err := json.Unmarshal(data, &chatResp); err != nil {
		return nil, fmt.Errorf("failed to unmarshal response: %w (body: %s)", err, truncate(string(data), 500))
	}
	if len(chatResp.Choices) == 0 {
		return nil, fmt.Errorf("no choices in response: %s", truncate(string(data), 500))
	}

	choice := chatResp.Choices[0]
	out := &ProviderResponse{
		Content:     choice.Message.Content,
		ToolCalls:   choice.Message.ToolCalls,
		RawResponse: data,
	}
	if chatResp.Usage != nil {
		out.Usage = *chatResp.Usage
	}
	return out, nil
}

func (p *JoyCodeProvider) SendStreamRequest(ctx context.Context, req *ProviderRequest) (<-chan StreamChunk, error) {
	model := p.resolveModel(req.Model)
	p.ensureModelMap(ctx)
	model = p.resolveModel(req.Model)

	token, chatId, err := p.getModelToken(ctx, model)
	if err != nil {
		return nil, err
	}

	body, err := p.buildChatBody(req, model, chatId)
	if err != nil {
		return nil, err
	}

	log.Printf("[JoyCode:%s] Request: model=%s (resolved=%s), stream=true, tools=%d, messages=%d",
		p.ID(), req.Model, model, len(req.Tools), len(req.Messages))

	resp, err := p.doGateway(ctx, fnChatCompletions, body, map[string]string{"X-Model-Token": token})
	if err != nil {
		return nil, err
	}

	chunks := make(chan StreamChunk, 100)
	go p.processStream(ctx, resp.Body, chunks)
	return chunks, nil
}

// processStream parses the OpenAI-style SSE stream (data: {...} ... [DONE]).
// Shared shape with OpenAIProvider; duplicated here because it is unexported.
func (p *JoyCodeProvider) processStream(ctx context.Context, body io.ReadCloser, chunks chan<- StreamChunk) {
	defer body.Close()
	defer close(chunks)

	send := func(chunk StreamChunk) bool {
		select {
		case <-ctx.Done():
			return false
		case chunks <- chunk:
			return true
		}
	}

	scanner := bufio.NewScanner(body)
	buf := make([]byte, 0, 1024*1024)
	scanner.Buffer(buf, 1024*1024)
	chunkCount := 0
	for scanner.Scan() {
		select {
		case <-ctx.Done():
			log.Printf("[JoyCode:%s] Stream cancelled by context, chunks=%d", p.ID(), chunkCount)
			return
		default:
		}

		line := scanner.Text()
		if !strings.HasPrefix(line, "data: ") {
			if line != "" && chunkCount == 0 {
				log.Printf("[JoyCode:%s] Non-SSE response line: %s", p.ID(), truncate(line, 300))
			}
			continue
		}

		dataStr := strings.TrimPrefix(line, "data: ")
		if dataStr == "[DONE]" {
			send(StreamChunk{Done: true})
			log.Printf("[JoyCode:%s] Stream completed normally, chunks=%d", p.ID(), chunkCount)
			return
		}

		var streamResp OpenAIStreamResponse
		if err := json.Unmarshal([]byte(dataStr), &streamResp); err != nil {
			log.Printf("[JoyCode:%s] Failed to parse stream chunk: %v (raw: %s)", p.ID(), err, truncate(dataStr, 300))
			continue
		}
		if len(streamResp.Choices) == 0 {
			continue
		}

		delta := streamResp.Choices[0].Delta
		chunk := StreamChunk{
			Delta:        delta.Content,
			ToolCalls:    delta.ToolCalls,
			FinishReason: streamResp.Choices[0].FinishReason,
		}
		if streamResp.Usage != nil {
			chunk.Usage = streamResp.Usage
		}
		chunkCount++
		if !send(chunk) {
			return
		}
	}

	if err := scanner.Err(); err != nil {
		send(StreamChunk{Error: fmt.Errorf("stream interrupted: %w", err)})
	} else {
		log.Printf("[JoyCode:%s] Stream ended without [DONE], chunks=%d", p.ID(), chunkCount)
		send(StreamChunk{Done: true})
	}
}

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n] + "...(truncated)"
}

// RegisterJoyCodeProvider registers the JoyCode provider factory.
func RegisterJoyCodeProvider(registry *Registry) {
	registry.RegisterFactory("joycode", func(config ProviderConfig) (Provider, error) {
		return NewJoyCodeProvider(config)
	})
}
