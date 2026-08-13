package main

import (
	"context"
	"encoding/json"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/KevinLiangX/AntigravityProxyLauncher/mitm_proxy/config"
	"github.com/KevinLiangX/AntigravityProxyLauncher/mitm_proxy/handler"
	"github.com/KevinLiangX/AntigravityProxyLauncher/mitm_proxy/provider"
	"github.com/KevinLiangX/AntigravityProxyLauncher/mitm_proxy/translator"
	"github.com/elazarl/goproxy"
	"github.com/joho/godotenv"
	socks5proxy "golang.org/x/net/proxy"
)

// defaultMitmHosts lists domains that should be MITM-intercepted for model routing.
// These can be overridden via the mitm_hosts field in proxy_config.json.
var defaultMitmHosts = []string{
	"api.openai.com",
	"api.anthropic.com",
	"generativelanguage.googleapis.com",
	"cloudcode-pa.googleapis.com",
}

// mitmHosts is loaded from proxy_config.json at startup, falling back to defaults.
var mitmHosts []string

func loadMitmHosts() {
	mitmHosts = defaultMitmHosts
	hosts := config.LoadMitmHosts()
	if len(hosts) > 0 {
		mitmHosts = hosts
		log.Printf("[MITM] Loaded %d custom MITM hosts from config", len(hosts))
	}
}

// shouldMitm returns true if the host (host:port or bare host) should be MITM'd.
func shouldMitm(host string) bool {
	// Strip port if present
	h := host
	if colonIdx := strings.LastIndex(host, ":"); colonIdx != -1 {
		h = host[:colonIdx]
	}
	for _, mh := range mitmHosts {
		if h == mh || strings.HasSuffix(h, "."+mh) || strings.Contains(h, mh) {
			return true
		}
	}
	return false
}

// conditionalMitm returns a goproxy FuncHttpsHandler that only MITMs
// hosts in the mitmHosts list, tunneling everything else transparently.
func conditionalMitm() goproxy.FuncHttpsHandler {
	return func(host string, ctx *goproxy.ProxyCtx) (*goproxy.ConnectAction, string) {
		if shouldMitm(host) {
			log.Printf("[CONNECT] MITM intercept: %s", host)
			return goproxy.MitmConnect, host
		}
		log.Printf("[CONNECT] Tunnel passthrough: %s", host)
		return goproxy.OkConnect, host
	}
}

func main() {
	// Ensure data dir exists (may be needed before logging writes)
	_ = os.MkdirAll(os.Getenv("HOME") + "/.config/antigravity", 0755)

	// Setup logging with rotation: max 10 MB, keep one backup
	logFile := openLogFile(os.Getenv("HOME") + "/.config/antigravity/mitm_proxy.log")
	if logFile != nil {
		log.SetOutput(io.MultiWriter(logFile, os.Stderr))
	} else {
		log.SetOutput(os.Stderr)
		log.Println("[Warning] Log file unavailable, logging to stderr only")
	}
	log.Println("=== MITM Proxy Starting ===")

	// Load MITM hosts from config (with defaults)
	loadMitmHosts()

	_ = godotenv.Load()

	// Load proxy_config.json to check model_routing_enabled
	if !config.IsModelRoutingEnabled() {
		log.Println("[MITM] model_routing_enabled is false, running in passthrough mode only")
		runPassthroughOnly()
		return
	}

	// Initialize registries
	providerRegistry := provider.NewRegistry()
	translatorRegistry := translator.NewRegistry()
	handlerRegistry := handler.NewRegistry()

	// Register provider factories
	provider.RegisterOpenAIProvider(providerRegistry)

	// Register translators
	translator.RegisterAnthropicToOpenAI(translatorRegistry)
	translator.RegisterGeminiToOpenAI(translatorRegistry)
	translator.RegisterOpenAIToOpenAI(translatorRegistry)

	// Load configuration
	modelRouting := config.LoadModelRouting()
	if len(modelRouting.Providers) == 0 {
		log.Println("[MITM] No routing config found, running in passthrough mode")
		runPassthroughOnly()
		return
	}

	// Create providers from config
	providerConfigs := modelRouting.ToProviderConfigs()
	providerRegistry.LoadProvidersFromConfig(providerConfigs)

	// Sync provider model lists (including models auto-fetched at startup via
	// options.auto_models) back into the routing config so direct model matching
	// and the /v1/models listing reflect runtime-fetched models.
	for i := range modelRouting.Providers {
		p := &modelRouting.Providers[i]
		if !p.Enabled {
			continue
		}
		if inst, err := providerRegistry.GetProvider(p.ID); err == nil {
			p.Models = inst.SupportedModels()
		}
	}

	// Create routing config for handlers
	routingConfig := modelRouting.ToHandlerRoutingConfig()

	// Register handlers
	handlerRegistry.Register(handler.NewAnthropicHandler(providerRegistry, translatorRegistry, &routingConfig))
	handlerRegistry.Register(handler.NewGeminiHandler(providerRegistry, translatorRegistry, &routingConfig))
	handlerRegistry.Register(handler.NewOpenAIHandler(providerRegistry, translatorRegistry, &routingConfig))

	// Create proxy server
	proxy := goproxy.NewProxyHttpServer()
	proxy.Verbose = false

	// Configure SOCKS5 proxy for outbound connections (dedicated transport, not global)
	socks5Addr := os.Getenv("SOCKS5_PROXY")
	if socks5Addr == "" {
		socks5Addr = "127.0.0.1:7897"
	}

	socks5Dialer, err := socks5proxy.SOCKS5("tcp", socks5Addr, nil, socks5proxy.Direct)
	if err != nil {
		log.Printf("[Warning] Failed to create SOCKS5 dialer: %v, using direct connection", err)
	} else {
		socks5Transport := &http.Transport{
			DialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
				return socks5Dialer.Dial(network, addr)
			},
			MaxIdleConns:        100,
			MaxIdleConnsPerHost: 10,
			IdleConnTimeout:     90 * time.Second,
		}
		// Set as default for shared HTTP client
		http.DefaultTransport = socks5Transport
		// Set for goproxy transport
		proxy.Tr = socks5Transport
		log.Printf("[MITM] Outbound connections routed through SOCKS5: %s", socks5Addr)
	}

	// Export goproxy CA certificate to absolute paths
	goproxyCA := os.Getenv("GOPROXY_CA_PATH")
	if goproxyCA == "" {
		goproxyCA = os.Getenv("HOME") + "/.config/antigravity/goproxy_ca.pem"
	}
	os.WriteFile(goproxyCA, goproxy.CA_CERT, 0644)
	log.Printf("[MITM] CA certificate exported to %s", goproxyCA)

	// Handle CONNECT requests — only MITM AI API domains, tunnel everything else
	proxy.OnRequest().HandleConnect(conditionalMitm())

	// Log response errors
	proxy.OnResponse().DoFunc(func(resp *http.Response, ctx *goproxy.ProxyCtx) *http.Response {
		if resp != nil && resp.StatusCode >= 400 {
			log.Printf("[RESP-ERR] %s %s → %d", ctx.Req.Method, ctx.Req.URL.String(), resp.StatusCode)
		}
		return resp
	})

	// Main request handler
	proxy.OnRequest().DoFunc(
		func(r *http.Request, ctx *goproxy.ProxyCtx) (*http.Request, *http.Response) {
			if r.URL == nil {
				return r, nil
			}

			// Find matching handler
			h := handlerRegistry.FindHandler(r)
			if h != nil {
				return h.Handle(r, ctx)
			}

			// No handler matched, pass through
			return r, nil
		})

	// Read port from env or default
	port := os.Getenv("MITM_PROXY_PORT")
	if port == "" {
		port = "18081"
	}

	// Wrap proxy for both CONNECT and direct POST
	// Wrap proxy for both CONNECT (forward proxy) and direct POST (reverse proxy).
	// The proxyWrapper enables external clients (e.g. Claude Code pointing
	// ANTHROPIC_BASE_URL / OpenAI base URL at this host:port) to use model routing.
	proxyWrapper := &proxyWrapper{
		goproxy:          proxy,
		handlerRegistry:  handlerRegistry,
		providerRegistry: providerRegistry,
	}

	// Create server with timeouts
	// WriteTimeout=0 for SSE streams (AI responses can exceed 5 minutes).
	// Per-request timeouts are handled by context.WithTimeout in handlers.
	server := &http.Server{
		Addr:         "0.0.0.0:" + port,
		Handler:      proxyWrapper,
		ReadTimeout:  30 * time.Second,
		WriteTimeout: 0, // SSE streams have no fixed duration
		IdleTimeout:  120 * time.Second,
	}

	// Graceful shutdown goroutine
	go func() {
		sigCh := make(chan os.Signal, 1)
		signal.Notify(sigCh, syscall.SIGTERM, syscall.SIGINT)
		sig := <-sigCh
		log.Printf("[MITM] Received signal %v, shutting down gracefully...", sig)
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		server.Shutdown(ctx)
	}()

	listener, err := net.Listen("tcp4", "0.0.0.0:"+port)
	if err != nil {
		log.Fatalf("[MITM] Failed to listen on 0.0.0.0:%s: %v", port, err)
	}
	log.Println("=================================================")
	log.Printf("Antigravity MITM Gateway is running on 0.0.0.0:%s (IPv4)", port)
	log.Println("Intercepting Anthropic, Google & OpenAI API requests...")
	log.Println("=================================================")

	if err := server.Serve(listener); err != http.ErrServerClosed {
		log.Fatalf("[MITM] Server error: %v", err)
	}
	log.Println("[MITM] Server shut down gracefully")
}

// runPassthroughOnly runs the proxy without model routing
func runPassthroughOnly() {
	proxy := goproxy.NewProxyHttpServer()
	proxy.Verbose = false

	// Configure SOCKS5
	socks5Addr := os.Getenv("SOCKS5_PROXY")
	if socks5Addr == "" {
		socks5Addr = "127.0.0.1:7897"
	}
	socks5Dialer, err := socks5proxy.SOCKS5("tcp", socks5Addr, nil, socks5proxy.Direct)
	if err == nil {
		socks5Transport := &http.Transport{
			DialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
				return socks5Dialer.Dial(network, addr)
			},
			MaxIdleConns:        100,
			MaxIdleConnsPerHost: 10,
			IdleConnTimeout:     90 * time.Second,
		}
		http.DefaultTransport = socks5Transport
		proxy.Tr = socks5Transport
	}

	// Passthrough mode: tunnel all CONNECT requests without interception
	proxy.OnRequest().HandleConnect(goproxy.FuncHttpsHandler(func(host string, ctx *goproxy.ProxyCtx) (*goproxy.ConnectAction, string) {
		return goproxy.OkConnect, host
	}))

	port := os.Getenv("MITM_PROXY_PORT")
	if port == "" {
		port = "18081"
	}

	server := &http.Server{
		Addr:         "0.0.0.0:" + port,
		Handler:      proxy,
		ReadTimeout:  30 * time.Second,
		WriteTimeout: 0,
		IdleTimeout:  120 * time.Second,
	}

	go func() {
		sigCh := make(chan os.Signal, 1)
		signal.Notify(sigCh, syscall.SIGTERM, syscall.SIGINT)
		<-sigCh
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		server.Shutdown(ctx)
	}()

	listener, err := net.Listen("tcp4", "0.0.0.0:"+port)
	if err != nil {
		log.Fatalf("[MITM] Failed to listen (passthrough) on 0.0.0.0:%s: %v", port, err)
	}
	log.Println("=================================================")
	log.Printf("Antigravity MITM Gateway (passthrough) is running on 0.0.0.0:%s (IPv4)", port)
	log.Println("=================================================")

	if err := server.Serve(listener); err != http.ErrServerClosed {
		log.Fatalf("[MITM] Server error: %v", err)
	}
}

// openLogFile opens a log file with rotation: if the file exceeds 10 MB,
// it is renamed to .1 (overwriting any previous backup) and a new file is created.
// proxyWrapper handles both forward proxy (CONNECT) and reverse proxy
// (direct POST from external clients, e.g. Claude Code with ANTHROPIC_BASE_URL
// or OpenAI base URL pointing here). This is what enables external access.
type proxyWrapper struct {
	goproxy          *goproxy.ProxyHttpServer
	handlerRegistry  *handler.Registry
	providerRegistry *provider.Registry
}

func (w *proxyWrapper) ServeHTTP(rw http.ResponseWriter, r *http.Request) {
	// Handle direct reverse-proxy API calls (non-CONNECT)
	if r.Method != "CONNECT" {
		// 1. Return OpenAI-compatible model list for GET /v1/models or GET /models
		if r.Method == "GET" && (r.URL.Path == "/v1/models" || r.URL.Path == "/models") {
			w.handleModelsList(rw, r)
			return
		}

		// 2. Set Host hint based on request path if not already set
		path := r.URL.Path
		if strings.Contains(path, "messages") {
			r.URL.Host = "api.anthropic.com"
			r.URL.Scheme = "https"
		} else if strings.Contains(path, "generateContent") || strings.Contains(path, "v1beta") {
			r.URL.Host = "generativelanguage.googleapis.com"
			r.URL.Scheme = "https"
		} else {
			// Default to OpenAI (e.g. /v1/chat/completions or /chat/completions)
			r.URL.Host = "api.openai.com"
			r.URL.Scheme = "https"
		}

		h := w.handlerRegistry.FindHandler(r)
		if h != nil {
			log.Printf("[ReverseProxy] Direct API call: %s %s -> %s", r.Method, r.URL.Path, h.Name())
			ctx := &goproxy.ProxyCtx{Req: r}
			_, resp := h.Handle(r, ctx)
			if resp != nil {
				for k, v := range resp.Header {
				rw.Header()[k] = v
				}
				rw.WriteHeader(resp.StatusCode)
				if resp.Body != nil {
					io.Copy(rw, resp.Body)
					resp.Body.Close()
				}
				return
			}
			rw.WriteHeader(http.StatusBadGateway)
			rw.Header().Set("Content-Type", "application/json")
			rw.Write([]byte(`{"error": {"message": "No route matched for model mapping"}}`))
			return
		}
		log.Printf("[ReverseProxy] No handler for: %s %s", r.Method, r.URL.Path)
		rw.WriteHeader(http.StatusNotFound)
		rw.Header().Set("Content-Type", "application/json")
		rw.Write([]byte(`{"error": {"message": "No handler found for path"}}`))
		return
	}

	// Default: use goproxy for forward proxy (CONNECT) requests
	w.goproxy.ServeHTTP(rw, r)
}

func (w *proxyWrapper) handleModelsList(rw http.ResponseWriter, r *http.Request) {
	modelRouting := config.LoadModelRouting()
	modelSet := make(map[string]bool)

	// Collect models from enabled providers (e.g. CodeBuddy). Prefer the live
	// provider instance so models auto-fetched at startup (options.auto_models)
	// are reflected here too.
	for _, p := range modelRouting.Providers {
		if p.Enabled {
			models := p.Models
			if inst, err := w.providerRegistry.GetProvider(p.ID); err == nil {
				models = inst.SupportedModels()
			}
			for _, m := range models {
				modelSet[m] = true
			}
		}
	}
	// Collect source models from enabled routing rules
	for _, rule := range modelRouting.Rules {
		if rule.Enabled && rule.SourceModelPattern != "" {
			modelSet[rule.SourceModelPattern] = true
		}
	}

	type ModelItem struct {
		ID      string `json:"id"`
		Object  string `json:"object"`
		Created int64  `json:"created"`
		OwnedBy string `json:"owned_by"`
	}
	type ModelsResponse struct {
		Object string      `json:"object"`
		Data   []ModelItem `json:"data"`
	}

	var items []ModelItem
	now := time.Now().Unix()
	for m := range modelSet {
		items = append(items, ModelItem{
			ID:      m,
			Object:  "model",
			Created: now,
			OwnedBy: "antigravity",
		})
	}

	rw.Header().Set("Content-Type", "application/json")
	rw.WriteHeader(http.StatusOK)
	json.NewEncoder(rw).Encode(ModelsResponse{
		Object: "list",
		Data:   items,
	})
}

func openLogFile(path string) *os.File {
	const maxSize = 10 * 1024 * 1024

	if info, err := os.Stat(path); err == nil && info.Size() > maxSize {
		backup := path + ".1"
		os.Remove(backup)
		os.Rename(path, backup)
	}

	f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0644)
	if err != nil {
		log.Printf("[Warning] Cannot open log file %s: %v", path, err)
		return nil
	}
	return f
}
