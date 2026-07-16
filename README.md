# Runtrue GitHub Actions frontend

This repository contains Runtrue's strict, fail-closed GitHub Actions workflow
frontend. It analyzes GitHub Actions YAML, reports compatibility findings, and
translates supported workflows into native Runtrue workflow YAML and lockfile
material.

The adapter is not an execution engine. Runtrue core independently validates
the adapter's bounded output, digests, contract generation, configuration, and
provenance before planning or execution.

## Compatibility

This release is built against Runtrue core revision
`0ff23cf70485260741473993156fca2d5a0c7a40`. All Runtrue packages in
`Cargo.toml` use that one exact revision so the frontend contract and workflow
types have a single reviewed source.

The adapter identity is `runtrue.github-actions`; its current frontend
generation is `1`, and the supported frontend contract generation is `1`.

## Development

Use Rust 1.94 or newer, then run:

```text
cargo fmt --all -- --check
cargo test --locked
cargo clippy --all-targets --locked -- -D warnings
```

GitHub Actions workflow files are deliberately not installed in this
repository. Release validation is performed by the Runtrue integration gates.

## License

Licensed under the Apache License, Version 2.0. See `LICENSE`.
