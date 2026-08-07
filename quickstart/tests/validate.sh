#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

QUICKSTART_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
temporary=$(mktemp -d)
trap 'rm -rf -- "$temporary"' EXIT HUP INT TERM

bash -n "${QUICKSTART_DIR}/quick-start.sh"
bash -n "${QUICKSTART_DIR}/bootstrap-state.sh"
bash -n "${QUICKSTART_DIR}/traefik-entrypoint.sh"

installer=$(<"${QUICKSTART_DIR}/quick-start.sh")
for required in \
  RUNTRUE_DOCKERHUB_USERNAME \
  RUNTRUE_DOCKERHUB_TOKEN_SOURCE \
  'https://index.docker.io/v1/' \
  'repository-actions/builder/docker-config/config.json' \
  '.bundle-image-id' \
  'refreshing stale or incomplete runner runtime bundle'; do
  [[ "$installer" == *"$required"* ]] || {
    printf 'quickstart installer is missing required deployment support: %s\n' "$required" >&2
    exit 1
  }
done

cat >"${temporary}/runtime.env" <<EOF
RUNTRUE_RUNTIME_UID=10001
RUNTRUE_RUNTIME_GID=10001
RUNTRUE_DOCKER_GID=999
RUNTRUE_DOCKER_BINARY=/usr/bin/docker
RUNTRUE_DOCKER_BUILDX_PLUGIN=/usr/libexec/docker/cli-plugins/docker-buildx
RUNTRUE_COMPOSE_PROJECT_NAME=runtrue-test
RUNTRUE_INSTALLATION_ID=single-node
COMPOSE_PROFILES=
RUNTRUE_STATE_DIR=${temporary}/state
RUNTRUE_PUBLIC_ORIGIN=https://runtrue.example.test
RUNTRUE_ACME_EMAIL=ops@example.test
RUNTRUE_EDGE_HTTP_PORT=80
RUNTRUE_EDGE_HTTPS_PORT=443
RUNTRUE_EDGE_NETWORK_NAME=proxy
RUNTRUE_EDGE_NETWORK_EXTERNAL=true
RUNTRUE_EDGE_UPSTREAM_NAME=runtrue-test-frontend
RUNTRUE_TRAEFIK_DOCKER_ENABLED=true
RUNTRUE_PUBLIC_HOST=runtrue.example.test
RUNTRUE_TRAEFIK_ROUTER_NAME=runtrue-test
RUNTRUE_TRAEFIK_HTTP_ENTRYPOINT=web
RUNTRUE_TRAEFIK_HTTPS_ENTRYPOINT=websecure
RUNTRUE_TRAEFIK_CERT_RESOLVER=letsencrypt
RUNTRUE_GITHUB_WEB_ORIGIN=https://github.example.test
RUNTRUE_GITHUB_API_ORIGIN=https://github.example.test/api/v3
RUNTRUE_GITHUB_APP_ID=42
RUNTRUE_GITHUB_APP_SLUG=runtrue-test
RUNTRUE_GITHUB_OAUTH_CLIENT_ID=test-client
RUNTRUE_GITHUB_OAUTH_ADMIN_USER_IDS=42
RUNTRUE_AUTOSCALER_IMAGE=ghcr.io/runtrue/runtrue-autoscaler:latest
RUNTRUE_AUTOSCALER_POOL_ID=pool-quickstart
RUNTRUE_AUTOSCALER_CLAIM_ROOT=/var/lib/runtrue-autoscaler/runtrue-test/claims
RUNTRUE_RUNNER_IMAGE=ghcr.io/runtrue/runtrue-runner@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
RUNTRUE_ACTION_ADMISSION_CONTAINER=runtrue-test-action-admission
RUNTRUE_REPOSITORY_ACTION_IMAGE_REPOSITORY=runtrue.local/repository-actions
RUNTRUE_REPOSITORY_ACTION_BUILDX_BUILDER=runtrue-test-repository-actions
RUNTRUE_REPOSITORY_ACTION_ALLOWED_BASE_IMAGES=node:22-bookworm-slim@sha256:53ada149d435c38b14476cb57e4a7da73c15595aba79bd6971b547ceb6d018bf
RUNTRUE_GITHUB_APP_CREDENTIAL_REFERENCE=provider://github-app/production
EOF

docker compose \
  --env-file "${temporary}/runtime.env" \
  -f "${QUICKSTART_DIR}/compose.yml" \
  config --format json >"${temporary}/compose.json"

python3 - "${temporary}/compose.json" <<'PY'
import json
import subprocess
import sys

with open(sys.argv[1], encoding="utf-8") as source:
    compose = json.load(source)

services = compose["services"]
required = {
    "action-admission",
    "action-builder",
    "autoscaler",
    "frontend",
    "github-signer",
    "server",
}
missing = sorted(required - services.keys())
if missing:
    raise SystemExit(f"quickstart compose is missing services: {', '.join(missing)}")

if services["autoscaler"].get("image") != "ghcr.io/runtrue/runtrue-autoscaler:latest":
    raise SystemExit("quickstart does not use the current Runtrue autoscaler release")

server = services["server"]
environment = server["environment"]
if environment.get("RUNTRUE_REPOSITORY_ACTION_BUILDER_SOCKET") != "/var/lib/runtrue-action-builder/builder.sock":
    raise SystemExit("server repository-action builder socket is not configured")
if environment.get("RUNTRUE_REPOSITORY_ACTION_CONTEXT_ROOT") != "/var/lib/runtrue-action-builder/source":
    raise SystemExit("server repository-action context root is not configured")
if "action-builder" not in server.get("depends_on", {}):
    raise SystemExit("server does not require the action builder to be healthy")

builder = services["action-builder"]
if "action-admission" not in builder.get("depends_on", {}):
    raise SystemExit("action builder does not require admission to be healthy")
if builder.get("networks") != {"scm-egress": None}:
    raise SystemExit("action builder must join only the registry egress network")
builder_command = " ".join(builder.get("command", []))
syntax = subprocess.run(
    ["/bin/sh", "-n"], input=builder_command, text=True, capture_output=True, check=False
)
if syntax.returncode != 0:
    raise SystemExit(f"action builder bootstrap command is invalid: {syntax.stderr.strip()}")
if "--driver docker-container" not in builder_command:
    raise SystemExit("action builder does not provision an OCI-capable Buildx driver")
if "--driver-opt network=host" not in builder_command:
    raise SystemExit("action builder does not give BuildKit access to the host registry route")
if "grep -Fq 'network=\"host\"'" not in builder_command or "docker buildx rm" not in builder_command:
    raise SystemExit("action builder does not reconcile an existing bridge-network builder")
if "docker-container-host-network-driver" not in builder_command:
    raise SystemExit("action builder does not identify the reviewed host-network BuildKit environment")
if "--buildx-builder" not in builder_command or "runtrue-test-repository-actions" not in builder_command:
    raise SystemExit("action builder does not use the deployment-scoped Buildx builder")
if builder.get("environment", {}).get("DOCKER_CONFIG") != "/var/lib/runtrue-action-builder/docker-config":
    raise SystemExit("action builder does not persist its Buildx client configuration")

admission = services["action-admission"]
if admission.get("network_mode") != "none" or not admission.get("privileged"):
    raise SystemExit("action admission isolation is incomplete")
if "podman --root /var/lib/runtrue-igh-oci/image-store info" not in " ".join(admission.get("command", [])):
    raise SystemExit("action admission does not initialize its rootless Podman namespace")

builder_mounts = {mount["target"] for mount in builder.get("volumes", [])}
required_mounts = {
    "/var/lib/runtrue-action-builder",
    "/var/lib/runtrue-igh-oci/manifests",
    "/var/run/docker.sock",
    "/run/runtrue-action-admission/image-signing.key",
}
if not required_mounts.issubset(builder_mounts):
    raise SystemExit("action builder is missing required state or admission mounts")
PY

printf 'quickstart deployment validation passed\n'
