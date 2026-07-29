# GitHub Actions product deployment

These Compose overlays add the GitHub Actions product server and UI to a
Runtrue control plane. Runtrue owns the provider-neutral deployment and
`control` network; this repository owns the product server and frontend image
selection plus public edge routing.

Set `RUNTRUE_GITHUB_PRODUCT_SERVER_IMAGE` and
`RUNTRUE_GITHUB_PRODUCT_UI_IMAGE` to reviewed immutable GHCR digests. For a
loopback-only deployment, append the server and frontend overlays to the
Runtrue Compose command. For a public Traefik deployment, append all three
files after the Runtrue Compose files:

```text
-f /path/to/github-actions-frontend/deploy/compose.server.yml
-f /path/to/github-actions-frontend/deploy/compose.yml
-f /path/to/github-actions-frontend/deploy/compose.traefik.yml
```

The images are published as `ghcr.io/runtrue/github-actions-server` and
`ghcr.io/runtrue/github-actions-frontend-ui` when a `v*` release tag is pushed.
Pull requests build both images for validation without publishing them. Deploy
the digest returned by the successful publication workflow rather than a
mutable version tag.

## Publishing prerequisites

The `Publish product images` workflow uses the repository `GITHUB_TOKEN` to
publish both images to GHCR. The product server also compiles private Rust
dependencies from `runtrue/runtrue`, so the repository must have a
`RUNTRUE_SOURCE_TOKEN` Actions secret with read-only access to that repository.
