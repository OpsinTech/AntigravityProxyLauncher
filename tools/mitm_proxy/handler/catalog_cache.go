package handler

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"
)

// The model catalog returned by `fetchAvailableModels` is the client's runtime
// model configuration, not a static list. The IDE polls it every five minutes
// (refreshUserStatus, both a 5-minute timer and the picker's refresh button) and
// renders the picker as:
//
//	agentModelSorts[].groups[].modelIds  ∩  models
//
// so caching only `models` is useless: an id that is missing from the sorts is
// dropped by the client and logged as "Model X not found in available models".
//
// Our earlier 12h whole-body cache had two failures: it froze a shrunken
// upstream answer (20 of 41 models, all gemini-4-*) for half a day, and it lost
// the snapshot on every proxy restart. The replacement below keeps an
// authoritative snapshot per account, persists it to disk, re-samples a
// suspicious shrink on both endpoints, and drops whatever no endpoint serves.
//
// It never synthesises `disabled`. That was tried and reverted: greying out the
// models an upstream stop serving produced 21 unselectable rows out of 44 on
// 11/28 20:02, which is strictly worse than not rendering them at all.
const (
	// catalogCacheTTL matches the client's own poll cadence: a refresh never
	// serves data older than one polling interval, so the picker, the tier and
	// the account settings are always decided from the same era.
	catalogCacheTTL = 5 * time.Minute

	// minCatalogModels rejects error/placeholder bodies before they reach the
	// cache: a valid catalog is always far larger than this.
	minCatalogModels = 5

	// catalogShrinkGuard is the missing-model ratio above which a response is
	// treated as suspicious (a differently rolled-out backend shard answered
	// instead of a real entitlement change) and re-sampled. 11/27 12:53 lost 20 of
	// 41 models (49%) inside one second.
	catalogShrinkGuard = 0.2

	// catalogExtraSamples is how many extra samples to take on the same host when
	// a catalog looks shrunken or is being seen for the first time. Google picks
	// the rollout bucket per request, so a retry often lands in a full one.
	catalogExtraSamples = 2

	// catalogCacheVersion guards the on-disk format. A snapshot written by an older
	// build is discarded instead of reloaded: version 1 could contain locally
	// synthesised `disabled` flags, and carrying those forward would resurrect the
	// greyed-out picker this version exists to prevent.
	catalogCacheVersion = 2

	// catalogProbeInterval bounds how often the catalog is re-sampled when nothing
	// looks wrong. Without it, an account that first sampled a shrunken bucket
	// would keep that baseline forever: every later answer is identical, so
	// nothing looks like a shrink.
	catalogProbeInterval = 30 * time.Minute

	catalogCacheDirName = "models_cache"
)

// catalogSort mirrors one element of agentModelSorts.
type catalogSort struct {
	DisplayName string             `json:"displayName"`
	Groups      []catalogSortGroup `json:"groups"`
}

// catalogSortGroup mirrors one group of a sort. The client renders group
// displayNames as section headers and group modelIds as the entries.
type catalogSortGroup struct {
	DisplayName string   `json:"displayName"`
	ModelIDs    []string `json:"modelIds"`
}

// catalogSnapshot is a parsed fetchAvailableModels payload. Unknown top-level
// fields are preserved verbatim as raw JSON so a future server-side addition
// survives our rewrite untouched.
type catalogSnapshot struct {
	top       map[string]json.RawMessage
	models    map[string]json.RawMessage
	sorts     []catalogSort
	hasSorts  bool
	tiered    map[string][]string
	hasTiered bool
}

// parseCatalog decodes a payload. It fails when the body is not a JSON object or
// carries no usable `models` map, which is how error bodies and HTML error pages
// are rejected.
func parseCatalog(body []byte) (*catalogSnapshot, error) {
	var top map[string]json.RawMessage
	if err := json.Unmarshal(body, &top); err != nil {
		return nil, err
	}
	rawModels, ok := top["models"]
	if !ok {
		return nil, errNoCatalogModels
	}
	var models map[string]json.RawMessage
	if err := json.Unmarshal(rawModels, &models); err != nil {
		return nil, err
	}
	if len(models) == 0 {
		return nil, errNoCatalogModels
	}

	snap := &catalogSnapshot{top: top, models: models}
	if raw, ok := top["agentModelSorts"]; ok {
		if err := json.Unmarshal(raw, &snap.sorts); err == nil {
			snap.hasSorts = true
		}
	}
	if raw, ok := top["tieredModelIds"]; ok {
		if err := json.Unmarshal(raw, &snap.tiered); err == nil && snap.tiered != nil {
			snap.hasTiered = true
		}
	}
	return snap, nil
}

type catalogError string

func (e catalogError) Error() string { return string(e) }

const errNoCatalogModels = catalogError("catalog has no models")

// encode rebuilds the payload, writing back only the fields a merge may touch.
func (c *catalogSnapshot) encode() []byte {
	top := make(map[string]json.RawMessage, len(c.top)+4)
	for k, v := range c.top {
		top[k] = v
	}
	top["models"] = mustMarshal(c.models)
	if c.hasSorts {
		top["agentModelSorts"] = mustMarshal(c.sorts)
	}
	if c.hasTiered {
		top["tieredModelIds"] = mustMarshal(c.tiered)
	}
	if id := c.defaultAgentModelID(); id != "" {
		top["defaultAgentModelId"] = mustMarshal(id)
	} else {
		delete(top, "defaultAgentModelId")
	}
	return mustMarshal(top)
}

func mustMarshal(v any) json.RawMessage {
	b, err := json.Marshal(v)
	if err != nil {
		return json.RawMessage("null")
	}
	return b
}

func (c *catalogSnapshot) modelCount() int {
	if c == nil {
		return 0
	}
	return len(c.models)
}

func (c *catalogSnapshot) modelIDs() []string {
	ids := make([]string, 0, len(c.models))
	for id := range c.models {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	return ids
}

func (c *catalogSnapshot) hasModel(id string) bool {
	if c == nil {
		return false
	}
	_, ok := c.models[id]
	return ok
}

// defaultAgentModelID returns the payload's default agent model, or "" when it is
// absent or points at a model the catalog does not carry.
func (c *catalogSnapshot) defaultAgentModelID() string {
	raw, ok := c.top["defaultAgentModelId"]
	if !ok {
		return ""
	}
	var id string
	if err := json.Unmarshal(raw, &id); err != nil || !c.hasModel(id) {
		return ""
	}
	return id
}

func (c *catalogSnapshot) sortContains(id string) bool {
	for _, s := range c.sorts {
		for _, g := range s.Groups {
			for _, m := range g.ModelIDs {
				if m == id {
					return true
				}
			}
		}
	}
	return false
}

// ensureInSorts makes id selectable. The most populated group of the first sort
// is the client's "recommended" block; appending there keeps a restored model
// visible instead of burying it in a synthetic section.
func (c *catalogSnapshot) ensureInSorts(id string) {
	if c.sortContains(id) {
		return
	}
	if len(c.sorts) == 0 {
		c.sorts = []catalogSort{{DisplayName: "Models", Groups: []catalogSortGroup{{DisplayName: "Models"}}}}
		c.hasSorts = true
	}
	if len(c.sorts[0].Groups) == 0 {
		name := c.sorts[0].DisplayName
		if name == "" {
			name = "Models"
		}
		c.sorts[0].Groups = []catalogSortGroup{{DisplayName: name}}
	}
	best := 0
	for i, g := range c.sorts[0].Groups {
		if len(g.ModelIDs) > len(c.sorts[0].Groups[best].ModelIDs) {
			best = i
		}
	}
	c.sorts[0].Groups[best].ModelIDs = append(c.sorts[0].Groups[best].ModelIDs, id)
}

// pruneSorts drops sort entries whose model is absent from models: the client
// warns about every such id and renders nothing for it.
func (c *catalogSnapshot) pruneSorts() {
	if !c.hasSorts {
		return
	}
	for si := range c.sorts {
		for gi := range c.sorts[si].Groups {
			kept := make([]string, 0, len(c.sorts[si].Groups[gi].ModelIDs))
			for _, id := range c.sorts[si].Groups[gi].ModelIDs {
				if c.hasModel(id) {
					kept = append(kept, id)
				}
			}
			c.sorts[si].Groups[gi].ModelIDs = kept
		}
	}
}

// modelDisabledFlag reads a model's own `disabled` flag. The proxy only ever
// passes this through from upstream; it is never written locally.
func modelDisabledFlag(raw json.RawMessage) bool {
	var details struct {
		Disabled bool `json:"disabled"`
	}
	if err := json.Unmarshal(raw, &details); err != nil {
		return false
	}
	return details.Disabled
}

// disabledCount reports how many models the upstream itself marked unavailable,
// for logging only.
func (c *catalogSnapshot) disabledCount() int {
	if c == nil {
		return 0
	}
	n := 0
	for _, raw := range c.models {
		if modelDisabledFlag(raw) {
			n++
		}
	}
	return n
}

// missingRatio reports how much of prev's catalog is absent from next.
func missingRatio(prev, next *catalogSnapshot) float64 {
	if prev == nil || prev.modelCount() == 0 {
		return 0
	}
	missing := 0
	for id := range prev.models {
		if !next.hasModel(id) {
			missing++
		}
	}
	return float64(missing) / float64(prev.modelCount())
}

// reconcileResult is what a merge changed, for logging and tests.
type reconcileResult struct {
	Snapshot *catalogSnapshot
	Restored []string
	Dropped  []string
}

// reconcileCatalog merges a freshly fetched authoritative catalog with the
// previous snapshot. Only two things survive a deletion:
//
//   - a model the alternate endpoint still reports is restored as-is (the shrink
//     was a backend-shard artifact, not an entitlement change);
//   - top-level fields the new response stopped sending are inherited.
//
// A model no endpoint serves any more is dropped. It is NOT re-inserted with
// `disabled: true`: the client renders such a row greyed and unselectable, so
// synthesising the flag turns an upstream entitlement loss into a picker full of
// dead entries (observed 11/28 20:02: 21 of 44 rows greyed). Google's own
// `disabled` flag is passed through untouched either way.
func reconcileCatalog(prev, next, alt *catalogSnapshot) reconcileResult {
	res := reconcileResult{Snapshot: next}
	if next == nil {
		res.Snapshot = prev
		return res
	}
	if prev == nil {
		next.pruneSorts()
		return res
	}

	for id := range prev.models {
		if next.hasModel(id) {
			continue
		}
		if alt != nil && alt.hasModel(id) && !modelDisabledFlag(alt.models[id]) {
			next.models[id] = alt.models[id]
			next.ensureInSorts(id)
			res.Restored = append(res.Restored, id)
			continue
		}
		// Either no endpoint serves it, or the only sample that still carries it
		// reports disabled=true — restoring that would render an unselectable row.
		res.Dropped = append(res.Dropped, id)
	}

	// Top-level fields are authoritative from the new response; anything the new
	// response stopped sending is kept from the previous one.
	for k, v := range prev.top {
		if _, ok := next.top[k]; !ok {
			next.top[k] = v
		}
	}
	if next.hasTiered && prev.hasTiered {
		for tier, ids := range prev.tiered {
			current, ok := next.tiered[tier]
			if !ok {
				next.tiered[tier] = ids
				continue
			}
			seen := make(map[string]bool, len(current))
			for _, id := range current {
				seen[id] = true
			}
			for _, id := range ids {
				if !seen[id] && next.hasModel(id) {
					current = append(current, id)
				}
			}
			next.tiered[tier] = current
		}
	}

	next.pruneSorts()
	sort.Strings(res.Restored)
	sort.Strings(res.Dropped)
	return res
}

// ---------------------------------------------------------------------------
// Snapshot storage (memory + disk, per account)
// ---------------------------------------------------------------------------

// catalogEntry is one account's cached snapshot.
type catalogEntry struct {
	snapshot  *catalogSnapshot
	header    http.Header
	updatedAt time.Time
	summary   string
	// lastProbe is when the catalog was last cross-checked against the other
	// endpoint (cold start, shrink arbitration, or the periodic widen).
	lastProbe time.Time
}

// catalogStore keeps the per-account snapshots. Entries are keyed by an account
// fingerprint so switching Google accounts (or tiers) never serves the previous
// account's catalog.
type catalogStore struct {
	mu      sync.Mutex
	entries map[string]*catalogEntry
	locks   map[string]*sync.Mutex
}

func newCatalogStore() *catalogStore {
	return &catalogStore{
		entries: make(map[string]*catalogEntry),
		locks:   make(map[string]*sync.Mutex),
	}
}

// lockAccount serialises catalog refreshes for one account, so two concurrent
// client requests cannot both go upstream and let the smaller answer win.
func (s *catalogStore) lockAccount(key string) func() {
	s.mu.Lock()
	mu, ok := s.locks[key]
	if !ok {
		mu = &sync.Mutex{}
		s.locks[key] = mu
	}
	s.mu.Unlock()
	mu.Lock()
	return mu.Unlock
}

// lookup returns the entry when it is younger than ttl.
func (s *catalogStore) lookup(key string, ttl time.Duration) (*catalogEntry, time.Duration, bool) {
	entry := s.peek(key)
	if entry == nil {
		return nil, 0, false
	}
	age := time.Since(entry.updatedAt)
	if age > ttl {
		return entry, age, false
	}
	return entry, age, true
}

// peek returns the entry regardless of age (used for stale-on-error fallback).
func (s *catalogStore) peek(key string) *catalogEntry {
	s.mu.Lock()
	if entry, ok := s.entries[key]; ok {
		s.mu.Unlock()
		return entry
	}
	s.mu.Unlock()

	entry := loadCatalogFromDisk(key)
	if entry == nil {
		return nil
	}
	s.mu.Lock()
	if existing, ok := s.entries[key]; ok {
		s.mu.Unlock()
		return existing
	}
	s.entries[key] = entry
	s.mu.Unlock()
	return entry
}

func (s *catalogStore) store(key string, entry *catalogEntry) {
	s.mu.Lock()
	s.entries[key] = entry
	s.mu.Unlock()
	saveCatalogToDisk(key, entry)
	pruneStaleCatalogFiles(catalogCacheStaleAfter)
}

// catalogCacheStaleAfter drops snapshots nobody refreshed for this long, so the
// fallback keys created by rotated OAuth tokens do not accumulate forever.
const catalogCacheStaleAfter = 7 * 24 * time.Hour

func pruneStaleCatalogFiles(maxAge time.Duration) {
	dir := catalogCacheDir()
	if dir == "" {
		return
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		return
	}
	now := time.Now()
	for _, de := range entries {
		if de.IsDir() || !strings.HasSuffix(de.Name(), ".json") {
			continue
		}
		info, err := de.Info()
		if err != nil || now.Sub(info.ModTime()) < maxAge {
			continue
		}
		path := filepath.Join(dir, de.Name())
		if err := os.Remove(path); err == nil {
			log.Printf("[Gemini] catalog cache: pruned stale snapshot %s", de.Name())
		}
	}
}

// ---------------------------------------------------------------------------
// Account fingerprint and disk layout
// ---------------------------------------------------------------------------

// catalogAccountKey fingerprints the caller so one account's catalog is never
// served to another.
//
// The Cloud Code project is the stable identifier: it survives an OAuth access
// token refresh, which happens roughly hourly and used to split one account into
// a new cache key every hour (observed live: 21 models under one token, 41 under
// the next). The token is only a fallback for requests that arrive before the
// project is resolved, and it is hashed, never stored.
func catalogAccountKey(r *http.Request, body []byte) string {
	if project := catalogProject(body); project != "" {
		sum := sha256.Sum256([]byte(project))
		return "proj-" + hex.EncodeToString(sum[:])[:12]
	}
	auth := ""
	if r != nil {
		auth = r.Header.Get("Authorization")
	}
	if auth == "" {
		return "anon"
	}
	sum := sha256.Sum256([]byte(auth))
	return "tok-" + hex.EncodeToString(sum[:])[:12]
}

// catalogProject extracts the Cloud Code project from the request body, which the
// client sends as {"project":"<id>"}.
func catalogProject(body []byte) string {
	if len(body) == 0 {
		return ""
	}
	var payload struct {
		Project string `json:"project"`
	}
	if err := json.Unmarshal(body, &payload); err != nil {
		return ""
	}
	return strings.TrimSpace(payload.Project)
}

// catalogCacheRoot overrides the on-disk location; tests point it at a temp dir
// so they never touch the user's real cache.
var catalogCacheRoot string

func catalogCacheDir() string {
	if catalogCacheRoot != "" {
		return catalogCacheRoot
	}
	base := antigravityConfigDir()
	if base == "" {
		return ""
	}
	return filepath.Join(base, catalogCacheDirName)
}

func catalogDiskPath(key string) string {
	dir := catalogCacheDir()
	if dir == "" {
		return ""
	}
	return filepath.Join(dir, sanitizeCatalogKey(key)+".json")
}

func sanitizeCatalogKey(key string) string {
	var b strings.Builder
	for _, r := range key {
		switch {
		case r >= 'a' && r <= 'z', r >= 'A' && r <= 'Z', r >= '0' && r <= '9', r == '-', r == '_':
			b.WriteRune(r)
		}
	}
	if b.Len() == 0 {
		return "anon"
	}
	return b.String()
}

type catalogDiskFile struct {
	Version   int             `json:"version"`
	UpdatedAt time.Time       `json:"updatedAt"`
	LastProbe time.Time       `json:"lastProbe,omitempty"`
	Body      json.RawMessage `json:"body"`
}

func loadCatalogFromDisk(key string) *catalogEntry {
	path := catalogDiskPath(key)
	if path == "" {
		return nil
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil
	}
	var file catalogDiskFile
	if err := json.Unmarshal(raw, &file); err != nil || len(file.Body) == 0 {
		return nil
	}
	if file.Version != catalogCacheVersion {
		log.Printf("[Gemini] catalog cache: discarding %s from cache format v%d (want v%d)",
			key, file.Version, catalogCacheVersion)
		if path := catalogDiskPath(key); path != "" {
			os.Remove(path)
		}
		return nil
	}
	snap, err := parseCatalog(file.Body)
	if err != nil {
		return nil
	}
	updatedAt := file.UpdatedAt
	if updatedAt.IsZero() {
		updatedAt = time.Now()
	}
	return &catalogEntry{
		snapshot:  snap,
		header:    http.Header{"Content-Type": {"application/json"}},
		updatedAt: updatedAt,
		summary:   summarizeAvailableModels(file.Body),
		lastProbe: file.LastProbe,
	}
}

func saveCatalogToDisk(key string, entry *catalogEntry) {
	path := catalogDiskPath(key)
	if path == "" || entry == nil || entry.snapshot == nil {
		return
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		log.Printf("[Gemini] catalog cache: cannot create %s: %v", filepath.Dir(path), err)
		return
	}
	payload, err := json.Marshal(catalogDiskFile{
		Version:   catalogCacheVersion,
		UpdatedAt: entry.updatedAt,
		LastProbe: entry.lastProbe,
		Body:      entry.snapshot.encode(),
	})
	if err != nil {
		return
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, payload, 0o644); err != nil {
		log.Printf("[Gemini] catalog cache: cannot write %s: %v", tmp, err)
		return
	}
	if err := os.Rename(tmp, path); err != nil {
		log.Printf("[Gemini] catalog cache: cannot replace %s: %v", path, err)
		os.Remove(tmp)
	}
}

// ---------------------------------------------------------------------------
// Endpoint cross-check
// ---------------------------------------------------------------------------

// alternateCatalogHost returns the other Cloud Code endpoint for a host, or ""
// when the host is not one of the two. Google answers the two from different
// rollout shards, so a shrunken daily answer is often a full prod answer.
func alternateCatalogHost(host string) string {
	name, port := host, ""
	if h, p, ok := strings.Cut(host, ":"); ok {
		name, port = h, p
	}
	switch {
	case strings.Contains(name, "daily-cloudcode-pa"):
		name = "cloudcode-pa.googleapis.com"
	case strings.Contains(name, "cloudcode-pa"):
		name = "daily-cloudcode-pa.googleapis.com"
	default:
		return ""
	}
	if port != "" {
		return name + ":" + port
	}
	return name
}
