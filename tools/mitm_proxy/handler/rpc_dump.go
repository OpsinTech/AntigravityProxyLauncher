package handler

import (
	"bytes"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"strings"
)

// Diagnostic-only helper: snapshot the response bodies of the auxiliary
// (non-model) RPCs so their real payloads can be inspected without decompiling.
//
// It is inert unless the marker file exists, and it never modifies a response:
//
//	touch ~/.config/antigravity/dump_rpc
//	# restart the proxy (launcher: 保存并应用), then restart the language server
//	ls ~/.config/antigravity/rpc_dump/
//	grep -l token_threshold ~/.config/antigravity/rpc_dump/* || echo "server never sends it"
//
// Each RPC gets one file, rewritten on every call while the marker exists, so the
// snapshot always holds the most recent payload. Remove the marker to stop.

const (
	dumpMarkerName = "dump_rpc"
	dumpDirName    = "rpc_dump"
	maxDumpBytes   = 16 << 20
)

func antigravityConfigDir() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return filepath.Join(home, ".config", "antigravity")
}

// rpcDumpFileName turns ".../v1internal:listExperiments" into "listExperiments.json".
func rpcDumpFileName(path string) string {
	name := path
	if i := strings.LastIndex(name, ":"); i >= 0 {
		name = name[i+1:]
	}
	if i := strings.LastIndex(name, "/"); i >= 0 {
		name = name[i+1:]
	}
	name = strings.Map(func(r rune) rune {
		switch {
		case r >= 'a' && r <= 'z', r >= 'A' && r <= 'Z', r >= '0' && r <= '9', r == '-', r == '_':
			return r
		}
		return '_'
	}, name)
	if name == "" {
		name = "unknown"
	}
	return name + ".json"
}

// dumpAuxRpcIfRequested writes a copy of the response body to disk when the
// marker file is present. The body is restored afterwards so the client sees it
// intact; a streamed body is left untouched.
func dumpAuxRpcIfRequested(path string, resp *http.Response) {
	if resp == nil || resp.Body == nil {
		return
	}
	dir := antigravityConfigDir()
	if dir == "" {
		return
	}
	if _, err := os.Stat(filepath.Join(dir, dumpMarkerName)); err != nil {
		return
	}
	ct := resp.Header.Get("Content-Type")
	if strings.Contains(ct, "event-stream") || strings.Contains(ct, "octet-stream") {
		return
	}

	body, err := io.ReadAll(io.LimitReader(resp.Body, maxDumpBytes))
	resp.Body.Close()
	resp.Body = io.NopCloser(bytes.NewReader(body))
	if err != nil {
		log.Printf("[RpcDump] read failed for %s: %v", path, err)
		return
	}

	outDir := filepath.Join(dir, dumpDirName)
	if err := os.MkdirAll(outDir, 0o755); err != nil {
		log.Printf("[RpcDump] cannot create %s: %v", outDir, err)
		return
	}
	out := filepath.Join(outDir, rpcDumpFileName(path))
	if err := os.WriteFile(out, body, 0o644); err != nil {
		log.Printf("[RpcDump] write failed for %s: %v", out, err)
		return
	}
	log.Printf("[RpcDump] %s -> %s (%d bytes, status %d)", path, out, len(body), resp.StatusCode)
}
