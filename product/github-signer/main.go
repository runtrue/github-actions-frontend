package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log"
	"net"
	"os"
	"os/signal"
	"path/filepath"
	"runtime"
	"strconv"
	"syscall"
	"time"
)

const maxConcurrentConnections = 32

type config struct {
	socketPath          string
	privateKeyPath      string
	appID               uint64
	credentialReference string
}

func main() {
	checkSocketPath := flag.String("check-socket", "", "verify that a secure signer socket accepts connections")
	flag.Parse()

	if *checkSocketPath != "" {
		if err := checkSocket(*checkSocketPath); err != nil {
			os.Exit(1)
		}
		return
	}
	if runtime.GOOS != "linux" {
		log.Fatal("runtrue-github-signer supports Linux only")
	}

	configuration, err := loadConfig()
	if err != nil {
		log.Fatalf("configuration: %v", err)
	}
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	if err := run(ctx, configuration); err != nil {
		log.Fatalf("run: %v", err)
	}
}

func loadConfig() (config, error) {
	appID, err := strconv.ParseUint(os.Getenv("RUNTRUE_GITHUB_APP_ID"), 10, 64)
	if err != nil || appID == 0 {
		return config{}, errors.New("RUNTRUE_GITHUB_APP_ID must be a positive integer")
	}
	configuration := config{
		socketPath:          os.Getenv("RUNTRUE_GITHUB_SIGNER_SOCKET"),
		privateKeyPath:      os.Getenv("RUNTRUE_GITHUB_APP_PRIVATE_KEY_FILE"),
		appID:               appID,
		credentialReference: os.Getenv("RUNTRUE_GITHUB_APP_CREDENTIAL_REFERENCE"),
	}
	if configuration.socketPath == "" {
		return config{}, errors.New("RUNTRUE_GITHUB_SIGNER_SOCKET is required")
	}
	if configuration.privateKeyPath == "" {
		return config{}, errors.New("RUNTRUE_GITHUB_APP_PRIVATE_KEY_FILE is required")
	}
	if err := validateCredentialReference(configuration.credentialReference); err != nil {
		return config{}, err
	}
	return configuration, nil
}

func run(ctx context.Context, configuration config) error {
	privateKey, err := readPrivateKey(configuration.privateKeyPath)
	if err != nil {
		return err
	}
	if err := prepareSocketPath(configuration.socketPath); err != nil {
		return err
	}

	listener, err := net.Listen("unix", configuration.socketPath)
	if err != nil {
		return fmt.Errorf("listen on signer socket: %w", err)
	}
	defer listener.Close()
	createdSocket, err := os.Lstat(configuration.socketPath)
	if err != nil {
		return fmt.Errorf("inspect created signer socket: %w", err)
	}
	defer removeSocketIfUnchanged(configuration.socketPath, createdSocket)
	if err := os.Chmod(configuration.socketPath, 0o600); err != nil {
		return fmt.Errorf("secure signer socket: %w", err)
	}

	signer := &signer{
		privateKey:          privateKey,
		appID:               configuration.appID,
		credentialReference: configuration.credentialReference,
		now:                 time.Now,
	}
	go func() {
		<-ctx.Done()
		_ = listener.Close()
	}()

	connections := make(chan struct{}, maxConcurrentConnections)
	log.Printf("runtrue GitHub App signer ready for app_id=%d", configuration.appID)
	for {
		connection, err := listener.Accept()
		if err != nil {
			if ctx.Err() != nil {
				return nil
			}
			return fmt.Errorf("accept signer connection: %w", err)
		}
		select {
		case connections <- struct{}{}:
			go func() {
				defer func() { <-connections }()
				signer.serve(connection)
			}()
		default:
			_ = connection.Close()
		}
	}
}

func removeSocketIfUnchanged(path string, created os.FileInfo) {
	current, err := os.Lstat(path)
	if err == nil && os.SameFile(created, current) {
		_ = os.Remove(path)
	}
}

func checkSocket(path string) error {
	if !filepath.IsAbs(path) || filepath.Clean(path) != path {
		return errors.New("signer socket path must be absolute and canonical")
	}
	if err := validateSocketParent(filepath.Dir(path)); err != nil {
		return err
	}
	info, err := os.Lstat(path)
	if err != nil {
		return err
	}
	if err := validateSocketInfo(info); err != nil {
		return err
	}
	connection, err := net.DialTimeout("unix", path, 500*time.Millisecond)
	if err != nil {
		return err
	}
	return connection.Close()
}
