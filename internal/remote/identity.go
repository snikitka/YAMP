package remote

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"encoding/pem"
	"errors"
	"math/big"
	"os"
	"path/filepath"
	"time"
)

type Identity struct {
	Cert        tls.Certificate
	Fingerprint string
}

func Fingerprint(der []byte) string {
	sum := sha256.Sum256(der)
	return base64.RawURLEncoding.EncodeToString(sum[:])
}

func LoadIdentity(path string) (*Identity, error) {
	if b, err := os.ReadFile(path); err == nil {
		if id, err := parseIdentity(b); err == nil {
			return id, nil
		}
	}
	b, err := newIdentityPEM()
	if err != nil {
		return nil, err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return nil, err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, b, 0o600); err != nil {
		return nil, err
	}
	if err := os.Rename(tmp, path); err != nil {
		return nil, err
	}
	return parseIdentity(b)
}

func parseIdentity(b []byte) (*Identity, error) {
	cert, err := tls.X509KeyPair(b, b)
	if err != nil {
		return nil, err
	}
	if len(cert.Certificate) == 0 {
		return nil, errors.New("пустой сертификат")
	}
	leaf, err := x509.ParseCertificate(cert.Certificate[0])
	if err != nil {
		return nil, err
	}
	if time.Now().After(leaf.NotAfter) {
		return nil, errors.New("сертификат истёк")
	}
	cert.Leaf = leaf
	return &Identity{Cert: cert, Fingerprint: Fingerprint(cert.Certificate[0])}, nil
}

func newIdentityPEM() ([]byte, error) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, err
	}
	serial, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 120))
	if err != nil {
		return nil, err
	}
	now := time.Now()
	tmpl := &x509.Certificate{
		SerialNumber: serial,
		Subject:      pkix.Name{CommonName: "YAMP"},
		NotBefore:    now.Add(-time.Hour),
		NotAfter:     now.AddDate(20, 0, 0),
		KeyUsage:     x509.KeyUsageDigitalSignature,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	if err != nil {
		return nil, err
	}
	keyDER, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		return nil, err
	}
	out := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})
	out = append(out, pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: keyDER})...)
	return out, nil
}

func RandomToken(n int) string {
	b := make([]byte, n)
	_, _ = rand.Read(b)
	return base64.RawURLEncoding.EncodeToString(b)
}

func HashKey(key string) string {
	sum := sha256.Sum256([]byte(key))
	return base64.RawURLEncoding.EncodeToString(sum[:])
}
