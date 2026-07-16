# Changelog

## 0.1.0 - 2026-07-16

- Extract the GitHub Actions frontend into an independently versioned package.
- Preserve strict YAML decoding, compatibility analysis, native workflow and
  lockfile generation, bounded structured errors, and configuration-bound
  provenance.
- Include the existing supported, unsupported, duplicate-key, and unsafe-input
  fixtures and security tests.
- Pin every Runtrue dependency to reviewed core revision
  `0ff23cf70485260741473993156fca2d5a0c7a40`.
- Keep release validation external to this repository; no GitHub Actions
  workflow is installed.
