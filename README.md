# Runtrue GitHub Actions frontend

This repository owns Runtrue's GitHub Actions-specific product surface:

- the strict, fail-closed workflow frontend that analyzes GitHub Actions YAML,
  reports compatibility findings, and translates supported workflows into
  native Runtrue workflow YAML and lockfile material; and
- the browser UI and same-origin proxy used to install GitHub repositories,
  manage GitHub-backed configuration, and inspect workflow runs.

The adapter is not an execution engine. Runtrue core independently validates
the adapter's bounded output and derives its digests, configuration identity,
and provenance before planning or execution.

## Compatibility

This release is built against Runtrue core revision
`d0056dc14d4b85e136a686c29af229c6f29a9b6d`. All Runtrue packages in
`Cargo.toml` use that one exact revision so the frontend contract and workflow
types have a single reviewed source.

The adapter identity is `runtrue.github-actions`; its current frontend
generation is `2`, and the supported frontend contract generation is `2`.

The browser UI is versioned and deployed independently from Runtrue core. Its
backend contract is documented in [`ui/README.md`](ui/README.md).

## Quick-start binary

`product/server` also builds `runtrue-quickstart`, a frontend-owned
single-process distribution for development and low-environment deployments.
It embeds this repository's UI and GitHub Actions adapter together with the
Runtrue backend and its in-process SCM, GitHub lifecycle, scheduler-maintenance,
runner-control, and optional autoscaler workers:

```text
cargo build --locked --release -p runtrue-server --bin runtrue-quickstart
```

The normal core server and standalone UI container remain separate deployment
options. Job execution runners are deliberately not moved into the trusted
quick-start process. Quick-start deployments should use Runtrue's existing
autoscaler and provider runtime to launch ephemeral runners from queued demand;
they must not embed a separate fixed-runner lifecycle in this product binary.

The pinned Runtrue core revision is available to anonymous clean checkouts.

## Development

Use Rust 1.94 or newer, then run:

```text
cargo fmt --all -- --check
cargo test --workspace --all-targets --locked
cargo clippy --workspace --all-targets --locked -- -D warnings
```

Use Node.js 22 or newer for the browser UI:

```text
npm --prefix ui test
node --check ui/public/app.js
docker build -f ui/Containerfile ui
```

GitHub Actions verifies formatting, linting, Rust, Go, and browser tests on
pull requests and pushes to `main`. Product-image builds also run on pull
requests, while pushes and version tags publish OCI images with provenance and
SBOM metadata to GHCR. Public-repository image builds also publish GitHub
artifact attestations.

## License

Licensed under the Apache License, Version 2.0. See `LICENSE`.
