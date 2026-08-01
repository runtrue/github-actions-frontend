package main

import (
	"bytes"
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

const (
	protocolVersion        = 1
	mintOperation          = "github.app-jwt.mint"
	maxFrameBytes          = 16 * 1024
	maxPrivateKeyBytes     = 64 * 1024
	minimumRSAKeyBits      = 2048
	requestClockSkew       = 60 * time.Second
	ioTimeout              = 5 * time.Second
	githubAppJWTBackdate   = 30
	githubAppJWTLifetime   = 9 * 60
	credentialReferenceMax = 255
)

type signerRequest struct {
	Version             uint32 `json:"version"`
	Operation           string `json:"operation"`
	AppID               uint64 `json:"app_id"`
	CredentialReference string `json:"credential_reference"`
	NowUnixSeconds      uint64 `json:"now_unix_seconds"`
}

type signerResponse struct {
	Version uint32 `json:"version"`
	JWT     string `json:"jwt,omitempty"`
	Error   string `json:"error,omitempty"`
}

type jwtClaims struct {
	IssuedAt  uint64 `json:"iat"`
	ExpiresAt uint64 `json:"exp"`
	Issuer    uint64 `json:"iss"`
}

type signer struct {
	privateKey          *rsa.PrivateKey
	appID               uint64
	credentialReference string
	now                 func() time.Time
}

func (s *signer) serve(connection net.Conn) {
	defer connection.Close()
	_ = connection.SetDeadline(time.Now().Add(ioTimeout))

	payload, err := readFrame(connection)
	if err != nil {
		return
	}
	request, err := decodeRequest(payload)
	if err != nil || !s.authorize(request) {
		_ = writeResponse(connection, signerResponse{
			Version: protocolVersion,
			Error:   "request rejected",
		})
		return
	}

	token, err := mintJWT(s.privateKey, s.appID, request.NowUnixSeconds)
	if err != nil {
		_ = writeResponse(connection, signerResponse{
			Version: protocolVersion,
			Error:   "signing failed",
		})
		return
	}
	_ = writeResponse(connection, signerResponse{
		Version: protocolVersion,
		JWT:     token,
	})
}

func (s *signer) authorize(request signerRequest) bool {
	if request.Version != protocolVersion ||
		request.Operation != mintOperation ||
		request.AppID != s.appID ||
		request.CredentialReference != s.credentialReference ||
		request.NowUnixSeconds < githubAppJWTBackdate {
		return false
	}

	now := s.now().Unix()
	if now < 0 {
		return false
	}
	current := uint64(now)
	allowedSkew := uint64(requestClockSkew / time.Second)
	if request.NowUnixSeconds > current {
		return request.NowUnixSeconds-current <= allowedSkew
	}
	return current-request.NowUnixSeconds <= allowedSkew
}

func readFrame(reader io.Reader) ([]byte, error) {
	var sizeBytes [4]byte
	if _, err := io.ReadFull(reader, sizeBytes[:]); err != nil {
		return nil, err
	}
	size := binary.BigEndian.Uint32(sizeBytes[:])
	if size == 0 || size > maxFrameBytes {
		return nil, errors.New("invalid frame size")
	}
	payload := make([]byte, size)
	if _, err := io.ReadFull(reader, payload); err != nil {
		return nil, err
	}
	return payload, nil
}

func writeFrame(writer io.Writer, payload []byte) error {
	if len(payload) == 0 || len(payload) > maxFrameBytes {
		return errors.New("invalid frame size")
	}
	var sizeBytes [4]byte
	binary.BigEndian.PutUint32(sizeBytes[:], uint32(len(payload)))
	if err := writeAll(writer, sizeBytes[:]); err != nil {
		return err
	}
	return writeAll(writer, payload)
}

func writeAll(writer io.Writer, payload []byte) error {
	for len(payload) > 0 {
		written, err := writer.Write(payload)
		if err != nil {
			return err
		}
		if written == 0 {
			return io.ErrShortWrite
		}
		payload = payload[written:]
	}
	return nil
}

func writeResponse(writer io.Writer, response signerResponse) error {
	payload, err := json.Marshal(response)
	if err != nil {
		return err
	}
	return writeFrame(writer, payload)
}

func decodeRequest(payload []byte) (signerRequest, error) {
	if err := rejectDuplicateObjectKeys(payload); err != nil {
		return signerRequest{}, err
	}

	decoder := json.NewDecoder(bytes.NewReader(payload))
	decoder.DisallowUnknownFields()
	var request signerRequest
	if err := decoder.Decode(&request); err != nil {
		return signerRequest{}, err
	}
	if err := requireJSONEnd(decoder); err != nil {
		return signerRequest{}, err
	}
	return request, nil
}

func rejectDuplicateObjectKeys(payload []byte) error {
	decoder := json.NewDecoder(bytes.NewReader(payload))
	opening, err := decoder.Token()
	if err != nil {
		return err
	}
	if opening != json.Delim('{') {
		return errors.New("request must be a JSON object")
	}

	seen := make(map[string]struct{}, 5)
	for decoder.More() {
		token, err := decoder.Token()
		if err != nil {
			return err
		}
		name, ok := token.(string)
		if !ok {
			return errors.New("request field name is not a string")
		}
		if _, duplicate := seen[name]; duplicate {
			return fmt.Errorf("duplicate request field %q", name)
		}
		seen[name] = struct{}{}
		var value json.RawMessage
		if err := decoder.Decode(&value); err != nil {
			return err
		}
	}

	closing, err := decoder.Token()
	if err != nil {
		return err
	}
	if closing != json.Delim('}') {
		return errors.New("request is not a JSON object")
	}
	return requireJSONEnd(decoder)
}

func requireJSONEnd(decoder *json.Decoder) error {
	var trailing json.RawMessage
	if err := decoder.Decode(&trailing); !errors.Is(err, io.EOF) {
		if err == nil {
			return errors.New("trailing JSON value")
		}
		return err
	}
	return nil
}

func mintJWT(privateKey *rsa.PrivateKey, appID, now uint64) (string, error) {
	if now < githubAppJWTBackdate || now > ^uint64(0)-githubAppJWTLifetime {
		return "", errors.New("request time is outside the supported range")
	}
	header := base64.RawURLEncoding.EncodeToString([]byte(`{"alg":"RS256","typ":"JWT"}`))
	claims, err := json.Marshal(jwtClaims{
		IssuedAt:  now - githubAppJWTBackdate,
		ExpiresAt: now + githubAppJWTLifetime,
		Issuer:    appID,
	})
	if err != nil {
		return "", err
	}
	unsigned := header + "." + base64.RawURLEncoding.EncodeToString(claims)
	digest := sha256.Sum256([]byte(unsigned))
	signature, err := rsa.SignPKCS1v15(rand.Reader, privateKey, crypto.SHA256, digest[:])
	if err != nil {
		return "", err
	}
	return unsigned + "." + base64.RawURLEncoding.EncodeToString(signature), nil
}

func readPrivateKey(path string) (*rsa.PrivateKey, error) {
	if path == "" {
		return nil, errors.New("private key path is empty")
	}
	descriptor, err := syscall.Open(path, syscall.O_RDONLY|syscall.O_CLOEXEC|syscall.O_NOFOLLOW, 0)
	if err != nil {
		return nil, fmt.Errorf("open private key: %w", err)
	}
	file := os.NewFile(uintptr(descriptor), path)
	if file == nil {
		_ = syscall.Close(descriptor)
		return nil, errors.New("open private key: invalid descriptor")
	}
	defer file.Close()

	info, err := file.Stat()
	if err != nil {
		return nil, fmt.Errorf("stat private key: %w", err)
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok || !info.Mode().IsRegular() || info.Mode().Perm()&0o077 != 0 || stat.Nlink != 1 ||
		(stat.Uid != 0 && stat.Uid != uint32(os.Geteuid())) {
		return nil, errors.New("private key must be a private, regular, non-linked file")
	}
	if info.Size() <= 0 || info.Size() > maxPrivateKeyBytes {
		return nil, errors.New("private key file has an invalid size")
	}

	encoded, err := io.ReadAll(io.LimitReader(file, maxPrivateKeyBytes+1))
	if err != nil {
		return nil, fmt.Errorf("read private key: %w", err)
	}
	defer clear(encoded)
	if len(encoded) > maxPrivateKeyBytes {
		return nil, errors.New("private key file is too large")
	}
	block, rest := pem.Decode(encoded)
	if block == nil || len(bytes.TrimSpace(rest)) != 0 {
		return nil, errors.New("private key must contain exactly one PEM block")
	}

	var privateKey *rsa.PrivateKey
	switch block.Type {
	case "RSA PRIVATE KEY":
		privateKey, err = x509.ParsePKCS1PrivateKey(block.Bytes)
	case "PRIVATE KEY":
		var parsed any
		parsed, err = x509.ParsePKCS8PrivateKey(block.Bytes)
		if err == nil {
			var ok bool
			privateKey, ok = parsed.(*rsa.PrivateKey)
			if !ok {
				return nil, errors.New("private key is not RSA")
			}
		}
	default:
		return nil, errors.New("unsupported private key PEM type")
	}
	if err != nil {
		return nil, fmt.Errorf("parse private key: %w", err)
	}
	if privateKey.N.BitLen() < minimumRSAKeyBits {
		return nil, fmt.Errorf("RSA private key must be at least %d bits", minimumRSAKeyBits)
	}
	if err := privateKey.Validate(); err != nil {
		return nil, fmt.Errorf("validate private key: %w", err)
	}
	privateKey.Precompute()
	return privateKey, nil
}

func validateCredentialReference(reference string) error {
	if !strings.HasPrefix(reference, "provider://github-app/") ||
		len(reference) > credentialReferenceMax ||
		strings.IndexFunc(reference, func(character rune) bool { return character < 0x20 || character == 0x7f }) >= 0 {
		return errors.New("GitHub App credential reference is invalid")
	}
	return nil
}

func prepareSocketPath(path string) error {
	if !filepath.IsAbs(path) || filepath.Clean(path) != path || path == string(filepath.Separator) {
		return errors.New("signer socket path must be absolute and canonical")
	}
	parent := filepath.Dir(path)
	if err := os.MkdirAll(parent, 0o700); err != nil {
		return fmt.Errorf("create signer socket directory: %w", err)
	}
	if err := validateSocketParent(parent); err != nil {
		return err
	}

	info, err := os.Lstat(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return fmt.Errorf("inspect signer socket: %w", err)
	}
	if err := validateSocketInfo(info); err != nil {
		return err
	}
	if err := os.Remove(path); err != nil {
		return fmt.Errorf("remove stale signer socket: %w", err)
	}
	return nil
}

func validateSocketParent(path string) error {
	current := string(filepath.Separator)
	for _, component := range strings.Split(strings.TrimPrefix(path, current), current) {
		if component == "" {
			continue
		}
		current = filepath.Join(current, component)
		info, err := os.Lstat(current)
		if err != nil {
			return fmt.Errorf("inspect signer socket parent: %w", err)
		}
		stat, ok := info.Sys().(*syscall.Stat_t)
		if !ok || !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
			return fmt.Errorf("signer socket parent %q is not a real directory", current)
		}
		mode := info.Mode().Perm()
		rootSticky := stat.Uid == 0 && info.Mode()&os.ModeSticky != 0
		if (stat.Uid != 0 && stat.Uid != uint32(os.Geteuid())) || (mode&0o022 != 0 && !rootSticky) {
			return fmt.Errorf("signer socket parent %q has unsafe ownership or permissions", current)
		}
	}
	return nil
}

func validateSocketInfo(info os.FileInfo) error {
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok || info.Mode()&os.ModeSocket == 0 || info.Mode().Perm() != 0o600 ||
		(stat.Uid != 0 && stat.Uid != uint32(os.Geteuid())) {
		return errors.New("signer socket must be root- or process-owned with exact mode 0600")
	}
	return nil
}
