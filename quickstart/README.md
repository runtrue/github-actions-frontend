# Runtrue quickstart

This is a self-contained clean-host deployment package with one Compose model,
installer, state bootstrap, edge entrypoint, configuration example, and
generated-runner template. It never checks out Runtrue source code. Service and
runner images are pulled from the registry's `latest` tags. Repository actions
referenced by an exact commit are resolved from GitHub, built locally on first
use, admitted into the installation's signed OCI store, and reused by later
runs.

## Start from zero

Requirements: an amd64 Linux host with Docker Engine and Compose v2,
OpenSSL, and DNS for the Runtrue hostname pointed at the host. The bundled
Traefik mode also requires ports 80/443 to be open.

The three `ghcr.io/runtrue/github-*` packages must be public for an anonymous
clean-host install. While they remain private, authenticate Docker to GHCR with
a read-packages token before running the installer.

```sh
cd /root/runtrue/quickstart
cp quick-start.env.example quick-start.env
chmod 600 quick-start.env /root/github-app.private-key.pem /root/github-app.oauth-secret
# Edit quick-start.env, then:
sudo ./quick-start.sh
```

The installer is self-contained and never clones a Runtrue source repository. It
creates private state under `/opt/runtrue`, pulls the release
images, starts HTTPS, the browser UI, the GitHub Actions control plane, the
isolated GitHub App signer, repository-action builder and admission helper, and
Runtrue's Docker fleet autoscaler, then prints the GitHub App URLs and webhook
secret.
It is safe to rerun: the latest Runtrue images are pulled, generated `.env` and
Compose configuration are updated,
containers are reconciled, and existing database, TLS, signing, and webhook
secrets are preserved. Changed private credential contents and changes to the
installation identity (public origin, GitHub App, state root, or Compose project
name) are rejected and require an explicit migration. Existing deployments
with a different database installation ID can preserve it with
`RUNTRUE_INSTALLATION_ID`. Likewise, migrations must preserve the registered
GitHub App provider identity with `RUNTRUE_GITHUB_APP_CREDENTIAL_REFERENCE`.
The project name is
derived from the install root, preventing multiple installations on one host
from colliding.

Quick-start enables complete action logs by default, including jobs that receive
credentials. This is useful for self-hosted debugging but means a trusted action
can print a credential into the Runtrue log store. Set
`RUNTRUE_ALLOW_CREDENTIAL_TAINTED_LOGS=false` to restore fail-closed log
suppression. Published tainted frames are labeled
`credential_taint_unredacted_operator_opt_in` in the control plane.

If an interrupted earlier run left the public runner runtime bundle incomplete,
the installer prepares and validates a complete replacement before publishing
it. An existing valid private Wasm runtime key is preserved, and the incomplete
directory is retained under `RUNTRUE_INSTALL_ROOT/recovery` for inspection.

## Reuse an existing Traefik

Set two values in `quick-start.env`:

```sh
RUNTRUE_TRAEFIK_MODE=existing
RUNTRUE_TRAEFIK_NETWORK=proxy
RUNTRUE_TRAEFIK_CERT_RESOLVER=dynu
```

The named Docker network must already exist, and your Traefik container must be
attached to it. In this mode the quickstart does not start Traefik, does not
publish ports 80/443, and does not create separate ACME state.

The frontend receives Docker-provider labels for HTTP-to-HTTPS redirection,
the HTTPS router, TLS certificate resolver, internal port 3000, and health
checks. The existing Traefik must enable Docker discovery and be able to read
these labels. This works with `exposedByDefault=false` because the quickstart
sets `traefik.enable=true` in existing-Traefik mode.

```text
--providers.docker=true
--providers.docker.exposedbydefault=false
--providers.docker.network=proxy
```

If upgrading from the earlier file-provider quickstart, remove the old
`traefik-route.yml` from Traefik after confirming the labeled router is healthy.
Leaving both enabled can create duplicate routes.

## Repository actions

The default stack includes the complete repository-action path. The control
plane resolves an action reference such as
`ci/ai-review@154a9442ef3217b6a9b400c00a486b68fe221b6a`, checks the trusted action
metadata at that exact commit, and asks `action-builder` to build a Dockerfile
action only when its immutable build result is not already cached. The builder
automatically provisions a deployment-scoped Buildx `docker-container` driver
on the host Docker Engine. Its BuildKit daemon uses the host network so private,
VPN, and enterprise DNS routes available to the host remain reachable while it
fetches pinned base images. The action's Dockerfile build network remains
governed separately by the repository-action build policy. The builder exports
an OCI archive and passes it to
`action-admission`. The dedicated driver is required because Docker's default
`docker` driver cannot export OCI archives unless the daemon uses the
containerd image store. Admission imports the image into the same rootless Podman
store mounted by autoscaled runners and writes a signed manifest into the
shared runtime assets.

The trusted `action-builder` client joins only the `scm-egress` network because
Buildx performs registry token exchange through its client-side session. The
admission service remains offline. Docker Hub applies anonymous pull limits to
shared source addresses; production and shared-host installations should set
`RUNTRUE_DOCKERHUB_USERNAME` and `RUNTRUE_DOCKERHUB_TOKEN_SOURCE`. The installer
generates a private, persistent Docker client configuration from that read-only
access token without writing the token to the generated environment file.

The installer creates a deployment-local Ed25519 image-admission key and adds
only its public key to the runner trust directory. The private signing key is
mounted read-only into the isolated builder and never enters a runner.
When repository-action trust is added to an existing installation, the
installer stops the autoscaler and recycles only ephemeral runner containers
whose state mounts belong to this installation's claim root. Warm runners are
therefore recreated with the new keyring before new work is accepted.

Repository-action Dockerfiles remain fail-closed. Their base images must be
immutable and present in `RUNTRUE_REPOSITORY_ACTION_ALLOWED_BASE_IMAGES`. The
default allowlist contains the exact Node base used by `ci/ai-review`. Add other
reviewed base images as comma-separated immutable references in
`quick-start.env`; mutable tags are rejected.

The complete default service set is:

```text
github-signer
action-admission
action-builder
server
frontend
autoscaler
```

If either repository-action service is absent or unhealthy, `server` does not
start. The browser UI also reports repository-action builds as unavailable
instead of presenting a webhook-level success as proof that every discovered
workflow ran.

## Autoscaled runners

The quickstart has no fixed runner services. It uses Runtrue's existing Docker
autoscaler and a combined ephemeral runner template for both Wasm and OCI jobs.
The installer creates the pool, mints a tenant-scoped token containing only
`runner-fleet:read` and `runner-fleet:write`, installs the exact fleet policy,
fetches and validates the control plane's public capsule-signing verification
key, installs it in the generated runners' private trust store, and starts the
autoscaler as part of the normal stack. The private signing key never leaves
the control plane. Trust keys are named by their SHA-256 key ID so reruns are
idempotent and older verification keys remain available across key rotation.
The pool starts at zero,
launches a runner when compatible demand is queued, and returns to zero after
the idle timeout.

To keep one warm, idle runner instead of scaling to zero, set these values in
`quick-start.env` and rerun the installer:

```sh
RUNTRUE_AUTOSCALER_MINIMUM_WORKERS=1
RUNTRUE_AUTOSCALER_MINIMUM_IDLE_WORKERS=1
```

Both settings default to zero and must not exceed
`RUNTRUE_AUTOSCALER_MAXIMUM_WORKERS`. When either minimum is nonzero, the
installer automatically binds warm workers to Quickstart's admitted baseline
runtime compatibility digest. `RUNTRUE_AUTOSCALER_SCALE_UP_BATCH` defaults to
the maximum worker count, allowing queued demand to launch the required fleet
in one reconciliation; set it lower only to deliberately ramp up gradually.

Webhook and workflow preparation happens before autoscaled runners receive
jobs. Quickstart processes four SCM tasks concurrently by default. For a busy
installation, set `RUNTRUE_SCM_WORKERS` independently (between 1 and 32) in
`quick-start.env`; for example, `RUNTRUE_SCM_WORKERS=10`.

The installer pulls the runtime assets from the public
`ghcr.io/runtrue/runtrue-runner:quickstart-runtime-bundle-latest` tag by
default. The bundle provides the admitted Wasm artifacts and OCI runtime
policy:

```text
runtime-bundle/
├── wasm/
│   ├── components/
│   ├── manifests/
│   └── keys/
└── oci/
    ├── image-store.tar.gz
    ├── manifests/
    ├── image-keys/
    ├── runtime-environment.json
    └── seccomp.json
```

The installer deliberately creates a fresh deployment-local Podman store and
empty OCI manifest/key directories instead of copying the bundle's expanded
rootless store. Rootless storage is tied to a host user namespace and is not a
portable deployment artifact. Exact-commit repository actions are built and
admitted locally on first use. The bundle's private Wasm runtime key is also
discarded; the installer generates one locally, installs it with mode `0600`,
and never uploads it. The runner and bundle image settings are optional
overrides; no runtime source path, preloaded OCI image, lock file, or
compatibility digest is required in `quick-start.env`.

The installer records the exact runtime-bundle image ID and refreshes the
installed bundle whenever its configured image advances. The deployment's
private Wasm runtime key is preserved during that replacement. This prevents
an older signed component manifest from remaining installed after a runner
upgrade.

The installer pulls `ghcr.io/runtrue/runtrue-runner:latest`, resolves its
immutable registry digest, hashes the runner executable from that exact image,
and binds the executable identity into the fleet configuration. A generic
operator-approved Docker template is bound to each queued job's exact runtime
compatibility digest when the autoscaler launches a runner.
When `latest` advances, rerunning the installer updates the runner template,
runtime bundle, and fleet configuration.

Only the autoscaler receives the Docker socket. Generated runner containers are
ephemeral, bounded to one concurrent job, and receive `/dev/fuse` plus outer
Docker privilege because the current OCI backend runs nested rootless Podman.
Wasm jobs use the same generated runner. No microVM backend is enabled.

Autoscaler claim and per-runner state lives under
`/var/lib/runtrue-autoscaler/<compose-project>/claims` by default. This path is
intentionally outside `/root`: the non-root autoscaler must access it and pass
the identical host path to Docker when launching ephemeral runners. Static
runtime assets and control-plane state remain under `RUNTRUE_INSTALL_ROOT`.
