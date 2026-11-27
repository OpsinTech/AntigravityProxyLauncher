package handler

import (
	"sync/atomic"

	"github.com/KevinLiangX/AntigravityProxyLauncher/mitm_proxy/config"
)

// routingPtr 把路由配置包成 handler 需要的 atomic 指针（测试辅助）。
func routingPtr(c *config.RoutingConfig) *atomic.Pointer[config.RoutingConfig] {
	p := &atomic.Pointer[config.RoutingConfig]{}
	p.Store(c)
	return p
}
