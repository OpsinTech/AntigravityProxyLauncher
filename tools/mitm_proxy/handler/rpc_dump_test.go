package handler

import (
	"bytes"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestRpcDumpFileName(t *testing.T) {
	cases := map[string]string{
		"/v1internal:listExperiments":      "listExperiments.json",
		"/v1internal:fetchAvailableModels": "fetchAvailableModels.json",
		"v1internal:fetchUserInfo":         "fetchUserInfo.json",
		"/v1:loadCodeAssist":               "loadCodeAssist.json",
		"":                                 "unknown.json",
		"/v1internal:weird%20name":         "weird_20name.json",
	}
	for in, want := range cases {
		if got := rpcDumpFileName(in); got != want {
			t.Errorf("rpcDumpFileName(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestDumpAuxRpcIfRequested(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	dir := filepath.Join(home, ".config", "antigravity")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	payload := `{"experimentIds":[1],"flags":[{"name":"checkpoint-variant","stringValue":"claude-1m_840k"}]}`
	newResp := func(ct string) *http.Response {
		return &http.Response{
			StatusCode: 200,
			Header:     http.Header{"Content-Type": []string{ct}},
			Body:       io.NopCloser(strings.NewReader(payload)),
		}
	}

	// No marker: nothing written, body untouched.
	resp := newResp("application/json")
	dumpAuxRpcIfRequested("/v1internal:listExperiments", resp)
	if b, _ := io.ReadAll(resp.Body); string(b) != payload {
		t.Fatal("body must pass through untouched")
	}
	if _, err := os.Stat(filepath.Join(dir, dumpDirName)); err == nil {
		t.Fatal("no dump without marker")
	}

	// Marker present: written under rpc_dump/, body still intact.
	if err := os.WriteFile(filepath.Join(dir, dumpMarkerName), nil, 0o644); err != nil {
		t.Fatal(err)
	}
	resp = newResp("application/json")
	dumpAuxRpcIfRequested("/v1internal:listExperiments", resp)
	got, err := io.ReadAll(resp.Body)
	if err != nil || !bytes.Equal(got, []byte(payload)) {
		t.Fatalf("body altered or unreadable: %v", err)
	}
	dumped, err := os.ReadFile(filepath.Join(dir, dumpDirName, "listExperiments.json"))
	if err != nil {
		t.Fatalf("dump missing: %v", err)
	}
	if !bytes.Equal(dumped, []byte(payload)) {
		t.Fatal("dump content mismatch")
	}

	// Streaming responses are never buffered.
	dumpAuxRpcIfRequested("/v1internal:streamGenerateContent", newResp("text/event-stream"))
	if _, err := os.Stat(filepath.Join(dir, dumpDirName, "streamGenerateContent.json")); err == nil {
		t.Fatal("event-stream must not be dumped")
	}

	// Second call rewrites the same file rather than accumulating files.
	dumpAuxRpcIfRequested("/v1internal:listExperiments", newResp("application/json"))
	entries, err := os.ReadDir(filepath.Join(dir, dumpDirName))
	if err != nil || len(entries) != 1 {
		t.Fatalf("expected exactly one dump file, got %d (%v)", len(entries), err)
	}
}
