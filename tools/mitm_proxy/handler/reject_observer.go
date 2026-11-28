package handler

import (
	"log"
	"net/http"
	"strings"
	"sync"
	"time"
)

// Read-only observation of upstream model rejections.
//
// Request-time eviction was deliberately NOT implemented. A 404 can mean a model
// that was delisted, but it can equally mean region gating, a missing project, a
// gateway HTML page, or a third-party backend that simply does not serve that
// model — and evicting on the status code alone would let one flaky shard delete a
// healthy model from the picker. The catalog already carries Google's own
// "unavailable" signal (`disabled`), and reconcile greys a model out before
// dropping it after maxCatalogMisses consecutive authoritative misses.
//
// This file therefore only records rejections so the decision can be made on
// data: it never mutates the catalog snapshot, the response, or the request.
const rejectObservationWindow = time.Minute

var (
	rejectMu   sync.Mutex
	rejectSeen = map[string]*rejectObservation{}
)

type rejectObservation struct {
	lastLog time.Time
	pending int
}

// rejectLogSink is swapped by tests to capture the emitted line.
var rejectLogSink = func(format string, args ...any) { log.Printf(format, args...) }

// nativeCloudCodeHost reports whether the upstream is Google's Cloud Code /
// Generativelanguage endpoint, where a 404 does speak about the model catalog.
// A third-party provider's 404 means "this backend does not serve that model" and
// says nothing about what Google offers.
func nativeCloudCodeHost(host string) bool {
	return strings.Contains(host, "cloudcode-pa") || strings.Contains(host, "generativelanguage")
}

// observeModelRejection logs a 404 for a concrete model id, deduped to one line
// per model+upstream per minute and carrying how many rejections happened since
// the previous line. Everything it needs is already on the response head, so it
// also covers streamGenerateContent (which is forwarded unbuffered).
func observeModelRejection(modelName string, r *http.Request, resp *http.Response) {
	if modelName == "" || r == nil || resp == nil || resp.StatusCode != http.StatusNotFound {
		return
	}
	host := r.URL.Host
	if host == "" {
		host = r.Host
	}
	path := r.URL.Path
	native := nativeCloudCodeHost(host)
	key := modelName + "|" + host
	now := time.Now()

	rejectMu.Lock()
	obs, ok := rejectSeen[key]
	if !ok {
		obs = &rejectObservation{}
		rejectSeen[key] = obs
	}
	obs.pending++
	shouldLog := obs.lastLog.IsZero() || now.Sub(obs.lastLog) >= rejectObservationWindow
	count := obs.pending
	if shouldLog {
		obs.lastLog = now
		obs.pending = 0
	}
	rejectMu.Unlock()

	if !shouldLog {
		return
	}
	rejectLogSink("[Gemini] model rejected: %s (status=404 native=%t upstream=%s count=%d path=%s)",
		modelName, native, host, count, path)
}

// resetRejectObservations clears the dedupe state. Test-only helper.
func resetRejectObservations() {
	rejectMu.Lock()
	rejectSeen = map[string]*rejectObservation{}
	rejectMu.Unlock()
}
