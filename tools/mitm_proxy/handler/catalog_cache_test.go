package handler

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/KevinLiangX/AntigravityProxyLauncher/mitm_proxy/config"
	"github.com/KevinLiangX/AntigravityProxyLauncher/mitm_proxy/provider"
	"github.com/KevinLiangX/AntigravityProxyLauncher/mitm_proxy/translator"
	"github.com/elazarl/goproxy"
)

// catalogBody builds a payload in the shape the client consumes: a models map
// plus the agentModelSorts groups the picker renders from.
func catalogBody(ids ...string) []byte {
	models := map[string]any{}
	for _, id := range ids {
		models[id] = map[string]any{"displayName": id, "maxTokens": 1048576}
	}
	payload := map[string]any{
		"models": models,
		"agentModelSorts": []any{map[string]any{
			"displayName": "Recommended",
			"groups": []any{map[string]any{
				"displayName": "Models",
				"modelIds":    ids,
			}},
		}},
		"defaultAgentModelId": ids[0],
	}
	out, _ := json.Marshal(payload)
	return out
}

func mustParse(t *testing.T, body []byte) *catalogSnapshot {
	t.Helper()
	snap, err := parseCatalog(body)
	if err != nil {
		t.Fatalf("parseCatalog: %v", err)
	}
	return snap
}

// renderedIDs reports what the client would actually show: sorts ∩ models.
func renderedIDs(t *testing.T, snap *catalogSnapshot) map[string]bool {
	t.Helper()
	visible := map[string]bool{}
	for _, s := range snap.sorts {
		for _, g := range s.Groups {
			for _, id := range g.ModelIDs {
				if snap.hasModel(id) {
					visible[id] = true
				}
			}
		}
	}
	return visible
}

func modelDisabled(t *testing.T, snap *catalogSnapshot, id string) bool {
	t.Helper()
	var details struct {
		Disabled bool `json:"disabled"`
	}
	if err := json.Unmarshal(snap.models[id], &details); err != nil {
		t.Fatalf("unmarshal model %s: %v", id, err)
	}
	return details.Disabled
}

func TestParseCatalog_RejectsUnusableBodies(t *testing.T) {
	for name, body := range map[string][]byte{
		"empty":        nil,
		"not json":     []byte("<html>502</html>"),
		"no models":    []byte(`{"error":"quota"}`),
		"empty models": []byte(`{"models":{}}`),
	} {
		if _, err := parseCatalog(body); err == nil {
			t.Errorf("%s: expected error", name)
		}
	}
}

func TestReconcileCatalog_FirstMissGreysModelOutButKeepsItVisible(t *testing.T) {
	prev := mustParse(t, catalogBody("gemini-4-neon-high", "gemini-4-carbon-high", "claude-sonnet-5-5-high"))
	next := mustParse(t, catalogBody("gemini-4-carbon-high", "claude-sonnet-5-5-high"))

	res := reconcileCatalog(prev, nil, next, nil)

	if !res.Snapshot.hasModel("gemini-4-neon-high") {
		t.Fatal("model missing from the first shrunken response must be kept")
	}
	if !renderedIDs(t, res.Snapshot)["gemini-4-neon-high"] {
		t.Error("kept model must be re-inserted into agentModelSorts, or the picker hides it")
	}
	if !modelDisabled(t, res.Snapshot, "gemini-4-neon-high") {
		t.Error("kept model must be marked disabled so it cannot be selected")
	}
	if res.Miss["gemini-4-neon-high"] != 1 {
		t.Errorf("miss count = %d, want 1", res.Miss["gemini-4-neon-high"])
	}
	if modelDisabled(t, res.Snapshot, "gemini-4-carbon-high") {
		t.Error("models present upstream must stay enabled")
	}
}

func TestReconcileCatalog_SecondMissDropsTheModel(t *testing.T) {
	prev := mustParse(t, catalogBody("gemini-4-neon-high", "claude-sonnet-5-5-high"))
	next := mustParse(t, catalogBody("claude-sonnet-5-5-high"))

	res := reconcileCatalog(prev, map[string]int{"gemini-4-neon-high": 1}, next, nil)

	if res.Snapshot.hasModel("gemini-4-neon-high") {
		t.Error("model absent for maxCatalogMisses responses must be dropped")
	}
	if renderedIDs(t, res.Snapshot)["gemini-4-neon-high"] {
		t.Error("dropped model must not linger in the sorts")
	}
	if len(res.Dropped) != 1 || res.Dropped[0] != "gemini-4-neon-high" {
		t.Errorf("dropped = %v, want [gemini-4-neon-high]", res.Dropped)
	}
	if _, ok := res.Miss["gemini-4-neon-high"]; ok {
		t.Error("dropped model must not keep a miss counter")
	}
}

func TestReconcileCatalog_PresenceResetsMissCounter(t *testing.T) {
	prev := mustParse(t, catalogBody("gemini-4-neon-high", "claude-sonnet-5-5-high"))
	next := mustParse(t, catalogBody("gemini-4-neon-high", "claude-sonnet-5-5-high"))

	res := reconcileCatalog(prev, map[string]int{"gemini-4-neon-high": 1}, next, nil)
	if got := res.Miss["gemini-4-neon-high"]; got != 0 {
		t.Errorf("miss count = %d, want 0 after the model reappears", got)
	}
	if modelDisabled(t, res.Snapshot, "gemini-4-neon-high") {
		t.Error("model present upstream must not be disabled")
	}
}

func TestReconcileCatalog_AlternateEndpointRestoresWithoutDisabling(t *testing.T) {
	prev := mustParse(t, catalogBody("gemini-4-neon-high", "claude-sonnet-5-5-high"))
	next := mustParse(t, catalogBody("claude-sonnet-5-5-high"))
	alt := mustParse(t, catalogBody("gemini-4-neon-high", "gemini-4-argon-high", "claude-sonnet-5-5-high"))

	res := reconcileCatalog(prev, map[string]int{"gemini-4-neon-high": 1}, next, alt)

	if !res.Snapshot.hasModel("gemini-4-neon-high") {
		t.Fatal("model the other endpoint still serves must be restored")
	}
	if modelDisabled(t, res.Snapshot, "gemini-4-neon-high") {
		t.Error("restored model must stay enabled: the shrink was a shard artifact")
	}
	if !renderedIDs(t, res.Snapshot)["gemini-4-neon-high"] {
		t.Error("restored model must be back in the sorts")
	}
	if _, ok := res.Miss["gemini-4-neon-high"]; ok {
		t.Error("restored model must not accumulate a miss counter")
	}
}

func TestReconcileCatalog_DoesNotShowSortEntriesWithoutModel(t *testing.T) {
	prev := mustParse(t, catalogBody("gemini-4-neon-high"))
	next := mustParse(t, catalogBody("gemini-4-carbon-high", "claude-sonnet-5-5-high"))
	// next references a model it does not carry — the client logs
	// "Model X not found in available models" and renders nothing for it.
	var payload map[string]any
	if err := json.Unmarshal(next.encode(), &payload); err != nil {
		t.Fatal(err)
	}
	payload["agentModelSorts"] = []any{map[string]any{
		"displayName": "Recommended",
		"groups": []any{map[string]any{
			"displayName": "Models",
			"modelIds":    []string{"gemini-4-carbon-high", "ghost-model"},
		}},
	}}
	next = mustParse(t, mustMarshalBytes(t, payload))

	res := reconcileCatalog(prev, nil, next, nil)
	if renderedIDs(t, res.Snapshot)["ghost-model"] {
		t.Error("sort entries without a model must be pruned")
	}
}

func TestMissingRatio(t *testing.T) {
	prev := mustParse(t, catalogBody("a", "b", "c", "d"))
	next := mustParse(t, catalogBody("a", "b"))
	if got := missingRatio(prev, next); got != 0.5 {
		t.Errorf("missingRatio = %v, want 0.5", got)
	}
	if got := missingRatio(nil, next); got != 0 {
		t.Errorf("missingRatio(nil) = %v, want 0", got)
	}
}

func TestAlternateCatalogHost(t *testing.T) {
	cases := map[string]string{
		"daily-cloudcode-pa.googleapis.com:443": "cloudcode-pa.googleapis.com:443",
		"cloudcode-pa.googleapis.com:443":       "daily-cloudcode-pa.googleapis.com:443",
		"daily-cloudcode-pa.googleapis.com":     "cloudcode-pa.googleapis.com",
		"example.com:443":                       "",
	}
	for in, want := range cases {
		if got := alternateCatalogHost(in); got != want {
			t.Errorf("alternateCatalogHost(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestCatalogStore_DiskRoundTripSurvivesRestart(t *testing.T) {
	isolateCatalogCache(t)
	key := "acct1234"

	store := newCatalogStore()
	snap := mustParse(t, catalogBody("gemini-4-neon-high", "claude-sonnet-5-5-high"))
	snap0 := mustParse(t, catalogBody("claude-sonnet-5-5-high"))
	res := reconcileCatalog(snap, nil, snap0, nil)
	store.store(key, &catalogEntry{
		snapshot:  res.Snapshot,
		header:    http.Header{"Content-Type": {"application/json"}},
		updatedAt: time.Now().Add(-time.Minute).Truncate(time.Second),
		miss:      res.Miss,
		summary:   summarizeAvailableModels(res.Snapshot.encode()),
	})

	// A brand-new store models the proxy restarting: memory is empty, disk is not.
	fresh := newCatalogStore()
	entry := fresh.peek(key)
	if entry == nil {
		t.Fatal("snapshot was not reloaded from disk")
	}
	if !entry.snapshot.hasModel("gemini-4-neon-high") {
		t.Error("greyed model lost across restart")
	}
	if entry.miss["gemini-4-neon-high"] != 1 {
		t.Errorf("miss counter lost across restart: %v", entry.miss)
	}
	if age := time.Since(entry.updatedAt); age < time.Minute {
		t.Errorf("entry age = %v, want the persisted ~1m", age)
	}
}

func TestCatalogStore_LookupHonoursTTL(t *testing.T) {
	isolateCatalogCache(t)
	store := newCatalogStore()
	snap := mustParse(t, catalogBody("a", "b", "c", "d", "e"))
	store.store("acct", &catalogEntry{snapshot: snap, header: http.Header{}, updatedAt: time.Now(), miss: nil})

	if _, _, ok := store.lookup("acct", catalogCacheTTL); !ok {
		t.Error("fresh snapshot should hit")
	}
	old := time.Now().Add(-2 * catalogCacheTTL)
	store.entries["acct"].updatedAt = old
	if _, _, ok := store.lookup("acct", catalogCacheTTL); ok {
		t.Error("snapshot older than the TTL must miss")
	}
}

func TestCatalogAccountKey_IsolatesAccounts(t *testing.T) {
	a := httptest.NewRequest("POST", "https://daily-cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels", nil)
	a.Header.Set("Authorization", "Bearer token-a")
	b := httptest.NewRequest("POST", "https://daily-cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels", nil)
	b.Header.Set("Authorization", "Bearer token-b")
	anon := httptest.NewRequest("POST", "https://daily-cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels", nil)

	if catalogAccountKey(a, nil) == catalogAccountKey(b, nil) {
		t.Error("different accounts must not share a catalog key")
	}
	if catalogAccountKey(anon, nil) != "anon" {
		t.Errorf("unauthenticated key = %q, want anon", catalogAccountKey(anon, nil))
	}
	if bytes.Contains([]byte(catalogAccountKey(a, nil)), []byte("token-a")) {
		t.Error("the token itself must never appear in the key")
	}

	// A refreshed OAuth token with the same project must map to the same key.
	sameProject := httptest.NewRequest("POST", "https://daily-cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels",
		bytes.NewBufferString(`{"project":"rising-fact-p41fc"}`))
	sameProject.Header.Set("Authorization", "Bearer rotated-token")
	first := httptest.NewRequest("POST", "https://daily-cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels",
		bytes.NewBufferString(`{"project":"rising-fact-p41fc"}`))
	first.Header.Set("Authorization", "Bearer token-a")
	if catalogAccountKey(first, []byte(`{"project":"rising-fact-p41fc"}`)) !=
		catalogAccountKey(sameProject, []byte(`{"project":"rising-fact-p41fc"}`)) {
		t.Error("a rotated token must not create a new cache key for the same project")
	}
}

// ---------------------------------------------------------------------------
// End-to-end handler paths with a fake upstream
// ---------------------------------------------------------------------------

type fakeCatalogUpstream struct {
	byHost map[string]func() *http.Response
	seen   []string
}

func (f *fakeCatalogUpstream) RoundTrip(req *http.Request, _ *goproxy.ProxyCtx) (*http.Response, error) {
	host := req.URL.Host
	f.seen = append(f.seen, host)
	if fn, ok := f.byHost[host]; ok {
		return fn(), nil
	}
	return jsonResponse(http.StatusNotFound, []byte(`{"error":"unexpected host"}`)), nil
}

func jsonResponse(status int, body []byte) *http.Response {
	return &http.Response{
		StatusCode:    status,
		ProtoMajor:    1,
		ProtoMinor:    1,
		Header:        http.Header{"Content-Type": {"application/json"}},
		Body:          io.NopCloser(bytes.NewReader(body)),
		ContentLength: int64(len(body)),
	}
}

func newCatalogTestHandler(t *testing.T) *GeminiHandler {
	t.Helper()
	isolateCatalogCache(t)
	return NewGeminiHandler(provider.NewRegistry(), translator.NewRegistry(), routingPtr(&config.RoutingConfig{}))
}

// testProjectBody is the request body used by the fetch helpers; the cache key is
// derived from its project, so seeds must use testCatalogKey().
const testProjectBody = `{"project":"test-project"}`

func testCatalogKey() string {
	return catalogAccountKey(nil, []byte(testProjectBody))
}

func fetchReq(t *testing.T) *http.Request {
	t.Helper()
	return httptest.NewRequest("POST", "https://daily-cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels",
		bytes.NewBufferString(testProjectBody))
}

func TestFetchAvailableModels_SuspiciousShrinkIsCrossChecked(t *testing.T) {
	h := newCatalogTestHandler(t)
	full := catalogBody("gemini-4-neon-high", "gemini-4-carbon-high", "gemini-4-argon-high",
		"claude-sonnet-5-5-high", "gemini-3.8-flash-high", "gemini-3.8-flash-medium",
		"gemini-3.8-flash-low", "gpt-oss-120b-medium")
	shrunken := catalogBody("claude-sonnet-5-5-high", "gemini-3.8-flash-high", "gemini-3.8-flash-medium",
		"gemini-3.8-flash-low", "gpt-oss-120b-medium")

	// Seed an expired-but-present snapshot so the shrink guard has a baseline.
	h.catalog.store(testCatalogKey(), &catalogEntry{
		snapshot:  mustParse(t, full),
		header:    http.Header{"Content-Type": {"application/json"}},
		updatedAt: time.Now().Add(-time.Hour),
	})

	upstream := &fakeCatalogUpstream{byHost: map[string]func() *http.Response{
		"daily-cloudcode-pa.googleapis.com": func() *http.Response { return jsonResponse(200, shrunken) },
		"cloudcode-pa.googleapis.com":       func() *http.Response { return jsonResponse(200, full) },
	}}
	ctx := &goproxy.ProxyCtx{RoundTripper: upstream}

	_, resp := h.Handle(fetchReq(t), ctx)
	if resp == nil || resp.StatusCode != 200 {
		t.Fatalf("expected 200, got %+v", resp)
	}
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatalf("read body: %v", err)
	}
	snap := mustParse(t, body)
	if !snap.hasModel("gemini-4-neon-high") {
		t.Error("gemini-4 model lost despite the other endpoint still serving it")
	}
	if len(upstream.seen) != 2 {
		t.Errorf("expected the shrink to be cross-checked once, hosts seen: %v", upstream.seen)
	}
}

func TestFetchAvailableModels_ErrorStatusIsNotCached(t *testing.T) {
	h := newCatalogTestHandler(t)
	upstream := &fakeCatalogUpstream{byHost: map[string]func() *http.Response{
		"daily-cloudcode-pa.googleapis.com": func() *http.Response {
			return jsonResponse(http.StatusTooManyRequests, []byte(`{"error":{"code":429,"message":"quota"}}`))
		},
	}}
	ctx := &goproxy.ProxyCtx{RoundTripper: upstream}

	_, resp := h.Handle(fetchReq(t), ctx)
	if resp == nil || resp.StatusCode != http.StatusTooManyRequests {
		t.Fatalf("error status must pass through, got %+v", resp)
	}
	io.Copy(io.Discard, resp.Body)
	resp.Body.Close()

	if entry := h.catalog.peek(testCatalogKey()); entry != nil {
		t.Errorf("a %d body must not be cached (got %d models)", resp.StatusCode, entry.snapshot.modelCount())
	}
}

func TestFetchAvailableModels_ServesStaleSnapshotOnUpstreamFailure(t *testing.T) {
	h := newCatalogTestHandler(t)
	stale := mustParse(t, catalogBody("gemini-4-neon-high", "claude-sonnet-5-5-high"))
	h.catalog.store(testCatalogKey(), &catalogEntry{
		snapshot:  stale,
		header:    http.Header{"Content-Type": {"application/json"}},
		updatedAt: time.Now().Add(-time.Hour),
	})
	upstream := &fakeCatalogUpstream{byHost: map[string]func() *http.Response{
		"daily-cloudcode-pa.googleapis.com": func() *http.Response {
			return jsonResponse(http.StatusInternalServerError, []byte(`{"error":"boom"}`))
		},
	}}
	ctx := &goproxy.ProxyCtx{RoundTripper: upstream}

	_, resp := h.Handle(fetchReq(t), ctx)
	if resp == nil {
		t.Fatal("expected a response")
	}
	if resp.StatusCode != 200 {
		t.Fatalf("stale fallback must answer 200, got %d", resp.StatusCode)
	}
	body, _ := io.ReadAll(resp.Body)
	if !mustParse(t, body).hasModel("gemini-4-neon-high") {
		t.Error("stale snapshot not served")
	}
}

func TestFetchAvailableModels_NormalRefreshIsNotCrossChecked(t *testing.T) {
	h := newCatalogTestHandler(t)
	body := catalogBody("gemini-4-neon-high", "gemini-4-carbon-high", "claude-sonnet-5-5-high", "gemini-3.8-flash-high", "gemini-3.8-flash-low")
	h.catalog.store(testCatalogKey(), &catalogEntry{
		snapshot:  mustParse(t, body),
		header:    http.Header{"Content-Type": {"application/json"}},
		updatedAt: time.Now().Add(-time.Hour),
		lastProbe: time.Now(),
	})
	upstream := &fakeCatalogUpstream{byHost: map[string]func() *http.Response{
		"daily-cloudcode-pa.googleapis.com": func() *http.Response { return jsonResponse(200, body) },
	}}
	ctx := &goproxy.ProxyCtx{RoundTripper: upstream}

	_, resp := h.Handle(fetchReq(t), ctx)
	io.Copy(io.Discard, resp.Body)
	if len(upstream.seen) != 1 {
		t.Errorf("a stable catalog must not trigger a second fetch, hosts seen: %v", upstream.seen)
	}
}

func mustMarshalBytes(t *testing.T, v any) []byte {
	t.Helper()
	out, err := json.Marshal(v)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	return out
}

func TestFetchAvailableModels_ColdStartPicksFullestProbe(t *testing.T) {
	h := newCatalogTestHandler(t)
	full := catalogBody("gemini-4-neon-high", "gemini-4-carbon-high", "gemini-4-argon-high",
		"claude-sonnet-5-5-high", "gemini-3.8-flash-high", "gemini-3.8-flash-medium",
		"gemini-3.8-flash-low", "gpt-oss-120b-medium")
	shrunken := catalogBody("claude-sonnet-5-5-high", "gemini-3.8-flash-high", "gemini-3.8-flash-medium",
		"gemini-3.8-flash-low", "gpt-oss-120b-medium")

	calls := 0
	upstream := &fakeCatalogUpstream{byHost: map[string]func() *http.Response{
		"daily-cloudcode-pa.googleapis.com": func() *http.Response {
			calls++
			if calls == 1 {
				return jsonResponse(200, shrunken) // first sample lands in the small bucket
			}
			return jsonResponse(200, full) // a second sample on the same host is fuller
		},
		"cloudcode-pa.googleapis.com": func() *http.Response { return jsonResponse(200, shrunken) },
	}}
	ctx := &goproxy.ProxyCtx{RoundTripper: upstream}

	_, resp := h.Handle(fetchReq(t), ctx)
	if resp == nil || resp.StatusCode != 200 {
		t.Fatalf("expected 200, got %+v", resp)
	}
	body, _ := io.ReadAll(resp.Body)
	snap := mustParse(t, body)
	if !snap.hasModel("gemini-4-neon-high") {
		t.Error("cold start must keep probing until a fuller catalog is found")
	}
	if snap.modelCount() != 8 {
		t.Errorf("models = %d, want the full 8", snap.modelCount())
	}
}

func TestFetchAvailableModels_PeriodicWidenEscapesAShrunkenBaseline(t *testing.T) {
	h := newCatalogTestHandler(t)
	shrunken := catalogBody("claude-sonnet-5-5-high", "gemini-3.8-flash-high", "gemini-3.8-flash-medium",
		"gemini-3.8-flash-low", "gpt-oss-120b-medium")
	full := catalogBody("gemini-4-neon-high", "gemini-4-carbon-high", "gemini-4-argon-high",
		"claude-sonnet-5-5-high", "gemini-3.8-flash-high", "gemini-3.8-flash-medium",
		"gemini-3.8-flash-low", "gpt-oss-120b-medium")

	// The account first sampled the shrunken bucket, so the baseline itself has no
	// gemini-4 models and nothing looks like a shrink on later refreshes.
	h.catalog.store(testCatalogKey(), &catalogEntry{
		snapshot:  mustParse(t, shrunken),
		header:    http.Header{"Content-Type": {"application/json"}},
		updatedAt: time.Now().Add(-time.Hour),
		lastProbe: time.Now().Add(-2 * catalogProbeInterval),
	})
	upstream := &fakeCatalogUpstream{byHost: map[string]func() *http.Response{
		"daily-cloudcode-pa.googleapis.com": func() *http.Response { return jsonResponse(200, shrunken) },
		"cloudcode-pa.googleapis.com":       func() *http.Response { return jsonResponse(200, full) },
	}}
	ctx := &goproxy.ProxyCtx{RoundTripper: upstream}

	_, resp := h.Handle(fetchReq(t), ctx)
	body, _ := io.ReadAll(resp.Body)
	snap := mustParse(t, body)
	if !snap.hasModel("gemini-4-neon-high") {
		t.Error("periodic widen must adopt the fuller catalog")
	}
	if !renderedIDs(t, snap)["gemini-4-neon-high"] {
		t.Error("adopted model must be selectable")
	}
}
