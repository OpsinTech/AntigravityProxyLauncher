package main

import (
	"io"
	"net/http"
	"testing"
)

// flushRecorder 记录写入次数与 Flush 次数。
type flushRecorder struct {
	header  http.Header
	writes  int
	flushes int
	written int
}

func (f *flushRecorder) Header() http.Header {
	if f.header == nil {
		f.header = http.Header{}
	}
	return f.header
}
func (f *flushRecorder) Write(p []byte) (int, error) {
	f.writes++
	f.written += len(p)
	return len(p), nil
}
func (f *flushRecorder) WriteHeader(int) {}
func (f *flushRecorder) Flush()          { f.flushes++ }

// chunkReader 按给定分块逐次返回，最后返回 EOF。
type chunkReader struct {
	chunks [][]byte
}

func (c *chunkReader) Read(p []byte) (int, error) {
	if len(c.chunks) == 0 {
		return 0, io.EOF
	}
	n := copy(p, c.chunks[0])
	c.chunks = c.chunks[1:]
	return n, nil
}

func TestStreamCopyWithFlushFlushesEveryChunk(t *testing.T) {
	body := &chunkReader{chunks: [][]byte{
		[]byte("data: one\n\n"),
		[]byte("data: two\n\n"),
		[]byte("data: three\n\n"),
	}}
	rec := &flushRecorder{}

	streamCopyWithFlush(rec, body)

	if rec.writes != 3 {
		t.Fatalf("期望写 3 次，实际 %d", rec.writes)
	}
	// 关键：每块之后都要 Flush，否则 SSE 事件会堆在 bufio 缓冲里直到请求结束
	if rec.flushes != 3 {
		t.Fatalf("期望 Flush 3 次，实际 %d", rec.flushes)
	}
	if rec.written == 0 {
		t.Fatalf("应写出数据")
	}
}

func TestStreamCopyWithFlushWithoutFlusher(t *testing.T) {
	// 不支持 Flush 的 ResponseWriter 不应 panic
	body := &chunkReader{chunks: [][]byte{[]byte("x"), []byte("y")}}
	rec := &noFlushWriter{}

	streamCopyWithFlush(rec, body)

	if rec.written != 2 {
		t.Fatalf("期望写出全部内容，实际 %d 字节", rec.written)
	}
}

type noFlushWriter struct {
	header  http.Header
	written int
}

func (w *noFlushWriter) Header() http.Header {
	if w.header == nil {
		w.header = http.Header{}
	}
	return w.header
}
func (w *noFlushWriter) Write(p []byte) (int, error) {
	w.written += len(p)
	return len(p), nil
}
func (w *noFlushWriter) WriteHeader(int) {}
