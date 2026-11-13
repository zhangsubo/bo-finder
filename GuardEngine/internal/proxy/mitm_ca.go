package proxy

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/hex"
	"encoding/pem"
	"errors"
	"fmt"
	"math/big"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

const maxLeafCache = 512

type cachedCert struct {
	cert      *tls.Certificate
	expiresAt time.Time
}

// LocalCA manages the machine-local Root CA (`0600` private key) used exclusively when
// Tier 3 built-in selective MITM proxy is active, dynamically minting short-lived leaf certificates.
type LocalCA struct {
	certPath string
	keyPath  string
	caCert   *x509.Certificate
	caKey    *ecdsa.PrivateKey
	caPEM    []byte
	fpSHA256 string

	mu    sync.RWMutex
	cache map[string]cachedCert
}

func LoadOrCreateCA(stateDir string) (*LocalCA, error) {
	if err := os.MkdirAll(stateDir, 0o700); err != nil {
		return nil, err
	}
	certPath := filepath.Join(stateDir, "ca-cert.pem")
	keyPath := filepath.Join(stateDir, "ca-key.pem")

	if certPEM, cErr := os.ReadFile(certPath); cErr == nil {
		if keyPEM, kErr := os.ReadFile(keyPath); kErr == nil {
			if loaded, pErr := parseCA(certPath, keyPath, certPEM, keyPEM); pErr == nil {
				_ = os.Chmod(keyPath, 0o600)
				return loaded, nil
			}
		}
	}

	priv, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, fmt.Errorf("generate CA key: %w", err)
	}

	serial, err := randomSerial()
	if err != nil {
		return nil, err
	}
	now := time.Now()
	tmpl := &x509.Certificate{
		SerialNumber: serial,
		Subject: pkix.Name{
			CommonName:   "DeskSide Local Guard Root CA",
			Organization: []string{"DeskSide Local Security"},
		},
		NotBefore:             now.Add(-1 * time.Hour),
		NotAfter:              now.AddDate(10, 0, 0),
		KeyUsage:              x509.KeyUsageCertSign | x509.KeyUsageCRLSign | x509.KeyUsageDigitalSignature,
		BasicConstraintsValid: true,
		IsCA:                  true,
		MaxPathLen:            0,
		MaxPathLenZero:        true,
	}

	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &priv.PublicKey, priv)
	if err != nil {
		return nil, fmt.Errorf("create CA cert: %w", err)
	}

	certPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})
	keyDER, err := x509.MarshalECPrivateKey(priv)
	if err != nil {
		return nil, fmt.Errorf("marshal CA key: %w", err)
	}
	keyPEM := pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: keyDER})

	if err := os.WriteFile(keyPath, keyPEM, 0o600); err != nil {
		return nil, err
	}
	_ = os.Chmod(keyPath, 0o600)
	if err := os.WriteFile(certPath, certPEM, 0o644); err != nil {
		return nil, err
	}

	return parseCA(certPath, keyPath, certPEM, keyPEM)
}

func parseCA(certPath, keyPath string, certPEM, keyPEM []byte) (*LocalCA, error) {
	tlsPair, err := tls.X509KeyPair(certPEM, keyPEM)
	if err != nil {
		return nil, err
	}
	if len(tlsPair.Certificate) == 0 {
		return nil, errors.New("empty CA certificate")
	}
	caCert, err := x509.ParseCertificate(tlsPair.Certificate[0])
	if err != nil {
		return nil, err
	}
	ecKey, ok := tlsPair.PrivateKey.(*ecdsa.PrivateKey)
	if !ok {
		return nil, errors.New("CA private key is not ECDSA")
	}
	if time.Now().After(caCert.NotAfter.Add(-24 * time.Hour)) {
		return nil, errors.New("CA certificate expired")
	}

	sum := sha256.Sum256(caCert.Raw)
	return &LocalCA{
		certPath: certPath,
		keyPath:  keyPath,
		caCert:   caCert,
		caKey:    ecKey,
		caPEM:    certPEM,
		fpSHA256: strings.ToUpper(hex.EncodeToString(sum[:])),
		cache:    make(map[string]cachedCert),
	}, nil
}

func (ca *LocalCA) CertPath() string {
	return ca.certPath
}

func (ca *LocalCA) CertPEM() []byte {
	return append([]byte(nil), ca.caPEM...)
}

func (ca *LocalCA) FingerprintSHA256() string {
	return ca.fpSHA256
}

func (ca *LocalCA) GetCertificate(hello *tls.ClientHelloInfo) (*tls.Certificate, error) {
	host := ""
	if hello != nil {
		host = hello.ServerName
	}
	return ca.CertForHost(host)
}

func (ca *LocalCA) CertForHost(host string) (*tls.Certificate, error) {
	host = normalizeHost(host)
	if host == "" {
		host = "localhost"
	}
	now := time.Now()

	ca.mu.RLock()
	if item, ok := ca.cache[host]; ok && now.Before(item.expiresAt) {
		ca.mu.RUnlock()
		return item.cert, nil
	}
	ca.mu.RUnlock()

	leafKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, err
	}
	serial, err := randomSerial()
	if err != nil {
		return nil, err
	}
	expires := now.Add(7 * 24 * time.Hour)
	tmpl := &x509.Certificate{
		SerialNumber: serial,
		Subject: pkix.Name{
			CommonName:   host,
			Organization: []string{"DeskSide Local Security"},
		},
		NotBefore:   now.Add(-1 * time.Hour),
		NotAfter:    expires,
		KeyUsage:    x509.KeyUsageDigitalSignature | x509.KeyUsageKeyEncipherment,
		ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
	}
	if ip := net.ParseIP(host); ip != nil {
		tmpl.IPAddresses = []net.IP{ip}
	} else {
		tmpl.DNSNames = []string{host}
	}

	der, err := x509.CreateCertificate(rand.Reader, tmpl, ca.caCert, &leafKey.PublicKey, ca.caKey)
	if err != nil {
		return nil, err
	}

	tlsCert := &tls.Certificate{
		Certificate: [][]byte{der, ca.caCert.Raw},
		PrivateKey:  leafKey,
	}

	ca.mu.Lock()
	if len(ca.cache) >= maxLeafCache {
		ca.cache = make(map[string]cachedCert)
	}
	ca.cache[host] = cachedCert{
		cert:      tlsCert,
		expiresAt: expires.Add(-1 * time.Hour),
	}
	ca.mu.Unlock()

	return tlsCert, nil
}

func normalizeHost(h string) string {
	h = strings.TrimSpace(strings.ToLower(h))
	if host, _, err := net.SplitHostPort(h); err == nil {
		return strings.Trim(host, "[]")
	}
	return strings.Trim(h, "[]")
}

func randomSerial() (*big.Int, error) {
	limit := new(big.Int).Lsh(big.NewInt(1), 128)
	return rand.Int(rand.Reader, limit)
}
