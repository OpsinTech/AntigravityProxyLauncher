package main

import (
	"encoding/binary"
	"testing"
)

// buildClientHello 构造一个最小但结构完整的 TLS ClientHello（单条 record）。
func buildClientHello(sni string, nameType byte, omitSNI bool) []byte {
	var exts []byte
	if !omitSNI {
		var list []byte
		list = append(list, nameType)
		list = binary.BigEndian.AppendUint16(list, uint16(len(sni)))
		list = append(list, sni...)

		var serverNameExt []byte
		serverNameExt = binary.BigEndian.AppendUint16(serverNameExt, uint16(len(list)))
		serverNameExt = append(serverNameExt, list...)

		exts = binary.BigEndian.AppendUint16(exts, 0x0000) // server_name
		exts = binary.BigEndian.AppendUint16(exts, uint16(len(serverNameExt)))
		exts = append(exts, serverNameExt...)
	}

	var body []byte
	body = append(body, 0x03, 0x03)                       // legacy_version
	body = append(body, make([]byte, 32)...)              // random
	body = append(body, 0x00)                             // session_id len
	body = binary.BigEndian.AppendUint16(body, 2)         // cipher_suites len
	body = append(body, 0x13, 0x01)                       // one cipher
	body = append(body, 0x01, 0x00)                       // compression len + null
	body = binary.BigEndian.AppendUint16(body, uint16(len(exts)))
	body = append(body, exts...)

	hs := []byte{0x01}
	hs = append(hs, byte(len(body)>>16), byte(len(body)>>8), byte(len(body)))
	hs = append(hs, body...)

	rec := []byte{0x16, 0x03, 0x01}
	rec = binary.BigEndian.AppendUint16(rec, uint16(len(hs)))
	return append(rec, hs...)
}

func TestParseServerName(t *testing.T) {
	cases := []struct {
		name    string
		input   func() []byte
		want    string
		wantErr bool
	}{
		{
			name:  "normal host",
			input: func() []byte { return buildClientHello("robinfrontend-pa.googleapis.com", 0x00, false) },
			want:  "robinfrontend-pa.googleapis.com",
		},
		{
			name:  "wildcard-ish short host",
			input: func() []byte { return buildClientHello("a.io", 0x00, false) },
			want:  "a.io",
		},
		{
			name:    "no SNI extension",
			input:   func() []byte { return buildClientHello("", 0x00, true) },
			wantErr: true,
		},
		{
			name:    "not tls",
			input:   func() []byte { return []byte("GET / HTTP/1.1\r\nHost: x\r\n\r\n") },
			wantErr: true,
		},
		{
			name:    "empty input",
			input:   func() []byte { return nil },
			wantErr: true,
		},
		{
			name:    "truncated record",
			input:   func() []byte { return buildClientHello("example.com", 0x00, false)[:20] },
			wantErr: true,
		},
		{
			name:    "server_name entry is not host_name type",
			input:   func() []byte { return buildClientHello("example.com", 0x01, false) },
			wantErr: true,
		},
	}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got, err := parseServerName(c.input())
			if c.wantErr {
				if err == nil {
					t.Fatalf("expected error, got %q", got)
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if got != c.want {
				t.Fatalf("got %q, want %q", got, c.want)
			}
		})
	}
}
