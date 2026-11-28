package handler

import (
	"sync/atomic"
	"testing"

	"github.com/KevinLiangX/AntigravityProxyLauncher/mitm_proxy/config"
)

// routingPtr 把路由配置包成 handler 需要的 atomic 指针（测试辅助）。
func routingPtr(c *config.RoutingConfig) *atomic.Pointer[config.RoutingConfig] {
	p := &atomic.Pointer[config.RoutingConfig]{}
	p.Store(c)
	return p
}

// isolateCatalogCache points the on-disk catalog cache at a temp dir so tests
// never read or write the real ~/.config/antigravity/models_cache.
func isolateCatalogCache(t *testing.T) {
	t.Helper()
	dir := t.TempDir()
	prev := catalogCacheRoot
	catalogCacheRoot = dir
	t.Cleanup(func() { catalogCacheRoot = prev })
}
