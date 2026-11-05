package provider

import (
	"bytes"
	"compress/gzip"
	"io"
	"math/rand"
	"testing"
)

func TestMaybeGzipBodyDisabled(t *testing.T) {
	body := bytes.Repeat([]byte("长上下文内容 "), 100000) // ~900KB
	got, compressed := maybeGzipBody(body, ProviderConfig{ID: "codebuddy"})
	if compressed || len(got) != len(body) {
		t.Fatalf("未开启开关时不应压缩")
	}
}

func TestMaybeGzipBodyBelowThreshold(t *testing.T) {
	body := bytes.Repeat([]byte("x"), gzipBodyThreshold-1)
	cfg := ProviderConfig{ID: "codebuddy", Options: map[string]string{"gzip_request": "true"}}
	got, compressed := maybeGzipBody(body, cfg)
	if compressed || len(got) != len(body) {
		t.Fatalf("小于阈值不应压缩")
	}
}

func TestMaybeGzipBodyCompressesLargeBody(t *testing.T) {
	body := bytes.Repeat([]byte(`{"messages":[{"role":"user","content":"请分析这段长上下文并总结"}]}`), 20000)
	cfg := ProviderConfig{ID: "codebuddy", Options: map[string]string{"gzip_request": "true"}}

	got, compressed := maybeGzipBody(body, cfg)
	if !compressed {
		t.Fatalf("超过阈值应压缩")
	}
	if len(got) >= len(body) {
		t.Fatalf("压缩后应更小：%d -> %d", len(body), len(got))
	}

	reader, err := gzip.NewReader(bytes.NewReader(got))
	if err != nil {
		t.Fatalf("解压失败: %v", err)
	}
	restored, err := io.ReadAll(reader)
	if err != nil {
		t.Fatalf("读取解压内容失败: %v", err)
	}
	if !bytes.Equal(restored, body) {
		t.Fatalf("解压后内容与原始不一致")
	}
}

func TestMaybeGzipBodyFallsBackWhenNoGain(t *testing.T) {
	// 随机字节几乎不可压缩，压缩后更大时应回退原字节
	body := make([]byte, gzipBodyThreshold+1024)
	rand.New(rand.NewSource(1)).Read(body)
	cfg := ProviderConfig{ID: "codebuddy", Options: map[string]string{"gzip_request": "true"}}

	got, compressed := maybeGzipBody(body, cfg)
	if compressed {
		t.Fatalf("压缩无收益时应回退")
	}
	if !bytes.Equal(got, body) {
		t.Fatalf("回退内容应与原始一致")
	}
}
