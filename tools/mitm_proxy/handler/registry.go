package handler

import (
	"net/http"

	"github.com/elazarl/goproxy"
)

// Handler defines the interface for a request handler that intercepts and
// potentially transforms API requests.
type Handler interface {
	Name() string
	Match(req *http.Request) bool
	Handle(r *http.Request, ctx *goproxy.ProxyCtx) (*http.Request, *http.Response)
}

// Registry manages available request handlers.
type Registry struct {
	handlers []Handler
}

// NewRegistry creates a new handler registry.
func NewRegistry() *Registry {
	return &Registry{
		handlers: make([]Handler, 0),
	}
}

// Register adds a handler to the registry.
func (r *Registry) Register(h Handler) {
	r.handlers = append(r.handlers, h)
}

// FindHandler finds the first handler that matches the given request.
func (r *Registry) FindHandler(req *http.Request) Handler {
	for _, h := range r.handlers {
		if h.Match(req) {
			return h
		}
	}
	return nil
}
