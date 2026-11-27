// sni_redirect: 接收被 pf 重定向过来的裸 TCP 连接，凭 TLS ClientHello 里的
// SNI 还原目标域名，再经上游 SOCKS5 连过去做纯隧道转发（不解密）。
//
// 用途：原生 Swift / Network.framework 的 App（Gemini）在框架内部建连，
// dyld 的 connect hook 拿不到，系统代理也不认；只能把 FakeIP 段在 IP 层
// 重定向到这里，靠 SNI 还原域名。不需要 TUN，不需要改全局路由以外的配置。
package main

import (
	"bufio"
	"encoding/binary"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"sync"
	"time"
)

type socks5Upstream struct {
	addr string
	user string
	pass string
}

func (u socks5Upstream) dial(target string) (net.Conn, error) {
	c, err := net.DialTimeout("tcp", u.addr, 8*time.Second)
	if err != nil {
		return nil, err
	}
	c.SetDeadline(time.Now().Add(15 * time.Second))

	methods := []byte{0x00}
	if u.user != "" {
		methods = []byte{0x02, 0x00}
	}
	if _, err = c.Write(append([]byte{0x05, byte(len(methods))}, methods...)); err != nil {
		c.Close()
		return nil, err
	}
	resp := make([]byte, 2)
	if _, err = io.ReadFull(c, resp); err != nil {
		c.Close()
		return nil, err
	}
	if resp[0] != 0x05 {
		c.Close()
		return nil, fmt.Errorf("socks5: bad version %d", resp[0])
	}
	if resp[1] == 0x02 {
		req := append([]byte{0x01, byte(len(u.user))}, u.user...)
		req = append(req, byte(len(u.pass)))
		req = append(req, u.pass...)
		if _, err = c.Write(req); err != nil {
			c.Close()
			return nil, err
		}
		if _, err = io.ReadFull(c, resp); err != nil || resp[1] != 0x00 {
			c.Close()
			return nil, errors.New("socks5: auth failed")
		}
	} else if resp[1] != 0x00 {
		c.Close()
		return nil, errors.New("socks5: no acceptable auth method")
	}

	host, port, err := net.SplitHostPort(target)
	if err != nil {
		c.Close()
		return nil, err
	}
	portNum := 443
	fmt.Sscanf(port, "%d", &portNum)

	// 域名长度字段只有 1 字节，超长会静默截断成错误目标。
	if len(host) == 0 || len(host) > 255 {
		c.Close()
		return nil, fmt.Errorf("socks5: host length %d out of range", len(host))
	}
	req := []byte{0x05, 0x01, 0x00, 0x03, byte(len(host))}
	req = append(req, host...)
	req = binary.BigEndian.AppendUint16(req, uint16(portNum))
	if _, err = c.Write(req); err != nil {
		c.Close()
		return nil, err
	}

	head := make([]byte, 4)
	if _, err = io.ReadFull(c, head); err != nil {
		c.Close()
		return nil, err
	}
	if head[1] != 0x00 {
		c.Close()
		return nil, fmt.Errorf("socks5: connect failed code=%d", head[1])
	}
	switch head[3] {
	case 0x01:
		_, err = io.ReadFull(c, make([]byte, 4+2))
	case 0x04:
		_, err = io.ReadFull(c, make([]byte, 16+2))
	case 0x03:
		l := make([]byte, 1)
		if _, err = io.ReadFull(c, l); err == nil {
			_, err = io.ReadFull(c, make([]byte, int(l[0])+2))
		}
	default:
		err = errors.New("socks5: bad atyp")
	}
	if err != nil {
		c.Close()
		return nil, err
	}
	c.SetDeadline(time.Time{})
	return c, nil
}

// parseServerName 从 TLS ClientHello 中提取 SNI。非 TLS 返回错误。
func parseServerName(b []byte) (string, error) {
	if len(b) < 5 || b[0] != 0x16 {
		return "", errors.New("not a TLS handshake")
	}
	recLen := int(binary.BigEndian.Uint16(b[3:5]))
	if len(b) < 5+recLen || len(b) < 44 {
		return "", errors.New("short record")
	}
	p := b[5:]
	if p[0] != 0x01 {
		return "", errors.New("not client hello")
	}
	p = p[4:]                 // handshake header
	p = p[2:]                 // legacy_version
	p = p[32:]                // random
	if len(p) < 1 {
		return "", errors.New("truncated sid")
	}
	sidLen := int(p[0])
	p = p[1:]
	if len(p) < sidLen+2 {
		return "", errors.New("truncated sid body")
	}
	p = p[sidLen:]
	csLen := int(binary.BigEndian.Uint16(p))
	p = p[2:]
	if len(p) < csLen+1 {
		return "", errors.New("truncated ciphers")
	}
	p = p[csLen:]
	compLen := int(p[0])
	p = p[1:]
	if len(p) < compLen+2 {
		return "", errors.New("truncated compression")
	}
	p = p[compLen:]
	extLen := int(binary.BigEndian.Uint16(p))
	p = p[2:]
	if len(p) > extLen {
		p = p[:extLen]
	}
	for len(p) >= 4 {
		etype := binary.BigEndian.Uint16(p)
		elen := int(binary.BigEndian.Uint16(p[2:]))
		p = p[4:]
		if len(p) < elen {
			break
		}
		edata := p[:elen]
		p = p[elen:]
		if etype != 0x0000 { // server_name
			continue
		}
		if len(edata) < 5 {
			continue
		}
		// edata[0:2] 是 server_name_list 长度，edata[2] 必须是 host_name(0)。
		if edata[2] != 0x00 {
			continue
		}
		nameLen := int(binary.BigEndian.Uint16(edata[3:]))
		if nameLen == 0 || len(edata) < 5+nameLen {
			continue
		}
		return string(edata[5 : 5+nameLen]), nil
	}
	return "", errors.New("no SNI in client hello")
}

func handle(conn net.Conn, up socks5Upstream) {
	defer conn.Close()
	conn.SetReadDeadline(time.Now().Add(10 * time.Second))

	br := bufio.NewReaderSize(conn, 16*1024)
	// 读到完整的 TLS record 头 + 尽可能多的 body，用于解析 SNI
	header := make([]byte, 5)
	if _, err := io.ReadFull(br, header); err != nil {
		return
	}
	recLen := int(binary.BigEndian.Uint16(header[3:5]))
	if recLen <= 0 || recLen > 16*1024 {
		return
	}
	body := make([]byte, recLen)
	if _, err := io.ReadFull(br, body); err != nil {
		return
	}
	buffered := append(append([]byte{}, header...), body...)

	sni, err := parseServerName(buffered)
	if err != nil || sni == "" {
		log.Printf("[skip] %s: %v", conn.RemoteAddr(), err)
		return
	}
	conn.SetReadDeadline(time.Time{})

	target := net.JoinHostPort(sni, "443")
	upstream, err := up.dial(target)
	if err != nil {
		log.Printf("[fail] %s: %v", target, err)
		return
	}
	defer upstream.Close()

	if _, err := upstream.Write(buffered); err != nil {
		return
	}
	log.Printf("[ok] %s", target)

	var wg sync.WaitGroup
	wg.Add(2)
	// 单向 Copy 结束就 CloseWrite 让对端收到 FIN：只等两个方向自然结束的话，
	// 对端不发 FIN 的连接会长期挂住 goroutine 和 fd。
	go func() {
		defer wg.Done()
		io.Copy(upstream, br)
		closeWrite(upstream)
	}()
	go func() {
		defer wg.Done()
		io.Copy(conn, upstream)
		closeWrite(conn)
	}()
	wg.Wait()
}

// closeWrite 对 TCP 连接做半关闭；不支持时退化为整体关闭。
func closeWrite(c net.Conn) {
	type closeWriter interface{ CloseWrite() error }
	if cw, ok := c.(closeWriter); ok {
		cw.CloseWrite()
		return
	}
	c.Close()
}

func main() {
	listen := flag.String("listen", "127.0.0.1:18082", "本地监听地址（pf 重定向目标）")
	upstream := flag.String("socks5", "127.0.0.1:7897", "上游 SOCKS5")
	logPath := flag.String("log", "", "日志文件（默认 stderr）")
	flag.Parse()

	if *logPath != "" {
		f, err := os.OpenFile(*logPath, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
		if err == nil {
			log.SetOutput(f)
		}
	}

	up := socks5Upstream{addr: *upstream}
	ln, err := net.Listen("tcp", *listen)
	if err != nil {
		log.Fatalf("listen %s: %v", *listen, err)
	}
	log.Printf("sni_redirect listening on %s -> socks5 %s", *listen, *upstream)
	for {
		c, err := ln.Accept()
		if err != nil {
			log.Printf("accept: %v", err)
			continue
		}
		go handle(c, up)
	}
}
