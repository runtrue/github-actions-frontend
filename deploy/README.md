# GitHub Actions product deployment

These Compose overlays add the GitHub Actions product server and UI to a
Runtrue control plane. Runtrue owns the provider-neutral deployment and
`control` network; this repository owns the product server and frontend image
selection plus public edge routing.

Set `RUNTRUE_GITHUB_PRODUCT_SERVER_IMAGE`, `RUNTRUE_GITHUB_PRODUCT_UI_IMAGE`,
and `RUNTRUE_AUTOSCALER_IMAGE` to reviewed immutable GHCR digests. For a
loopback-only deployment, append the server and frontend overlays to the
Runtrue Compose command. For a public Traefik deployment, append all three
files after the Runtrue Compose files. Include Runtrue core's autoscaler file
before the product server overlay when on-demand capacity is enabled:

```text
-f /path/to/runtrue/deploy/compose.autoscaler.yml
-f /path/to/github-actions-frontend/deploy/compose.server.yml
-f /path/to/github-actions-frontend/deploy/compose.autoscaler.yml
-f /path/to/github-actions-frontend/deploy/compose.yml
-f /path/to/github-actions-frontend/deploy/compose.traefik.yml
```

The images are published as `ghcr.io/runtrue/github-actions-server` and
`ghcr.io/runtrue/github-actions-frontend-ui` when a `v*` release tag is pushed.
Pull requests build both images for validation without publishing them. Deploy
the digest returned by the successful publication workflow rather than a
mutable version tag.

The `Publish product images` workflow uses the repository `GITHUB_TOKEN` to
publish both images to GHCR. The product server fetches its public Rust
dependencies from `runtrue/runtrue` without a separate source credential.

## Autoscaled quick-start capacity

Do not add a product-specific runner service to these overlays. Use Runtrue
core's existing `deploy/compose.autoscaler.yml` after its runner TLS overlay,
and configure the target pool's scaling policy and exact provider templates as
described by Runtrue core. The autoscaler observes queued demand, launches
ephemeral runners through the configured provider, and retires idle capacity.
Consequently, the runners page may correctly show zero runners before the first
compatible job is queued.

Only the autoscaler service should receive the Docker socket. The GitHub Actions
product server and browser UI do not need container-runtime access.
