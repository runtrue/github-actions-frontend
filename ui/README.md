# Runtrue GitHub Actions UI

This directory contains the browser UI for Runtrue's GitHub Actions use case.
It is not the generic Runtrue product UI. The service serves static assets and
proxies all other requests to Runtrue core so browser sessions, CSRF tokens,
OAuth callbacks, and API requests remain same-origin.

## Backend contract

Set `BACKEND_ORIGIN` to the private Runtrue server origin. The public browser
origin must route only to this UI service; the proxy forwards these backend
surfaces without changing their paths:

- `/auth/*` for login, callback, session, and logout;
- `/api/v1/session`, `/api/v1/policy-status`, and `/api/v1/ui/*` for the
  browser-facing API;
- `/ui/github/*` for GitHub installation mutations and compatibility
  redirects; and
- backend health and problem responses that are intentionally exposed through
  the same public origin.

The UI never receives GitHub App private keys, webhook secrets, backend
security keys, or direct database access. Those remain owned by Runtrue core.

## Development

```text
npm test
BACKEND_ORIGIN=http://127.0.0.1:8080 npm start
docker build -t runtrue-github-actions-ui:dev .
```

The container listens on port `3000` and exposes `/frontend-healthz`.

## Release ordering

Publish the UI as `ghcr.io/runtrue/github-actions-frontend-ui:<version>` with
`RUNTRUE_VERSION` and `RUNTRUE_REVISION` build arguments set to the reviewed
version and full source commit. Record the resulting image digest, then update
Runtrue core's `RUNTRUE_GITHUB_ACTIONS_UI_IMAGE` selection. The external image
must exist before the corresponding core change is merged or deployed.
