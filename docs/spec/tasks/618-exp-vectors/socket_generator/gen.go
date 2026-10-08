package main

import (
	"crypto"
	_ "crypto/sha256"
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"encoding/binary"
	"encoding/hex"
	"fmt"
	"os"
	"strings"
	"golang.org/x/crypto/hkdf"
)

var salt = []byte{0x38,0x76,0x2c,0xf7,0xf5,0x59,0x34,0xb3,0x4d,0x17,0x9a,0xe6,0xa4,0xc8,0x0c,0xad,0xcc,0xbb,0x7f,0x0a}

func expandLabel(secret []byte, label string, n int) []byte {
	full := "tls13 " + label
	info := []byte{byte(n >> 8), byte(n), byte(len(full))}
	info = append(info, full...)
	info = append(info, 0x00)
	out := make([]byte, n)
	hkdf.Expand(crypto.SHA256.New, secret, info).Read(out)
	return out
}
func keys(dcid []byte) (k, iv, hp []byte) {
	s := hkdf.Extract(crypto.SHA256.New, dcid, salt)
	cs := expandLabel(s, "client in", 32)
	return expandLabel(cs, "quic key", 16), expandLabel(cs, "quic iv", 12), expandLabel(cs, "quic hp", 16)
}
func cryptoFrame(off int, data []byte) []byte {
	f := []byte{0x06}
	f = appendVarint(f, uint64(off))
	f = appendVarint(f, uint64(len(data)))
	return append(f, data...)
}
func appendVarint(b []byte, v uint64) []byte {
	switch {
	case v < 64: return append(b, byte(v))
	case v < 16384: return append(b, byte(0x40|v>>8), byte(v))
	default: return append(b, byte(0x80|v>>24), byte(v>>16), byte(v>>8), byte(v))
	}
}
func build(dcid []byte, pn uint64, frames []byte, total int) []byte {
	const pnLen = 1
	headerLen := 1 + 4 + 1 + len(dcid) + 1 + 1 + 2 + pnLen
	payloadLen := total - headerLen - 16
	payload := append(append([]byte{}, frames...), make([]byte, payloadLen-len(frames))...)
	lf := pnLen + payloadLen + 16
	h := []byte{0xC0}
	h = binary.BigEndian.AppendUint32(h, 1)
	h = append(h, byte(len(dcid)))
	h = append(h, dcid...)
	h = append(h, 0x00, 0x00)
	h = append(h, byte(0x40|(lf>>8)), byte(lf))
	pnOff := len(h)
	h = append(h, byte(pn))
	key, iv, hp := keys(dcid)
	blk, _ := aes.NewCipher(key)
	aead, _ := cipher.NewGCM(blk)
	nonce := make([]byte, 12); copy(nonce, iv); nonce[11] ^= byte(pn)
	ct := aead.Seal(nil, nonce, payload, h)
	pkt := append(append([]byte{}, h...), ct...)
	hb, _ := aes.NewCipher(hp)
	mask := make([]byte, 16)
	hb.Encrypt(mask, pkt[pnOff+4:pnOff+4+16])
	pkt[0] ^= mask[0] & 0x0f
	pkt[pnOff] ^= mask[1]
	return pkt
}
// minimal but valid TLS1.3 ClientHello with SNI + key_share x25519 + required exts
func clientHello(sni string) []byte {
	ext := []byte{}
	// server_name
	host := []byte(sni)
	snl := append([]byte{0x00}, byte(len(host)>>8), byte(len(host)))
	snl = append(snl, host...)
	snContent := append([]byte{byte(len(snl)>>8), byte(len(snl))}, snl...)
	ext = append(ext, 0x00,0x00, byte(len(snContent)>>8), byte(len(snContent)))
	ext = append(ext, snContent...)
	// supported_versions 0x002b -> TLS1.3
	ext = append(ext, 0x00,0x2b,0x00,0x03,0x02,0x03,0x04)
	// supported_groups 0x000a -> x25519(0x001d)
	ext = append(ext, 0x00,0x0a,0x00,0x04,0x00,0x02,0x00,0x1d)
	// key_share 0x0033 -> x25519 32 bytes
	ks := make([]byte, 32); rand.Read(ks)
	ksEntry := append([]byte{0x00,0x1d,0x00,0x20}, ks...)
	ksList := append([]byte{byte(len(ksEntry)>>8), byte(len(ksEntry))}, ksEntry...)
	ext = append(ext, 0x00,0x33, byte(len(ksList)>>8), byte(len(ksList)))
	ext = append(ext, ksList...)
	// signature_algorithms 0x000d
	ext = append(ext, 0x00,0x0d,0x00,0x04,0x00,0x02,0x08,0x04)
	// ALPN h3
	alpn := []byte{0x00,0x03,0x02,'h','3'}
	ext = append(ext, 0x00,0x10, byte(len(alpn)>>8), byte(len(alpn)))
	ext = append(ext, alpn...)
	// quic_transport_params 0x0039 (opaque small)
	ext = append(ext, 0x00,0x39,0x00,0x04,0x01,0x02,0x03,0x04)
	body := []byte{0x03,0x03}
	r := make([]byte, 32); rand.Read(r); body = append(body, r...)
	body = append(body, 0x00) // session id len
	body = append(body, 0x00,0x02,0x13,0x01) // cipher suites: TLS_AES_128_GCM_SHA256
	body = append(body, 0x01,0x00) // compression null
	body = append(body, byte(len(ext)>>8), byte(len(ext)))
	body = append(body, ext...)
	ch := []byte{0x01, byte(len(body)>>16), byte(len(body)>>8), byte(len(body))}
	return append(ch, body...)
}
func main() {
	mode := os.Args[1]; sni := os.Args[2]
	dcid := make([]byte, 8); rand.Read(dcid)
	ch := clientHello(sni)
	p1 := build(dcid, 0, cryptoFrame(0, ch), 1250)
	emit := func(p []byte){ fmt.Println("<b 0x"+strings.ToLower(hex.EncodeToString(p))+">") }
	if mode == "p1" { emit(p1); return }
	if mode == "p2good" { emit(p1); p2 := build(dcid, 1, []byte{0x01,0x01}, 1250); emit(p2); return }
}
