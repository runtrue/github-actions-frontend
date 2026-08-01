package main

import (
	"bytes"
	"context"
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"encoding/pem"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

const testNow = uint64(1_783_728_000)

func TestMintJWTBindsClaimsAndVerifies(t *testing.T) {
	privateKey := newTestKey(t)
	token, err := mintJWT(privateKey, 123, testNow)
	if err != nil {
		t.Fatal(err)
	}
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		t.Fatalf("JWT has %d parts", len(parts))
	}
	header := decodePart(t, parts[0])
	if string(header) != `{"alg":"RS256","typ":"JWT"}` {
		t.Fatalf("unexpected header: %s", header)
	}
	var claims jwtClaims
	if err := json.Unmarshal(decodePart(t, parts[1]), &claims); err != nil {
		t.Fatal(err)
	}
	if claims.Issuer != 123 || claims.IssuedAt != testNow-30 || claims.ExpiresAt != testNow+540 {
		t.Fatalf("unexpected claims: %+v", claims)
	}
	signature := decodePart(t, parts[2])
	digest := sha256.Sum256([]byte(parts[0] + "." + parts[1]))
	if err := rsa.VerifyPKCS1v15(&privateKey.PublicKey, crypto.SHA256, digest[:], signature); err != nil {
		t.Fatalf("verify RS256 signature: %v", err)
	}
}

func TestServeAcceptsExactRequest(t *testing.T) {
	privateKey := newTestKey(t)
	s := &signer{
		privateKey:          privateKey,
		appID:               123,
		credentialReference: "provider://github-app/production",
		now:                 func() time.Time { return time.Unix(int64(testNow), 0) },
	}
	client, server := net.Pipe()
	done := make(chan struct{})
	go func() {
		defer close(done)
		s.serve(server)
	}()

	request := signerRequest{
		Version:             1,
		Operation:           mintOperation,
		AppID:               123,
		CredentialReference: "provider://github-app/production",
		NowUnixSeconds:      testNow,
	}
	payload, err := json.Marshal(request)
	if err != nil {
		t.Fatal(err)
	}
	if err := writeFrame(client, payload); err != nil {
		t.Fatal(err)
	}
	responsePayload, err := readFrame(client)
	if err != nil {
		t.Fatal(err)
	}
	var response signerResponse
	if err := json.Unmarshal(responsePayload, &response); err != nil {
		t.Fatal(err)
	}
	if response.Version != 1 || response.Error != "" || response.JWT == "" {
		t.Fatalf("unexpected response: %+v", response)
	}
	_ = client.Close()
	<-done
}

func TestServeRejectsMismatchedAndMalformedRequests(t *testing.T) {
	privateKey := newTestKey(t)
	valid := `{"version":1,"operation":"github.app-jwt.mint","app_id":123,"credential_reference":"provider://github-app/production","now_unix_seconds":1783728000}`
	tests := map[string]string{
		"wrong version":    strings.Replace(valid, `"version":1`, `"version":2`, 1),
		"wrong operation":  strings.Replace(valid, mintOperation, "github.installation-token.mint", 1),
		"wrong app":        strings.Replace(valid, `"app_id":123`, `"app_id":124`, 1),
		"wrong credential": strings.Replace(valid, "production", "staging", 1),
		"stale time":       strings.Replace(valid, "1783728000", "1783727939", 1),
		"future time":      strings.Replace(valid, "1783728000", "1783728061", 1),
		"unknown field":    strings.TrimSuffix(valid, "}") + `,"extra":true}`,
		"duplicate field":  strings.TrimSuffix(valid, "}") + `,"app_id":123}`,
		"trailing value":   valid + `{}`,
	}
	for name, payload := range tests {
		t.Run(name, func(t *testing.T) {
			s := &signer{
				privateKey:          privateKey,
				appID:               123,
				credentialReference: "provider://github-app/production",
				now:                 func() time.Time { return time.Unix(int64(testNow), 0) },
			}
			client, server := net.Pipe()
			go s.serve(server)
			if err := writeFrame(client, []byte(payload)); err != nil {
				t.Fatal(err)
			}
			responsePayload, err := readFrame(client)
			if err != nil {
				t.Fatal(err)
			}
			var response signerResponse
			if err := json.Unmarshal(responsePayload, &response); err != nil {
				t.Fatal(err)
			}
			if response.Error != "request rejected" || response.JWT != "" {
				t.Fatalf("unexpected response: %+v", response)
			}
			_ = client.Close()
		})
	}
}

func TestFrameBoundsAndPartialWrites(t *testing.T) {
	for _, size := range []uint32{0, maxFrameBytes + 1} {
		var framed bytes.Buffer
		if err := binary.Write(&framed, binary.BigEndian, size); err != nil {
			t.Fatal(err)
		}
		if _, err := readFrame(&framed); err == nil {
			t.Fatalf("accepted frame size %d", size)
		}
	}
	writer := &shortWriter{maximum: 3}
	payload := []byte(`{"version":1}`)
	if err := writeFrame(writer, payload); err != nil {
		t.Fatal(err)
	}
	if got, want := writer.buffer.Len(), len(payload)+4; got != want {
		t.Fatalf("wrote %d bytes, want %d", got, want)
	}
}

func TestReadPrivateKeyAcceptsPKCS1AndRejectsUnsafeFiles(t *testing.T) {
	privateKey := newTestKey(t)
	directory := t.TempDir()
	pkcs1 := filepath.Join(directory, "github-app.pem")
	writePEM(t, pkcs1, "RSA PRIVATE KEY", x509.MarshalPKCS1PrivateKey(privateKey), 0o600)
	loaded, err := readPrivateKey(pkcs1)
	if err != nil {
		t.Fatal(err)
	}
	if loaded.N.Cmp(privateKey.N) != 0 {
		t.Fatal("loaded a different private key")
	}

	pkcs8Bytes, err := x509.MarshalPKCS8PrivateKey(privateKey)
	if err != nil {
		t.Fatal(err)
	}
	pkcs8 := filepath.Join(directory, "github-app-pkcs8.pem")
	writePEM(t, pkcs8, "PRIVATE KEY", pkcs8Bytes, 0o400)
	if _, err := readPrivateKey(pkcs8); err != nil {
		t.Fatalf("read PKCS#8 key: %v", err)
	}

	permissive := filepath.Join(directory, "permissive.pem")
	writePEM(t, permissive, "RSA PRIVATE KEY", x509.MarshalPKCS1PrivateKey(privateKey), 0o640)
	if _, err := readPrivateKey(permissive); err == nil {
		t.Fatal("accepted group-readable key")
	}
	symlink := filepath.Join(directory, "symlink.pem")
	if err := os.Symlink(pkcs1, symlink); err != nil {
		t.Fatal(err)
	}
	if _, err := readPrivateKey(symlink); err == nil {
		t.Fatal("accepted private-key symlink")
	}
	hardlink := filepath.Join(directory, "hardlink.pem")
	if err := os.Link(pkcs1, hardlink); err != nil {
		t.Fatal(err)
	}
	if _, err := readPrivateKey(pkcs1); err == nil {
		t.Fatal("accepted hard-linked private key")
	}
}

func TestRunCreatesPrivateReachableSocketAndStopsCleanly(t *testing.T) {
	privateKey := newTestKey(t)
	directory := t.TempDir()
	keyPath := filepath.Join(directory, "github-app.pem")
	writePEM(t, keyPath, "RSA PRIVATE KEY", x509.MarshalPKCS1PrivateKey(privateKey), 0o600)
	socketPath := filepath.Join(directory, "signer.sock")
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() {
		done <- run(ctx, config{
			socketPath:          socketPath,
			privateKeyPath:      keyPath,
			appID:               123,
			credentialReference: "provider://github-app/production",
		})
	}()
	deadline := time.Now().Add(5 * time.Second)
	for {
		if err := checkSocket(socketPath); err == nil {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("signer socket did not become ready")
		}
		time.Sleep(10 * time.Millisecond)
	}
	info, err := os.Lstat(socketPath)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o600 || info.Mode()&os.ModeSocket == 0 {
		t.Fatalf("unexpected socket mode: %v", info.Mode())
	}
	cancel()
	if err := <-done; err != nil {
		t.Fatal(err)
	}
	if _, err := os.Lstat(socketPath); !os.IsNotExist(err) {
		t.Fatalf("socket was not removed: %v", err)
	}
}

func TestPrepareSocketPathRejectsSubstitutionAndUnsafeParent(t *testing.T) {
	directory := t.TempDir()
	regularPath := filepath.Join(directory, "not-a-socket")
	if err := os.WriteFile(regularPath, []byte("do not remove"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := prepareSocketPath(regularPath); err == nil {
		t.Fatal("accepted a regular file in place of the socket")
	}
	if payload, err := os.ReadFile(regularPath); err != nil || string(payload) != "do not remove" {
		t.Fatalf("substitute path was changed: %q, %v", payload, err)
	}

	unsafeParent := filepath.Join(directory, "unsafe")
	if err := os.Mkdir(unsafeParent, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(unsafeParent, 0o777); err != nil {
		t.Fatal(err)
	}
	if err := prepareSocketPath(filepath.Join(unsafeParent, "signer.sock")); err == nil {
		t.Fatal("accepted a world-writable socket parent")
	}

	realParent := filepath.Join(directory, "real")
	if err := os.Mkdir(realParent, 0o700); err != nil {
		t.Fatal(err)
	}
	symlinkParent := filepath.Join(directory, "linked")
	if err := os.Symlink(realParent, symlinkParent); err != nil {
		t.Fatal(err)
	}
	if err := prepareSocketPath(filepath.Join(symlinkParent, "signer.sock")); err == nil {
		t.Fatal("accepted a symbolic-link socket parent")
	}
}

func newTestKey(t *testing.T) *rsa.PrivateKey {
	t.Helper()
	privateKey, err := rsa.GenerateKey(rand.Reader, minimumRSAKeyBits)
	if err != nil {
		t.Fatal(err)
	}
	return privateKey
}

func writePEM(t *testing.T, path, blockType string, der []byte, mode os.FileMode) {
	t.Helper()
	encoded := pem.EncodeToMemory(&pem.Block{Type: blockType, Bytes: der})
	if err := os.WriteFile(path, encoded, mode); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(path, mode); err != nil {
		t.Fatal(err)
	}
}

func decodePart(t *testing.T, encoded string) []byte {
	t.Helper()
	decoded, err := base64.RawURLEncoding.DecodeString(encoded)
	if err != nil {
		t.Fatal(err)
	}
	return decoded
}

type shortWriter struct {
	buffer  bytes.Buffer
	maximum int
}

func (w *shortWriter) Write(payload []byte) (int, error) {
	if len(payload) > w.maximum {
		payload = payload[:w.maximum]
	}
	return w.buffer.Write(payload)
}

var _ io.Writer = (*shortWriter)(nil)
