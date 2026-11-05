package provider

import (
	"bytes"
	"compress/gzip"
	"log"
)

// gzipBodyThreshold 低于该大小不做压缩：小请求体压缩后可能更大，
// 而且省下的时间远小于 CPU 与协商开销。
const gzipBodyThreshold = 256 << 10 // 256KB

// maybeGzipBody 在 provider 开启 options.gzip_request = "true" 且请求体较大时
// 做 gzip 压缩，返回压缩后的字节与是否压缩。
//
// 背景：长上下文请求体可达数 MB，上行是首字延迟的主要组成部分；实测该网关
// 接受 Content-Encoding: gzip（返回 200），真实 agent 请求压缩比约 3.2×。
// 压缩后若体积没有变小，则回退原始字节，避免做无用功。
func maybeGzipBody(body []byte, cfg ProviderConfig) ([]byte, bool) {
	if cfg.Options["gzip_request"] != "true" || len(body) <= gzipBodyThreshold {
		return body, false
	}

	var buf bytes.Buffer
	writer := gzip.NewWriter(&buf)
	if _, err := writer.Write(body); err != nil {
		_ = writer.Close()
		return body, false
	}
	if err := writer.Close(); err != nil {
		return body, false
	}
	if buf.Len() >= len(body) {
		return body, false
	}
	log.Printf("[OpenAI:%s] gzip: request body %d -> %d bytes", cfg.ID, len(body), buf.Len())
	return buf.Bytes(), true
}
