package handler

import (
	"net/http"

	"github.com/KevinLiangX/AntigravityProxyLauncher/mitm_proxy/provider"
)

// ExternalAPIHeader 由 main.go 的反向代理打在请求上，用于区分
// 「外部客户端直连 18081」与「MITM 拦截到的本机客户端流量」。
const ExternalAPIHeader = "X-AGL-External-API"

// MarkExternalAPI 根据请求头标记该 provider 请求来自对外接口。
// 目前只有 system 提示词迁移（sanitize_system_prompt）依赖这个标记，
// 以免改动本机客户端（如 Antigravity）经模型映射转发时的消息结构。
func MarkExternalAPI(providerReq *provider.ProviderRequest, r *http.Request) {
	if providerReq != nil && r != nil && r.Header.Get(ExternalAPIHeader) == "1" {
		providerReq.ExternalAPI = true
	}
}
