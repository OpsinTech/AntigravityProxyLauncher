package provider

import (
	"bytes"
	"compress/gzip"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// TestGzipRequestEndToEnd 验证大请求体真的以 gzip 发出、且内容可还原。
func TestGzipRequestEndToEnd(t *testing.T) {
	type captured struct {
		encoding string
		body     []byte
	}
	got := make(chan captured, 1)

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		raw, _ := io.ReadAll(r.Body)
		if r.Header.Get("Content-Encoding") == "gzip" {
			reader, err := gzip.NewReader(bytes.NewReader(raw))
			if err == nil {
				if decompressed, err := io.ReadAll(reader); err == nil {
					raw = decompressed
				}
			}
		}
		got <- captured{encoding: r.Header.Get("Content-Encoding"), body: raw}

		w.Header().Set("Content-Type", "text/event-stream")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("data: {\"choices\":[{\"delta\":{\"content\":\"ok\"}}]}\n\ndata: [DONE]\n\n"))
	}))
	defer server.Close()

	p, err := NewOpenAIProvider(ProviderConfig{
		ID:          "codebuddy",
		Type:        "openai",
		ApiEndpoint: strings.TrimPrefix(server.URL, "http://"),
		Options: map[string]string{
			"scheme":       "http",
			"gzip_request": "true",
		},
	})
	if err != nil {
		t.Fatalf("创建 provider 失败: %v", err)
	}

	bigContent := strings.Repeat("请分析这段长上下文并总结要点。", 40000) // ~1.6MB
	rawBody, _ := json.Marshal(map[string]any{
		"model":    "space-bunny",
		"stream":   true,
		"messages": []map[string]string{{"role": "user", "content": bigContent}},
	})

	stream, err := p.SendStreamRequest(context.Background(), &ProviderRequest{
		Model:   "space-bunny",
		Stream:  true,
		RawBody: rawBody,
	})
	if err != nil {
		t.Fatalf("发送失败: %v", err)
	}
	for range stream {
		// 消费完即可
	}

	select {
	case c := <-got:
		if c.encoding != "gzip" {
			t.Fatalf("期望 Content-Encoding: gzip，实际 %q", c.encoding)
		}
		if !bytes.Contains(c.body, []byte("请分析这段长上下文")) {
			t.Fatalf("解压后的请求体内容不完整")
		}
	default:
		t.Fatalf("服务端未收到请求")
	}
}
