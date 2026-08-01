# Runtrue GitHub App signer

This Linux-only Go component owns a GitHub App RSA private key and exposes one
operation over a private Unix socket: minting a short-lived App JWT for an exact
Runtrue App id, credential reference, and request time. The Runtrue server sees
only the socket. It never receives the private key.

Go is intentional here. The framed signer contract is a language-neutral
Runtrue boundary, and a small independently built service demonstrates that an
extension does not have to share the Rust implementation of the execution
kernel. Reimplementing the signer in Rust later would not change the protocol
or the server.

## Build and test

Go 1.24 or newer is required. The component has no third-party dependencies.

```sh
cd components/github-signer
go test ./...
CGO_ENABLED=0 go build -trimpath -ldflags='-s -w -buildid=' \
  -o runtrue-github-signer .
```

The output binary is ignored by Git when built in this directory.

## Run

The signer and server must run as the same numeric user, or the server must run
as root. The socket is created with exact mode `0600`. The private-key file
must be a regular, non-linked PKCS#1 or PKCS#8 RSA key of at least 2048 bits,
with no group or other permissions.

```sh
export RUNTRUE_GITHUB_SIGNER_SOCKET=/run/runtrue/github-app-signer.sock
export RUNTRUE_GITHUB_APP_PRIVATE_KEY_FILE=/run/secrets/github-app-private-key.pem
export RUNTRUE_GITHUB_APP_ID=123
export RUNTRUE_GITHUB_APP_CREDENTIAL_REFERENCE=provider://github-app/production

./runtrue-github-signer
```

Readiness can be checked without loading the private key again:

```sh
./runtrue-github-signer --check-socket \
  /run/runtrue/github-app-signer.sock
```

The process has no network dependency and should run with networking disabled.
Give only this process read access to the App private key. Share only the socket
with `runtrue-server`.
