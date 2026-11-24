package provider

import "testing"

// 缺字段 / 畸形 JSON 时只应安静跳过，不能影响请求本身。
func TestLogBodyBreakdownToleratesOddShapes(t *testing.T) {
	big := make([]byte, bodyBreakdownThreshold+1)
	for i := range big {
		big[i] = 'x'
	}
	logBodyBreakdown("test", big)                       // 非 JSON
	logBodyBreakdown("test", []byte(`{"messages":[]}`)) // 太小，直接返回
	logBodyBreakdown("test", append(big[:0], []byte(`{"tools":"not-an-array"}`)...))
}
