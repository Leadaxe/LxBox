// §130 — проверяет, что DER-ключи из Dart парсятся ТЕМИ ЖЕ функциями, что и ядро
// (protocol/masque/outbound.go: x509.ParseECPrivateKey / x509.ParsePKIXPublicKey).
package main

import (
	"bufio"
	"crypto/ecdsa"
	"crypto/x509"
	"encoding/base64"
	"fmt"
	"os"
)

func main() {
	f, err := os.Open(os.Args[1])
	if err != nil {
		panic(err)
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	sc.Scan()
	privB64 := sc.Text()
	sc.Scan()
	pubB64 := sc.Text()

	// --- private_key: ровно как parseECPrivateKey в ядре ---
	privDer, err := base64.StdEncoding.DecodeString(privB64)
	if err != nil {
		fmt.Println("FAIL priv base64:", err)
		os.Exit(1)
	}
	priv, err := x509.ParseECPrivateKey(privDer)
	if err != nil {
		fmt.Println("FAIL x509.ParseECPrivateKey:", err)
		os.Exit(1)
	}
	fmt.Printf("OK  private_key: curve=%s d.bits=%d\n", priv.Curve.Params().Name, priv.D.BitLen())

	// --- public_key: ровно как parseECPublicKey в ядре ---
	pubDer, err := base64.StdEncoding.DecodeString(pubB64)
	if err != nil {
		fmt.Println("FAIL pub base64:", err)
		os.Exit(1)
	}
	pubAny, err := x509.ParsePKIXPublicKey(pubDer)
	if err != nil {
		fmt.Println("FAIL x509.ParsePKIXPublicKey:", err)
		os.Exit(1)
	}
	pub, ok := pubAny.(*ecdsa.PublicKey)
	if !ok {
		fmt.Println("FAIL public_key is not ECDSA")
		os.Exit(1)
	}
	fmt.Printf("OK  public_key:  curve=%s\n", pub.Curve.Params().Name)

	// --- сверка: pub из priv совпадает с отдельным public_key? ---
	if priv.PublicKey.X.Cmp(pub.X) == 0 && priv.PublicKey.Y.Cmp(pub.Y) == 0 {
		fmt.Println("OK  priv.PublicKey == public_key (координаты совпадают)")
	} else {
		fmt.Println("NOTE priv/pub из разных ключей (ожидаемо если dump в разных вызовах)")
	}
	fmt.Println("ALL GOOD — DER-контракт с ядром сходится")
}
