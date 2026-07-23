# GitHub Actions product deployment

These Compose overlays add the GitHub Actions product UI to a Runtrue control
plane. Runtrue owns the provider-neutral `server` and `control` network; this
repository owns the `frontend` service, its image selection, and public edge
routing.

For a loopback-only deployment, append `deploy/compose.yml` to the Runtrue
Compose command. For a public Traefik deployment, append both files after the
Runtrue Compose files:

```text
-f /path/to/github-actions-frontend/deploy/compose.yml
-f /path/to/github-actions-frontend/deploy/compose.traefik.yml
```

Set `RUNTRUE_GITHUB_PRODUCT_UI_IMAGE` to an immutable image digest when
overriding the reviewed default.
