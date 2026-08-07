#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly SCRIPT_DIR
readonly CONFIG_FILE="${1:-${SCRIPT_DIR}/quick-start.env}"
readonly STATE_BOOTSTRAP="${SCRIPT_DIR}/bootstrap-state.sh"

die() {
  printf 'quick-start: %s\n' "$*" >&2
  exit 1
}

require_value() {
  local name=$1
  [[ -n "${!name:-}" && "${!name}" != CHANGE_ME ]] || die "set ${name} in ${CONFIG_FILE}"
}

require_private_file() {
  local path=$1 label=$2 mode
  [[ -f "$path" && ! -L "$path" && -s "$path" ]] || die "${label} is not a nonempty regular file: ${path}"
  mode=$(stat -c '%a' -- "$path")
  (((8#$mode & 8#077) == 0)) || die "${label} must not be accessible by group or other: ${path}"
}

install_private_file() {
  local source=$1 destination=$2 uid=$3 gid=$4
  if [[ -e "$destination" || -L "$destination" ]]; then
    [[ -f "$destination" && ! -L "$destination" ]] || die "unsafe existing path: ${destination}"
    cmp -s -- "$source" "$destination" || die "refusing to replace existing credential: ${destination}"
  else
    install -m 0600 -o "$uid" -g "$gid" -- "$source" "$destination"
  fi
  [[ "$(stat -c '%u:%g:%a' -- "$destination")" == "${uid}:${gid}:600" ]] ||
    die "incorrect ownership or mode: ${destination}"
}

runner_binary_digest() {
  local image=$1 temporary container digest
  temporary=$(mktemp -- "${RUNTRUE_STATE_DIR}/autoscaler/.runtrue-runner.XXXXXXXX")
  container=$(docker create "$image" /)
  if ! docker cp "${container}:/usr/local/bin/runtrue-runner" "$temporary"; then
    docker rm -f "$container" >/dev/null 2>&1 || true
    rm -f -- "$temporary"
    die "could not inspect runner executable in image: ${image}"
  fi
  docker rm -f "$container" >/dev/null
  digest=$(sha256sum "$temporary" | awk '{print $1}')
  rm -f -- "$temporary"
  printf 'sha256:%s\n' "$digest"
}

install_runtime_bundle() {
  local image=$1 destination=$2 temporary container backup='' preserved_key='' bundle_complete
  local bundle_image_id installed_bundle_image_id=''
  local -a required_directories=(
    wasm/components wasm/manifests wasm/keys
    oci/image-store oci/manifests oci/image-keys
  )
  local -a required_files=(
    wasm/runtime.key oci/runtime-environment.json oci/seccomp.json
    oci/.deployment-local-store-v3 .bundle-image-id
  )
  docker pull "$image" >/dev/null
  bundle_image_id=$(docker image inspect "$image" --format '{{.Id}}')
  [[ "$bundle_image_id" =~ ^sha256:[0-9a-f]{64}$ ]] ||
    die "runtime bundle image did not resolve to an exact image ID: ${image}"
  if [[ -e "$destination" || -L "$destination" ]]; then
    [[ -d "$destination" && ! -L "$destination" ]] || die "unsafe runtime bundle destination: ${destination}"
    bundle_complete=true
    for path in "${required_directories[@]}"; do
      [[ -d "${destination}/${path}" && ! -L "${destination}/${path}" ]] || bundle_complete=false
    done
    for path in "${required_files[@]}"; do
      [[ -f "${destination}/${path}" && ! -L "${destination}/${path}" ]] || bundle_complete=false
    done
    if [[ -f "${destination}/.bundle-image-id" && ! -L "${destination}/.bundle-image-id" ]]; then
      installed_bundle_image_id=$(tr -d '\r\n' <"${destination}/.bundle-image-id")
    fi
    if "$bundle_complete" &&
      [[ "$(stat -c '%s' -- "${destination}/wasm/runtime.key")" == 64 ]] &&
      [[ "$installed_bundle_image_id" == "$bundle_image_id" ]]; then
      return
    fi
    if [[ -f "${destination}/wasm/runtime.key" && ! -L "${destination}/wasm/runtime.key" &&
          "$(stat -c '%s' -- "${destination}/wasm/runtime.key")" == 64 ]]; then
      preserved_key="${destination}/wasm/runtime.key"
    fi
    printf 'quick-start: refreshing stale or incomplete runner runtime bundle at %s\n' "$destination" >&2
  fi
  temporary=$(mktemp -d -- "${RUNTRUE_STATE_DIR}/autoscaler/.runtime-assets.XXXXXXXX")
  container=$(docker create "$image" /)
  if ! docker cp "${container}:/runtrue-runtime-bundle/." "$temporary/"; then
    docker rm -f "$container" >/dev/null 2>&1 || true
    die "could not extract runner runtime bundle image: ${image}"
  fi
  docker rm -f "$container" >/dev/null
  if find "$temporary" -mindepth 1 \( -type l -o \( ! -type f ! -type d \) \) -print -quit | grep -q .; then
    die "runner runtime bundle contains a symbolic link or special file: ${image}"
  fi
  for path in \
    wasm/components wasm/manifests wasm/keys \
    oci/image-store.tar.gz oci/manifests oci/image-keys \
    oci/runtime-environment.json oci/seccomp.json
  do
    [[ -e "${temporary}/${path}" ]] || die "runner runtime bundle is missing ${path}"
  done
  chown -R "${RUNTRUE_RUNTIME_UID}:${RUNTRUE_RUNTIME_GID}" -- "$temporary"
  # Repository OCI actions are admitted into a deployment-local store on
  # demand. A pre-expanded rootless Podman store is not portable between host
  # user namespaces, even when its numeric ownership is preserved.
  rm -f -- "${temporary}/oci/image-store.tar.gz"
  rm -rf -- \
    "${temporary}/oci/image-store" \
    "${temporary}/oci/manifests" \
    "${temporary}/oci/image-keys"
  install -d -m 0700 -o "$RUNTRUE_RUNTIME_UID" -g "$RUNTRUE_RUNTIME_GID" \
    "${temporary}/oci/image-store" \
    "${temporary}/oci/manifests" \
    "${temporary}/oci/image-keys"
  : >"${temporary}/oci/.deployment-local-store-v3"
  printf '%s\n' "$bundle_image_id" >"${temporary}/.bundle-image-id"
  if [[ -n "$preserved_key" ]]; then
    install -m 0600 -- "$preserved_key" "${temporary}/wasm/runtime.key"
  else
    openssl rand 64 >"${temporary}/wasm/runtime.key"
  fi
  find "$temporary" -path "${temporary}/oci/image-store" -prune -o \
    -exec chown "${RUNTRUE_RUNTIME_UID}:${RUNTRUE_RUNTIME_GID}" -- {} +
  find "$temporary" -path "${temporary}/oci/image-store" -prune -o -type d -exec chmod 0700 -- {} +
  find "$temporary" -path "${temporary}/oci/image-store" -prune -o -type f -exec chmod 0600 -- {} +
  for path in "${required_directories[@]}"; do
    [[ -d "${temporary}/${path}" && ! -L "${temporary}/${path}" ]] ||
      die "prepared runner runtime bundle is missing directory ${path}"
  done
  for path in "${required_files[@]}"; do
    [[ -f "${temporary}/${path}" && ! -L "${temporary}/${path}" ]] ||
      die "prepared runner runtime bundle is missing file ${path}"
  done
  [[ "$(stat -c '%s' -- "${temporary}/wasm/runtime.key")" == 64 ]] ||
    die 'prepared Wasm runtime key has an invalid length'
  if [[ -e "$destination" || -L "$destination" ]]; then
    install -d -m 0700 -- "${RUNTRUE_INSTALL_ROOT}/recovery"
    backup="${RUNTRUE_INSTALL_ROOT}/recovery/runtime-assets.incomplete.$(openssl rand -hex 8)"
    [[ ! -e "$backup" && ! -L "$backup" ]] || die "runtime bundle recovery path already exists: ${backup}"
    mv -- "$destination" "$backup"
  fi
  if ! mv -- "$temporary" "$destination"; then
    if [[ -n "$backup" && ! -e "$destination" && ! -L "$destination" ]]; then
      mv -- "$backup" "$destination"
    fi
    die 'could not publish the prepared runner runtime bundle'
  fi
  if [[ -n "$backup" ]]; then
    printf 'quick-start: incomplete runtime bundle retained for recovery at %s\n' "$backup" >&2
  fi
}

install_repository_action_signing_key() {
  local private_key="${RUNTRUE_STATE_DIR}/repository-actions/image-signing.key"
  local public_key="${RUNTRUE_STATE_DIR}/autoscaler/runtime-assets/oci/image-keys/local-repository-actions.hex"
  local temporary private_der public_der present=0

  [[ -e "$private_key" || -L "$private_key" ]] && ((present += 1))
  [[ -e "$public_key" || -L "$public_key" ]] && ((present += 1))
  if ((present == 2)); then
    [[ -f "$private_key" && ! -L "$private_key" && "$(stat -c '%s' -- "$private_key")" == 32 ]] ||
      die "repository-action signing key is invalid: ${private_key}"
    [[ -f "$public_key" && ! -L "$public_key" && "$(stat -c '%s' -- "$public_key")" == 32 ]] ||
      die "repository-action verifying key is invalid: ${public_key}"
    [[ "$(stat -c '%u:%g:%a' -- "$private_key")" == "${RUNTRUE_RUNTIME_UID}:${RUNTRUE_RUNTIME_GID}:600" ]] ||
      die 'repository-action signing key has incorrect ownership or mode'
    [[ "$(stat -c '%u:%g:%a' -- "$public_key")" == "${RUNTRUE_RUNTIME_UID}:${RUNTRUE_RUNTIME_GID}:600" ]] ||
      die 'repository-action verifying key has incorrect ownership or mode'
    return
  fi
  if ((present == 1)) && [[ -f "$private_key" && ! -L "$private_key" ]]; then
    [[ "$(stat -c '%s' -- "$private_key")" == 32 ]] ||
      die "repository-action signing key is invalid: ${private_key}"
    [[ "$(stat -c '%u:%g:%a' -- "$private_key")" == "${RUNTRUE_RUNTIME_UID}:${RUNTRUE_RUNTIME_GID}:600" ]] ||
      die 'repository-action signing key has incorrect ownership or mode'
    temporary=$(mktemp -d -- "${RUNTRUE_STATE_DIR}/repository-actions/.image-key.XXXXXXXX")
    chmod 0700 -- "$temporary"
    private_der="${temporary}/private.der"
    public_der="${temporary}/public.der"
    {
      printf '\x30\x2e\x02\x01\x00\x30\x05\x06\x03\x2b\x65\x70\x04\x22\x04\x20'
      dd if="$private_key" bs=32 count=1 status=none
    } >"$private_der"
    openssl pkey -inform DER -in "$private_der" -pubout -outform DER -out "$public_der" 2>/dev/null ||
      die 'repository-action signing key could not be decoded'
    tail -c 32 -- "$public_der" >"${temporary}/public.raw"
    [[ "$(stat -c '%s' -- "${temporary}/public.raw")" == 32 ]] ||
      die 'OpenSSL did not derive a valid repository-action verifying key'
    install -m 0600 -o "$RUNTRUE_RUNTIME_UID" -g "$RUNTRUE_RUNTIME_GID" \
      "${temporary}/public.raw" "$public_key"
    rm -rf -- "$temporary"
    return
  fi
  ((present == 0)) || die 'partial repository-action signing state found; refusing to replace credentials'

  temporary=$(mktemp -d -- "${RUNTRUE_STATE_DIR}/repository-actions/.image-key.XXXXXXXX")
  chmod 0700 -- "$temporary"
  openssl genpkey -algorithm ED25519 -out "${temporary}/key.pem" 2>/dev/null
  private_der="${temporary}/private.der"
  public_der="${temporary}/public.der"
  openssl pkey -in "${temporary}/key.pem" -outform DER -out "$private_der" 2>/dev/null
  openssl pkey -in "${temporary}/key.pem" -pubout -outform DER -out "$public_der" 2>/dev/null
  tail -c 32 -- "$private_der" >"${temporary}/private.raw"
  tail -c 32 -- "$public_der" >"${temporary}/public.raw"
  [[ "$(stat -c '%s' -- "${temporary}/private.raw")" == 32 &&
     "$(stat -c '%s' -- "${temporary}/public.raw")" == 32 ]] ||
    die 'OpenSSL did not produce a valid Ed25519 repository-action key pair'
  install -m 0600 -o "$RUNTRUE_RUNTIME_UID" -g "$RUNTRUE_RUNTIME_GID" \
    "${temporary}/private.raw" "$private_key"
  install -m 0600 -o "$RUNTRUE_RUNTIME_UID" -g "$RUNTRUE_RUNTIME_GID" \
    "${temporary}/public.raw" "$public_key"
  rm -rf -- "$temporary"
  RUNTRUE_REPOSITORY_ACTION_KEY_CREATED=true
}

install_repository_action_registry_credentials() {
  [[ -n "$RUNTRUE_DOCKERHUB_USERNAME" ]] || return 0
  local destination="${RUNTRUE_STATE_DIR}/repository-actions/builder/docker-config/config.json"
  local temporary
  install -d -m 0700 -o "$RUNTRUE_RUNTIME_UID" -g "$RUNTRUE_RUNTIME_GID" \
    "${RUNTRUE_STATE_DIR}/repository-actions/builder/docker-config"
  temporary=$(mktemp -- "${RUNTRUE_STATE_DIR}/repository-actions/builder/.docker-config.XXXXXXXX")
  python3 - "$RUNTRUE_DOCKERHUB_USERNAME" "$RUNTRUE_DOCKERHUB_TOKEN_SOURCE" "$temporary" <<'PY'
import base64
import json
import pathlib
import sys

username, token_path, destination = sys.argv[1:]
token = pathlib.Path(token_path).read_text(encoding="utf-8").rstrip("\r\n")
if not token or "\n" in token or "\r" in token:
    raise SystemExit("Docker Hub token must contain exactly one nonempty line")
auth = base64.b64encode(f"{username}:{token}".encode()).decode()
pathlib.Path(destination).write_text(json.dumps({
    "auths": {"https://index.docker.io/v1/": {"auth": auth}}
}, indent=2) + "\n", encoding="utf-8")
PY
  install_private_file \
    "$temporary" \
    "$destination" \
    "$RUNTRUE_RUNTIME_UID" \
    "$RUNTRUE_RUNTIME_GID"
  rm -f -- "$temporary"
}

recycle_autoscaled_runners_for_repository_action_trust() {
  local force=${1:-false}
  "$RUNTRUE_REPOSITORY_ACTION_KEY_CREATED" || "$force" || return 0
  local container_id mount_source recycled=0
  while IFS= read -r container_id; do
    [[ -n "$container_id" ]] || continue
    while IFS= read -r mount_source; do
      if [[ "$mount_source" == "${RUNTRUE_AUTOSCALER_CLAIM_ROOT}/"* ]]; then
        docker rm -f "$container_id" >/dev/null
        ((recycled += 1))
        break
      fi
    done < <(docker inspect --format '{{range .Mounts}}{{println .Source}}{{end}}' "$container_id")
  done < <(docker ps -aq --filter label=dev.runtrue.autoscaled=true)
  if ((recycled > 0)); then
    printf 'quick-start: recycled %s ephemeral runner(s) to load repository-action trust\n' "$recycled"
  fi
}

clear_stale_oci_runroot() {
  local runroot="${RUNTRUE_STATE_DIR}/autoscaler/runtime-assets/oci/image-store/.runtrue-runroot"
  [[ -e "$runroot" || -L "$runroot" ]] || return 0
  [[ -d "$runroot" && ! -L "$runroot" ]] ||
    die "unsafe transient OCI runroot: ${runroot}"
  rm -rf -- "$runroot"
  printf 'quick-start: removed transient OCI runroot from the shared image store\n'
}

render_autoscaler_template() {
  local destination=$1 temporary
  temporary=$(mktemp -- "${RUNTRUE_STATE_DIR}/autoscaler/.docker-template.XXXXXXXX")
  sed \
    -e "s#__RUNTRUE_RUNNER_IMAGE__#${RUNTRUE_RUNNER_IMAGE}#g" \
    -e "s#__RUNTRUE_CONTROL_NETWORK__#${RUNTRUE_COMPOSE_PROJECT_NAME}_control#g" \
    -e "s#__RUNTRUE_SCM_NETWORK__#${RUNTRUE_COMPOSE_PROJECT_NAME}_scm-egress#g" \
    -e "s#__RUNTRUE_COMPOSE_PROJECT_NAME__#${RUNTRUE_COMPOSE_PROJECT_NAME}#g" \
    -e "s#__RUNTRUE_RUNTIME_UID__#${RUNTRUE_RUNTIME_UID}#g" \
    -e "s#__RUNTRUE_RUNTIME_GID__#${RUNTRUE_RUNTIME_GID}#g" \
    -e "s#__RUNTRUE_ALLOW_CREDENTIAL_TAINTED_LOGS__#${RUNTRUE_ALLOW_CREDENTIAL_TAINTED_LOGS}#g" \
    -e "s#__RUNTRUE_RUNNER_MEMORY_BYTES__#${RUNTRUE_RUNNER_MEMORY_BYTES}#g" \
    -e "s#__RUNTRUE_RUNNER_NANO_CPUS__#${RUNTRUE_RUNNER_NANO_CPUS}#g" \
    -e "s#__RUNTRUE_AUTOSCALER_CAPACITY_RESERVE_MEMORY_BYTES__#${RUNTRUE_AUTOSCALER_CAPACITY_RESERVE_MEMORY_BYTES}#g" \
    -e "s#__RUNTRUE_AUTOSCALER_CAPACITY_RESERVE_NANO_CPUS__#${RUNTRUE_AUTOSCALER_CAPACITY_RESERVE_NANO_CPUS}#g" \
    -e "s#__RUNTRUE_STATE_DIR__#${RUNTRUE_STATE_DIR}#g" \
    "${SCRIPT_DIR}/autoscaler-docker-template.json" >"$temporary"
  python3 -m json.tool "$temporary" >/dev/null || die 'generated autoscaler template is invalid JSON'
  chmod 0600 -- "$temporary"
  chown "${RUNTRUE_RUNTIME_UID}:${RUNTRUE_RUNTIME_GID}" -- "$temporary"
  if [[ -e "$destination" || -L "$destination" ]]; then
    [[ -f "$destination" && ! -L "$destination" ]] || die "unsafe autoscaler template: ${destination}"
  fi
  mv -fT -- "$temporary" "$destination"
}

control_plane_request() {
  local bearer=$1 method=$2 path=$3 body=${4:-} envelope response
  envelope=$(mktemp -- "${RUNTRUE_INSTALL_ROOT}/.control-request.XXXXXXXX")
  QUICKSTART_BEARER=$bearer QUICKSTART_METHOD=$method QUICKSTART_PATH=$path QUICKSTART_BODY=$body \
    python3 - <<'PY' >"$envelope"
import json, os
print(json.dumps({
    "bearer": os.environ["QUICKSTART_BEARER"],
    "method": os.environ["QUICKSTART_METHOD"],
    "path": os.environ["QUICKSTART_PATH"],
    "body": os.environ["QUICKSTART_BODY"],
}))
PY
  # The single-quoted program is JavaScript; its `${...}` expressions are not shell expansions.
  # shellcheck disable=SC2016
  if ! response=$("${compose[@]}" exec -T frontend node -e '
    let input = "";
    process.stdin.setEncoding("utf8");
    process.stdin.on("data", chunk => input += chunk);
    process.stdin.on("end", () => {
      (async () => {
        const request = JSON.parse(input);
        const headers = {authorization: `Bearer ${request.bearer}`};
        if (request.body) headers["content-type"] = "application/json";
        const response = await fetch(`http://server:8080${request.path}`, {
          method: request.method,
          headers,
          body: request.body || undefined,
        });
        const body = await response.text();
        process.stdout.write(JSON.stringify({status: response.status, body}));
      })().catch(error => { console.error(error); process.exit(1); });
    });
  ' <"$envelope"); then
    rm -f -- "$envelope"
    return 1
  fi
  rm -f -- "$envelope"
  printf '%s' "$response"
}

install_capsule_trust_key() {
  local bearer=$1 response status parsed key_name public_key destination temporary candidate recovery=''
  response=$(control_plane_request \
    "$bearer" GET /api/v1/runner-pools/trust/capsule-key)
  status=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])' <<<"$response")
  [[ "$status" == 200 ]] || die "capsule trust key lookup failed with HTTP ${status}"

  parsed=$(QUICKSTART_CAPSULE_RESPONSE=$response python3 - <<'PY'
import hashlib
import json
import os
import re

outer = json.loads(os.environ["QUICKSTART_CAPSULE_RESPONSE"])
view = json.loads(outer["body"])
key_id = view.get("key_id", "")
public_key = view.get("public_key_hex", "")
if view.get("algorithm") != "ed25519":
    raise SystemExit("capsule trust endpoint returned an unsupported algorithm")
if not re.fullmatch(r"sha256:[0-9a-f]{64}", key_id):
    raise SystemExit("capsule trust endpoint returned a malformed key ID")
if not re.fullmatch(r"[0-9a-f]{64}", public_key):
    raise SystemExit("capsule trust endpoint returned a malformed public key")
if hashlib.sha256(bytes.fromhex(public_key)).hexdigest() != key_id.removeprefix("sha256:"):
    raise SystemExit("capsule trust public key does not match its key ID")
print(f"{key_id.removeprefix('sha256:')}\t{public_key}")
PY
  ) || die 'capsule trust key validation failed'
  IFS=$'\t' read -r key_name public_key <<<"$parsed"

  destination="${RUNTRUE_STATE_DIR}/runner-trust/capsule-keys/${key_name}.hex"
  temporary=$(mktemp -- "${RUNTRUE_STATE_DIR}/runner-trust/capsule-keys/.capsule-key.XXXXXXXX")
  printf '%s\n' "$public_key" >"$temporary"
  install_private_file \
    "$temporary" \
    "$destination" \
    "$RUNTRUE_RUNTIME_UID" \
    "$RUNTRUE_RUNTIME_GID"
  rm -f -- "$temporary"

  # Older deployments used a descriptive filename for this same key. The
  # runner rejects duplicate key identities even when their bytes match, so
  # retain obsolete aliases outside the active keyring during migration.
  while IFS= read -r -d '' candidate; do
    [[ "$candidate" == "$destination" ]] && continue
    [[ -f "$candidate" && ! -L "$candidate" ]] || die "unsafe capsule trust key: ${candidate}"
    cmp -s -- "$candidate" "$destination" || continue
    if [[ -z "$recovery" ]]; then
      install -d -m 0700 -- "${RUNTRUE_INSTALL_ROOT}/recovery"
      recovery="${RUNTRUE_INSTALL_ROOT}/recovery/capsule-key-aliases.$(openssl rand -hex 8)"
      install -d -m 0700 -- "$recovery"
    fi
    mv -- "$candidate" "$recovery/"
    printf 'quick-start: duplicate capsule trust key alias retained for recovery at %s\n' "$recovery" >&2
  done < <(find "${RUNTRUE_STATE_DIR}/runner-trust/capsule-keys" -mindepth 1 -maxdepth 1 -type f -name '*.hex' -print0)
}

write_runtime_environment() {
  local destination=$1 temporary api_origin key value
  local existing_project='' existing_installation_id='' existing_state_dir='' existing_claim_root='' existing_public_origin=''
  local existing_github_origin='' existing_app_id='' existing_app_slug='' existing_oauth_client_id=''
  local existing_credential_reference=''
  if [[ "$RUNTRUE_GITHUB_WEB_ORIGIN" == https://github.com ]]; then
    api_origin=https://api.github.com
  else
    api_origin="${RUNTRUE_GITHUB_WEB_ORIGIN}/api/v3"
  fi

  temporary=$(mktemp -- "${RUNTRUE_INSTALL_ROOT}/.env.XXXXXXXX")
  {
    printf 'RUNTRUE_RUNTIME_UID=%s\n' "$RUNTRUE_RUNTIME_UID"
    printf 'RUNTRUE_RUNTIME_GID=%s\n' "$RUNTRUE_RUNTIME_GID"
    printf 'RUNTRUE_DOCKER_GID=%s\n' "$RUNTRUE_DOCKER_GID"
    printf 'RUNTRUE_DOCKER_BINARY=%s\n' "$RUNTRUE_DOCKER_BINARY"
    printf 'RUNTRUE_DOCKER_BUILDX_PLUGIN=%s\n' "$RUNTRUE_DOCKER_BUILDX_PLUGIN"
    printf 'RUNTRUE_COMPOSE_PROJECT_NAME=%s\n' "$RUNTRUE_COMPOSE_PROJECT_NAME"
    printf 'RUNTRUE_INSTALLATION_ID=%s\n' "$RUNTRUE_INSTALLATION_ID"
    printf 'COMPOSE_PROFILES=%s\n' "$RUNTRUE_COMPOSE_PROFILES"
    printf 'RUNTRUE_STATE_DIR=%s\n' "$RUNTRUE_STATE_DIR"
    printf 'RUNTRUE_PUBLIC_ORIGIN=%s\n' "$RUNTRUE_PUBLIC_ORIGIN"
    printf 'RUNTRUE_ACME_EMAIL=%s\n' "$RUNTRUE_ACME_EMAIL"
    printf 'RUNTRUE_EDGE_HTTP_PORT=%s\n' "$RUNTRUE_EDGE_HTTP_PORT"
    printf 'RUNTRUE_EDGE_HTTPS_PORT=%s\n' "$RUNTRUE_EDGE_HTTPS_PORT"
    printf 'RUNTRUE_EDGE_NETWORK_NAME=%s\n' "$RUNTRUE_EDGE_NETWORK_NAME"
    printf 'RUNTRUE_EDGE_NETWORK_EXTERNAL=%s\n' "$RUNTRUE_EDGE_NETWORK_EXTERNAL"
    printf 'RUNTRUE_EDGE_UPSTREAM_NAME=%s\n' "$RUNTRUE_EDGE_UPSTREAM_NAME"
    printf 'RUNTRUE_TRAEFIK_DOCKER_ENABLED=%s\n' "$RUNTRUE_TRAEFIK_DOCKER_ENABLED"
    printf 'RUNTRUE_PUBLIC_HOST=%s\n' "$RUNTRUE_PUBLIC_HOST"
    printf 'RUNTRUE_TRAEFIK_ROUTER_NAME=%s\n' "$RUNTRUE_TRAEFIK_ROUTER_NAME"
    printf 'RUNTRUE_TRAEFIK_HTTP_ENTRYPOINT=%s\n' "$RUNTRUE_TRAEFIK_HTTP_ENTRYPOINT"
    printf 'RUNTRUE_TRAEFIK_HTTPS_ENTRYPOINT=%s\n' "$RUNTRUE_TRAEFIK_HTTPS_ENTRYPOINT"
    printf 'RUNTRUE_TRAEFIK_CERT_RESOLVER=%s\n' "$RUNTRUE_TRAEFIK_CERT_RESOLVER"
    printf 'RUNTRUE_GITHUB_WEB_ORIGIN=%s\n' "$RUNTRUE_GITHUB_WEB_ORIGIN"
    printf 'RUNTRUE_GITHUB_API_ORIGIN=%s\n' "$api_origin"
    printf 'RUNTRUE_GITHUB_APP_ID=%s\n' "$RUNTRUE_GITHUB_APP_ID"
    printf 'RUNTRUE_GITHUB_APP_SLUG=%s\n' "$RUNTRUE_GITHUB_APP_SLUG"
    printf 'RUNTRUE_GITHUB_OAUTH_CLIENT_ID=%s\n' "$RUNTRUE_GITHUB_OAUTH_CLIENT_ID"
    printf 'RUNTRUE_GITHUB_OAUTH_ADMIN_USER_IDS=%s\n' "$RUNTRUE_GITHUB_OAUTH_ADMIN_USER_IDS"
    printf 'RUNTRUE_SCM_WORKERS=%s\n' "$RUNTRUE_SCM_WORKERS"
    printf 'RUNTRUE_AUTOSCALER_IMAGE=%s\n' "$RUNTRUE_AUTOSCALER_IMAGE"
    printf 'RUNTRUE_AUTOSCALER_POOL_ID=%s\n' "$RUNTRUE_AUTOSCALER_POOL_ID"
    printf 'RUNTRUE_AUTOSCALER_SCALE_UP_BATCH=%s\n' "$RUNTRUE_AUTOSCALER_SCALE_UP_BATCH"
    printf 'RUNTRUE_AUTOSCALER_CLAIM_ROOT=%s\n' "$RUNTRUE_AUTOSCALER_CLAIM_ROOT"
    printf 'RUNTRUE_RUNNER_IMAGE=%s\n' "$RUNTRUE_RUNNER_IMAGE"
    printf 'RUNTRUE_RUNNER_MEMORY_BYTES=%s\n' "$RUNTRUE_RUNNER_MEMORY_BYTES"
    printf 'RUNTRUE_RUNNER_NANO_CPUS=%s\n' "$RUNTRUE_RUNNER_NANO_CPUS"
    printf 'RUNTRUE_AUTOSCALER_CAPACITY_RESERVE_MEMORY_BYTES=%s\n' "$RUNTRUE_AUTOSCALER_CAPACITY_RESERVE_MEMORY_BYTES"
    printf 'RUNTRUE_AUTOSCALER_CAPACITY_RESERVE_NANO_CPUS=%s\n' "$RUNTRUE_AUTOSCALER_CAPACITY_RESERVE_NANO_CPUS"
    printf 'RUNTRUE_ALLOW_CREDENTIAL_TAINTED_LOGS=%s\n' "$RUNTRUE_ALLOW_CREDENTIAL_TAINTED_LOGS"
    printf 'RUNTRUE_ACTION_ADMISSION_CONTAINER=%s\n' "$RUNTRUE_ACTION_ADMISSION_CONTAINER"
    printf 'RUNTRUE_REPOSITORY_ACTION_IMAGE_REPOSITORY=%s\n' "$RUNTRUE_REPOSITORY_ACTION_IMAGE_REPOSITORY"
    printf 'RUNTRUE_REPOSITORY_ACTION_BUILDX_BUILDER=%s\n' "$RUNTRUE_REPOSITORY_ACTION_BUILDX_BUILDER"
    printf 'RUNTRUE_REPOSITORY_ACTION_ALLOWED_BASE_IMAGES=%s\n' "$RUNTRUE_REPOSITORY_ACTION_ALLOWED_BASE_IMAGES"
    printf 'RUNTRUE_GITHUB_APP_CREDENTIAL_REFERENCE=%s\n' "$RUNTRUE_GITHUB_APP_CREDENTIAL_REFERENCE"
  } >"$temporary"
  chmod 0600 -- "$temporary"
  chown "${RUNTRUE_RUNTIME_UID}:${RUNTRUE_RUNTIME_GID}" -- "$temporary"

  if [[ -e "$destination" || -L "$destination" ]]; then
    [[ -f "$destination" && ! -L "$destination" ]] || die "unsafe existing environment file: ${destination}"
    while IFS='=' read -r key value; do
      case "$key" in
        RUNTRUE_COMPOSE_PROJECT_NAME) existing_project=$value ;;
        RUNTRUE_INSTALLATION_ID) existing_installation_id=$value ;;
        RUNTRUE_STATE_DIR) existing_state_dir=$value ;;
        RUNTRUE_AUTOSCALER_CLAIM_ROOT) existing_claim_root=$value ;;
        RUNTRUE_PUBLIC_ORIGIN) existing_public_origin=$value ;;
        RUNTRUE_GITHUB_WEB_ORIGIN) existing_github_origin=$value ;;
        RUNTRUE_GITHUB_APP_ID) existing_app_id=$value ;;
        RUNTRUE_GITHUB_APP_SLUG) existing_app_slug=$value ;;
        RUNTRUE_GITHUB_OAUTH_CLIENT_ID) existing_oauth_client_id=$value ;;
        RUNTRUE_GITHUB_APP_CREDENTIAL_REFERENCE) existing_credential_reference=$value ;;
      esac
    done <"$destination"
    if [[ "$existing_project" != "$RUNTRUE_COMPOSE_PROJECT_NAME" ||
          ( -n "$existing_installation_id" && "$existing_installation_id" != "$RUNTRUE_INSTALLATION_ID" ) ||
          "$existing_state_dir" != "$RUNTRUE_STATE_DIR" ||
          ( -n "$existing_claim_root" && "$existing_claim_root" != "$RUNTRUE_AUTOSCALER_CLAIM_ROOT" ) ||
          "$existing_public_origin" != "$RUNTRUE_PUBLIC_ORIGIN" ||
          "$existing_github_origin" != "$RUNTRUE_GITHUB_WEB_ORIGIN" ||
          "$existing_app_id" != "$RUNTRUE_GITHUB_APP_ID" ||
          "$existing_app_slug" != "$RUNTRUE_GITHUB_APP_SLUG" ||
          "$existing_oauth_client_id" != "$RUNTRUE_GITHUB_OAUTH_CLIENT_ID" ||
          ( -n "$existing_credential_reference" &&
            "$existing_credential_reference" != "$RUNTRUE_GITHUB_APP_CREDENTIAL_REFERENCE" ) ]]; then
      rm -f -- "$temporary"
      die 'installation identity cannot change on a rerun; use a new install root or an explicit migration'
    fi
  fi
  mv -- "$temporary" "$destination"
}

((EUID == 0)) || die 'run this script as root'
[[ -f "$CONFIG_FILE" && ! -L "$CONFIG_FILE" ]] ||
  die "copy quick-start.env.example to ${CONFIG_FILE} and fill it in"

# This is an operator-owned configuration file, not untrusted input.
# shellcheck disable=SC1090
source "$CONFIG_FILE"

for obsolete in \
  RUNTRUE_RUNNER_RUNTIME_BUNDLE_SOURCE \
  RUNTRUE_WASM_RUNTIME_COMPATIBILITY_DIGEST \
  RUNTRUE_OCI_RUNTIME_COMPATIBILITY_DIGEST
do
  if [[ -n "${!obsolete:-}" ]]; then
    printf 'quick-start: ignoring obsolete setting %s; runtime assets are loaded from the latest bundle image\n' \
      "$obsolete" >&2
    unset "$obsolete"
  fi
done

RUNTRUE_TRAEFIK_MODE=${RUNTRUE_TRAEFIK_MODE:-bundled}

for name in \
  RUNTRUE_PUBLIC_ORIGIN \
  RUNTRUE_GITHUB_WEB_ORIGIN \
  RUNTRUE_GITHUB_APP_ID \
  RUNTRUE_GITHUB_APP_SLUG \
  RUNTRUE_GITHUB_OAUTH_CLIENT_ID \
  RUNTRUE_GITHUB_OAUTH_ADMIN_USER_IDS \
  RUNTRUE_GITHUB_APP_PRIVATE_KEY_SOURCE \
  RUNTRUE_GITHUB_OAUTH_CLIENT_SECRET_SOURCE
do
  require_value "$name"
done

case "$RUNTRUE_TRAEFIK_MODE" in
  bundled)
    require_value RUNTRUE_ACME_EMAIL
    ;;
  existing)
    require_value RUNTRUE_TRAEFIK_NETWORK
    ;;
  *)
    die 'RUNTRUE_TRAEFIK_MODE must be bundled or existing'
    ;;
esac

RUNTRUE_INSTALL_ROOT=${RUNTRUE_INSTALL_ROOT:-/opt/runtrue}
RUNTRUE_RUNTIME_UID=${RUNTRUE_RUNTIME_UID:-10001}
RUNTRUE_RUNTIME_GID=${RUNTRUE_RUNTIME_GID:-10001}
RUNTRUE_DOCKER_GID=${RUNTRUE_DOCKER_GID:-$(stat -c '%g' -- /var/run/docker.sock 2>/dev/null || true)}
RUNTRUE_DOCKER_BINARY=${RUNTRUE_DOCKER_BINARY:-$(command -v docker 2>/dev/null || true)}
RUNTRUE_DOCKER_BUILDX_PLUGIN=${RUNTRUE_DOCKER_BUILDX_PLUGIN:-$(docker info --format '{{range .ClientInfo.Plugins}}{{if eq .Name "buildx"}}{{.Path}}{{end}}{{end}}' 2>/dev/null || true)}
RUNTRUE_AUTOSCALER_IMAGE=${RUNTRUE_AUTOSCALER_IMAGE:-ghcr.io/runtrue/runtrue-autoscaler:latest}
RUNTRUE_RUNNER_IMAGE=${RUNTRUE_RUNNER_IMAGE:-ghcr.io/runtrue/runtrue-runner:latest}
RUNTRUE_RUNNER_RUNTIME_BUNDLE_IMAGE=${RUNTRUE_RUNNER_RUNTIME_BUNDLE_IMAGE:-ghcr.io/runtrue/runtrue-runner:quickstart-runtime-bundle-latest}
RUNTRUE_ALLOW_CREDENTIAL_TAINTED_LOGS=${RUNTRUE_ALLOW_CREDENTIAL_TAINTED_LOGS:-true}
RUNTRUE_SCM_WORKERS=${RUNTRUE_SCM_WORKERS:-4}
RUNTRUE_AUTOSCALER_POOL_ID=${RUNTRUE_AUTOSCALER_POOL_ID:-pool-quickstart}
RUNTRUE_AUTOSCALER_TENANT_ID=${RUNTRUE_AUTOSCALER_TENANT_ID:-quickstart}
RUNTRUE_AUTOSCALER_MINIMUM_WORKERS=${RUNTRUE_AUTOSCALER_MINIMUM_WORKERS:-0}
RUNTRUE_AUTOSCALER_MINIMUM_IDLE_WORKERS=${RUNTRUE_AUTOSCALER_MINIMUM_IDLE_WORKERS:-0}
RUNTRUE_AUTOSCALER_MAXIMUM_WORKERS=${RUNTRUE_AUTOSCALER_MAXIMUM_WORKERS:-2}
RUNTRUE_AUTOSCALER_SCALE_UP_BATCH=${RUNTRUE_AUTOSCALER_SCALE_UP_BATCH:-$RUNTRUE_AUTOSCALER_MAXIMUM_WORKERS}
RUNTRUE_AUTOSCALER_IDLE_TIMEOUT_MS=${RUNTRUE_AUTOSCALER_IDLE_TIMEOUT_MS:-30000}
RUNTRUE_RUNNER_MEMORY_BYTES=${RUNTRUE_RUNNER_MEMORY_BYTES:-6442450944}
RUNTRUE_RUNNER_NANO_CPUS=${RUNTRUE_RUNNER_NANO_CPUS:-2000000000}
RUNTRUE_AUTOSCALER_CAPACITY_RESERVE_MEMORY_BYTES=${RUNTRUE_AUTOSCALER_CAPACITY_RESERVE_MEMORY_BYTES:-4294967296}
RUNTRUE_AUTOSCALER_CAPACITY_RESERVE_NANO_CPUS=${RUNTRUE_AUTOSCALER_CAPACITY_RESERVE_NANO_CPUS:-2000000000}
RUNTRUE_EDGE_HTTP_PORT=${RUNTRUE_EDGE_HTTP_PORT:-80}
RUNTRUE_EDGE_HTTPS_PORT=${RUNTRUE_EDGE_HTTPS_PORT:-443}
RUNTRUE_COMPOSE_PROJECT_NAME=${RUNTRUE_COMPOSE_PROJECT_NAME:-$(basename -- "$RUNTRUE_INSTALL_ROOT")}
RUNTRUE_INSTALLATION_ID=${RUNTRUE_INSTALLATION_ID:-single-node}
RUNTRUE_GITHUB_APP_CREDENTIAL_REFERENCE=${RUNTRUE_GITHUB_APP_CREDENTIAL_REFERENCE:-provider://github-app/production}
RUNTRUE_ACTION_ADMISSION_CONTAINER=${RUNTRUE_ACTION_ADMISSION_CONTAINER:-${RUNTRUE_COMPOSE_PROJECT_NAME}-action-admission}
RUNTRUE_REPOSITORY_ACTION_IMAGE_REPOSITORY=${RUNTRUE_REPOSITORY_ACTION_IMAGE_REPOSITORY:-runtrue.local/repository-actions}
RUNTRUE_REPOSITORY_ACTION_BUILDX_BUILDER=${RUNTRUE_REPOSITORY_ACTION_BUILDX_BUILDER:-${RUNTRUE_COMPOSE_PROJECT_NAME}-repository-actions}
RUNTRUE_REPOSITORY_ACTION_ALLOWED_BASE_IMAGES=${RUNTRUE_REPOSITORY_ACTION_ALLOWED_BASE_IMAGES:-node:22-bookworm-slim@sha256:53ada149d435c38b14476cb57e4a7da73c15595aba79bd6971b547ceb6d018bf}
RUNTRUE_DOCKERHUB_USERNAME=${RUNTRUE_DOCKERHUB_USERNAME:-}
RUNTRUE_DOCKERHUB_TOKEN_SOURCE=${RUNTRUE_DOCKERHUB_TOKEN_SOURCE:-}
RUNTRUE_REPOSITORY_ACTION_KEY_CREATED=false
RUNTRUE_AUTOSCALER_CLAIM_ROOT=${RUNTRUE_AUTOSCALER_CLAIM_ROOT:-/var/lib/runtrue-autoscaler/${RUNTRUE_COMPOSE_PROJECT_NAME}/claims}
RUNTRUE_EDGE_UPSTREAM_NAME=${RUNTRUE_EDGE_UPSTREAM_NAME:-${RUNTRUE_COMPOSE_PROJECT_NAME//_/-}-frontend}
RUNTRUE_PUBLIC_HOST=${RUNTRUE_PUBLIC_ORIGIN#https://}
RUNTRUE_TRAEFIK_ROUTER_NAME=${RUNTRUE_TRAEFIK_ROUTER_NAME:-${RUNTRUE_COMPOSE_PROJECT_NAME//_/-}}
RUNTRUE_TRAEFIK_HTTP_ENTRYPOINT=${RUNTRUE_TRAEFIK_HTTP_ENTRYPOINT:-web}
RUNTRUE_TRAEFIK_HTTPS_ENTRYPOINT=${RUNTRUE_TRAEFIK_HTTPS_ENTRYPOINT:-websecure}
RUNTRUE_TRAEFIK_CERT_RESOLVER=${RUNTRUE_TRAEFIK_CERT_RESOLVER:-letsencrypt}
if [[ "$RUNTRUE_TRAEFIK_MODE" == bundled ]]; then
  RUNTRUE_COMPOSE_PROFILES=bundled-traefik
  RUNTRUE_EDGE_NETWORK_NAME=${RUNTRUE_EDGE_NETWORK_NAME:-${RUNTRUE_COMPOSE_PROJECT_NAME}_edge}
  RUNTRUE_EDGE_NETWORK_EXTERNAL=false
  RUNTRUE_TRAEFIK_DOCKER_ENABLED=false
else
  RUNTRUE_COMPOSE_PROFILES=
  RUNTRUE_EDGE_NETWORK_NAME=$RUNTRUE_TRAEFIK_NETWORK
  RUNTRUE_EDGE_NETWORK_EXTERNAL=true
  RUNTRUE_TRAEFIK_DOCKER_ENABLED=true
  RUNTRUE_ACME_EMAIL=${RUNTRUE_ACME_EMAIL:-}
fi
readonly RUNTRUE_INSTALL_ROOT RUNTRUE_RUNTIME_UID RUNTRUE_RUNTIME_GID
readonly RUNTRUE_DOCKER_GID RUNTRUE_DOCKER_BINARY RUNTRUE_DOCKER_BUILDX_PLUGIN
readonly RUNTRUE_AUTOSCALER_IMAGE RUNTRUE_AUTOSCALER_POOL_ID
readonly RUNTRUE_AUTOSCALER_CLAIM_ROOT
readonly RUNTRUE_AUTOSCALER_TENANT_ID
readonly RUNTRUE_AUTOSCALER_MINIMUM_WORKERS RUNTRUE_AUTOSCALER_MINIMUM_IDLE_WORKERS
readonly RUNTRUE_AUTOSCALER_MAXIMUM_WORKERS
readonly RUNTRUE_AUTOSCALER_SCALE_UP_BATCH
readonly RUNTRUE_AUTOSCALER_IDLE_TIMEOUT_MS
readonly RUNTRUE_RUNNER_MEMORY_BYTES RUNTRUE_RUNNER_NANO_CPUS
readonly RUNTRUE_AUTOSCALER_CAPACITY_RESERVE_MEMORY_BYTES
readonly RUNTRUE_AUTOSCALER_CAPACITY_RESERVE_NANO_CPUS
readonly RUNTRUE_RUNNER_RUNTIME_BUNDLE_IMAGE
readonly RUNTRUE_ALLOW_CREDENTIAL_TAINTED_LOGS
readonly RUNTRUE_SCM_WORKERS
readonly RUNTRUE_EDGE_HTTP_PORT RUNTRUE_EDGE_HTTPS_PORT
readonly RUNTRUE_COMPOSE_PROJECT_NAME
readonly RUNTRUE_INSTALLATION_ID
readonly RUNTRUE_GITHUB_APP_CREDENTIAL_REFERENCE
readonly RUNTRUE_ACTION_ADMISSION_CONTAINER
readonly RUNTRUE_REPOSITORY_ACTION_IMAGE_REPOSITORY RUNTRUE_REPOSITORY_ACTION_BUILDX_BUILDER
readonly RUNTRUE_REPOSITORY_ACTION_ALLOWED_BASE_IMAGES
readonly RUNTRUE_DOCKERHUB_USERNAME RUNTRUE_DOCKERHUB_TOKEN_SOURCE
readonly RUNTRUE_TRAEFIK_MODE RUNTRUE_COMPOSE_PROFILES
readonly RUNTRUE_EDGE_NETWORK_NAME RUNTRUE_EDGE_NETWORK_EXTERNAL RUNTRUE_EDGE_UPSTREAM_NAME
readonly RUNTRUE_TRAEFIK_DOCKER_ENABLED RUNTRUE_PUBLIC_HOST RUNTRUE_TRAEFIK_ROUTER_NAME
readonly RUNTRUE_TRAEFIK_HTTP_ENTRYPOINT RUNTRUE_TRAEFIK_HTTPS_ENTRYPOINT RUNTRUE_TRAEFIK_CERT_RESOLVER
readonly RUNTRUE_STATE_DIR="${RUNTRUE_INSTALL_ROOT}/state"
readonly COMPOSE_FILE="${RUNTRUE_INSTALL_ROOT}/compose.yml"
readonly RUNTIME_ENV="${RUNTRUE_INSTALL_ROOT}/.env"

[[ "$RUNTRUE_INSTALL_ROOT" =~ ^/[A-Za-z0-9_./-]+$ && "$RUNTRUE_INSTALL_ROOT" != / ]] ||
  die 'RUNTRUE_INSTALL_ROOT must be a safe absolute path other than /'
[[ "$RUNTRUE_PUBLIC_ORIGIN" =~ ^https://[A-Za-z0-9.-]+$ ]] ||
  die 'RUNTRUE_PUBLIC_ORIGIN must be an HTTPS origin with a DNS hostname and no path'
if [[ "$RUNTRUE_TRAEFIK_MODE" == bundled ]]; then
  [[ "$RUNTRUE_ACME_EMAIL" == *@* && "$RUNTRUE_ACME_EMAIL" != *[$' \t\r\n']* ]] ||
    die 'RUNTRUE_ACME_EMAIL is invalid'
fi
[[ "$RUNTRUE_GITHUB_WEB_ORIGIN" =~ ^https://[A-Za-z0-9.-]+$ ]] ||
  die 'RUNTRUE_GITHUB_WEB_ORIGIN must be an HTTPS origin with no path or trailing slash'
[[ "$RUNTRUE_GITHUB_APP_ID" =~ ^[1-9][0-9]*$ ]] || die 'RUNTRUE_GITHUB_APP_ID must be numeric'
[[ "$RUNTRUE_GITHUB_APP_SLUG" =~ ^[A-Za-z0-9-]+$ ]] || die 'RUNTRUE_GITHUB_APP_SLUG is invalid'
[[ "$RUNTRUE_GITHUB_OAUTH_CLIENT_ID" =~ ^[A-Za-z0-9._-]+$ ]] || die 'RUNTRUE_GITHUB_OAUTH_CLIENT_ID is invalid'
[[ "$RUNTRUE_GITHUB_OAUTH_ADMIN_USER_IDS" =~ ^[1-9][0-9]*(,[1-9][0-9]*)*$ ]] ||
  die 'RUNTRUE_GITHUB_OAUTH_ADMIN_USER_IDS must be a comma-separated numeric list'
[[ "$RUNTRUE_GITHUB_APP_CREDENTIAL_REFERENCE" =~ ^provider://github-app/[A-Za-z0-9_.-]+$ ]] ||
  die 'RUNTRUE_GITHUB_APP_CREDENTIAL_REFERENCE is invalid'
[[ "$RUNTRUE_RUNTIME_UID" =~ ^[1-9][0-9]*$ && "$RUNTRUE_RUNTIME_GID" =~ ^[1-9][0-9]*$ ]] ||
  die 'runtime uid and gid must be positive numbers'
[[ "$RUNTRUE_DOCKER_GID" =~ ^[0-9]+$ ]] || die 'RUNTRUE_DOCKER_GID must be numeric'
[[ "$RUNTRUE_DOCKER_BINARY" == /* && -x "$RUNTRUE_DOCKER_BINARY" && ! -L "$RUNTRUE_DOCKER_BINARY" ]] ||
  die 'RUNTRUE_DOCKER_BINARY must be an executable absolute regular path'
[[ "$RUNTRUE_DOCKER_BUILDX_PLUGIN" == /* && -x "$RUNTRUE_DOCKER_BUILDX_PLUGIN" && ! -L "$RUNTRUE_DOCKER_BUILDX_PLUGIN" ]] ||
  die 'RUNTRUE_DOCKER_BUILDX_PLUGIN must be an executable absolute regular path'
[[ "$RUNTRUE_RUNNER_IMAGE" =~ ^[^[:space:]]+$ ]] || die 'runner image reference is invalid'
[[ "$RUNTRUE_RUNNER_RUNTIME_BUNDLE_IMAGE" =~ ^[^[:space:]]+$ ]] || die 'runtime bundle image reference is invalid'
[[ "$RUNTRUE_ALLOW_CREDENTIAL_TAINTED_LOGS" == true || "$RUNTRUE_ALLOW_CREDENTIAL_TAINTED_LOGS" == false ]] ||
  die 'RUNTRUE_ALLOW_CREDENTIAL_TAINTED_LOGS must be true or false'
[[ "$RUNTRUE_SCM_WORKERS" =~ ^[1-9][0-9]*$ ]] && ((10#$RUNTRUE_SCM_WORKERS <= 32)) ||
  die 'RUNTRUE_SCM_WORKERS must be an integer between 1 and 32'
[[ "$RUNTRUE_AUTOSCALER_IMAGE" =~ ^[^[:space:]]+$ ]] || die 'autoscaler image reference is invalid'
[[ "$RUNTRUE_AUTOSCALER_POOL_ID" =~ ^[A-Za-z0-9_.-]+$ ]] || die 'autoscaler pool ID is invalid'
[[ "$RUNTRUE_AUTOSCALER_CLAIM_ROOT" =~ ^/[A-Za-z0-9_./-]+$ &&
   "$RUNTRUE_AUTOSCALER_CLAIM_ROOT" != / &&
   "$RUNTRUE_AUTOSCALER_CLAIM_ROOT" != /root &&
   "$RUNTRUE_AUTOSCALER_CLAIM_ROOT" != /root/* ]] ||
  die 'autoscaler claim root must be a safe absolute path outside /root'
[[ "$RUNTRUE_AUTOSCALER_TENANT_ID" =~ ^[A-Za-z0-9_.-]+$ ]] || die 'autoscaler tenant ID is invalid'
[[ "$RUNTRUE_AUTOSCALER_MINIMUM_WORKERS" =~ ^[0-9]+$ ]] ||
  die 'RUNTRUE_AUTOSCALER_MINIMUM_WORKERS must be zero or a positive integer'
[[ "$RUNTRUE_AUTOSCALER_MINIMUM_IDLE_WORKERS" =~ ^[0-9]+$ ]] ||
  die 'RUNTRUE_AUTOSCALER_MINIMUM_IDLE_WORKERS must be zero or a positive integer'
[[ "$RUNTRUE_AUTOSCALER_MAXIMUM_WORKERS" =~ ^[1-9][0-9]*$ ]] ||
  die 'RUNTRUE_AUTOSCALER_MAXIMUM_WORKERS must be positive'
[[ "$RUNTRUE_AUTOSCALER_SCALE_UP_BATCH" =~ ^[1-9][0-9]*$ ]] ||
  die 'RUNTRUE_AUTOSCALER_SCALE_UP_BATCH must be positive'
((10#$RUNTRUE_AUTOSCALER_MINIMUM_WORKERS <= 10#$RUNTRUE_AUTOSCALER_MAXIMUM_WORKERS)) ||
  die 'RUNTRUE_AUTOSCALER_MINIMUM_WORKERS must not exceed RUNTRUE_AUTOSCALER_MAXIMUM_WORKERS'
((10#$RUNTRUE_AUTOSCALER_MINIMUM_IDLE_WORKERS <= 10#$RUNTRUE_AUTOSCALER_MAXIMUM_WORKERS)) ||
  die 'RUNTRUE_AUTOSCALER_MINIMUM_IDLE_WORKERS must not exceed RUNTRUE_AUTOSCALER_MAXIMUM_WORKERS'
((10#$RUNTRUE_AUTOSCALER_SCALE_UP_BATCH <= 10#$RUNTRUE_AUTOSCALER_MAXIMUM_WORKERS)) ||
  die 'RUNTRUE_AUTOSCALER_SCALE_UP_BATCH must not exceed RUNTRUE_AUTOSCALER_MAXIMUM_WORKERS'
[[ "$RUNTRUE_AUTOSCALER_IDLE_TIMEOUT_MS" =~ ^[1-9][0-9]*$ ]] ||
  die 'RUNTRUE_AUTOSCALER_IDLE_TIMEOUT_MS must be positive'
[[ "$RUNTRUE_RUNNER_MEMORY_BYTES" =~ ^[1-9][0-9]*$ ]] ||
  die 'RUNTRUE_RUNNER_MEMORY_BYTES must be positive'
[[ "$RUNTRUE_RUNNER_NANO_CPUS" =~ ^[1-9][0-9]*$ ]] ||
  die 'RUNTRUE_RUNNER_NANO_CPUS must be positive'
[[ "$RUNTRUE_AUTOSCALER_CAPACITY_RESERVE_MEMORY_BYTES" =~ ^[0-9]+$ ]] ||
  die 'RUNTRUE_AUTOSCALER_CAPACITY_RESERVE_MEMORY_BYTES must be zero or positive'
[[ "$RUNTRUE_AUTOSCALER_CAPACITY_RESERVE_NANO_CPUS" =~ ^[0-9]+$ ]] ||
  die 'RUNTRUE_AUTOSCALER_CAPACITY_RESERVE_NANO_CPUS must be zero or positive'
[[ "$RUNTRUE_COMPOSE_PROJECT_NAME" =~ ^[a-z0-9][a-z0-9_-]*$ ]] ||
  die 'RUNTRUE_COMPOSE_PROJECT_NAME must contain only lowercase letters, digits, hyphens, and underscores'
[[ "$RUNTRUE_INSTALLATION_ID" =~ ^[A-Za-z0-9_.-]+$ ]] ||
  die 'RUNTRUE_INSTALLATION_ID is invalid'
[[ "$RUNTRUE_ACTION_ADMISSION_CONTAINER" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]+$ ]] ||
  die 'RUNTRUE_ACTION_ADMISSION_CONTAINER is invalid'
[[ "$RUNTRUE_REPOSITORY_ACTION_IMAGE_REPOSITORY" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]+$ ]] ||
  die 'RUNTRUE_REPOSITORY_ACTION_IMAGE_REPOSITORY is invalid'
[[ "$RUNTRUE_REPOSITORY_ACTION_BUILDX_BUILDER" =~ ^[a-z0-9][a-z0-9_.-]+$ ]] ||
  die 'RUNTRUE_REPOSITORY_ACTION_BUILDX_BUILDER is invalid'
[[ "$RUNTRUE_REPOSITORY_ACTION_ALLOWED_BASE_IMAGES" == *@sha256:* &&
   "$RUNTRUE_REPOSITORY_ACTION_ALLOWED_BASE_IMAGES" != *[$' \t\r\n']* ]] ||
  die 'RUNTRUE_REPOSITORY_ACTION_ALLOWED_BASE_IMAGES must contain immutable comma-separated image references'
if [[ -n "$RUNTRUE_DOCKERHUB_USERNAME" || -n "$RUNTRUE_DOCKERHUB_TOKEN_SOURCE" ]]; then
  [[ "$RUNTRUE_DOCKERHUB_USERNAME" =~ ^[A-Za-z0-9_.-]+$ ]] ||
    die 'RUNTRUE_DOCKERHUB_USERNAME is invalid'
  [[ "$RUNTRUE_DOCKERHUB_TOKEN_SOURCE" == /* ]] ||
    die 'RUNTRUE_DOCKERHUB_TOKEN_SOURCE must be an absolute path'
  require_private_file "$RUNTRUE_DOCKERHUB_TOKEN_SOURCE" 'Docker Hub access token'
fi
[[ "$RUNTRUE_EDGE_NETWORK_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] ||
  die 'the edge network name is invalid'
[[ ${#RUNTRUE_EDGE_UPSTREAM_NAME} -le 63 && "$RUNTRUE_EDGE_UPSTREAM_NAME" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] ||
  die 'RUNTRUE_EDGE_UPSTREAM_NAME must be a lowercase DNS label'
[[ "$RUNTRUE_TRAEFIK_ROUTER_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] ||
  die 'RUNTRUE_TRAEFIK_ROUTER_NAME is invalid'
for traefik_name in "$RUNTRUE_TRAEFIK_HTTP_ENTRYPOINT" "$RUNTRUE_TRAEFIK_HTTPS_ENTRYPOINT" "$RUNTRUE_TRAEFIK_CERT_RESOLVER"; do
  [[ "$traefik_name" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || die 'a Traefik entrypoint or resolver name is invalid'
done
[[ "$RUNTRUE_EDGE_HTTP_PORT" =~ ^[1-9][0-9]*$ && "$RUNTRUE_EDGE_HTTPS_PORT" =~ ^[1-9][0-9]*$ ]] ||
  die 'edge ports must be positive numbers'
((RUNTRUE_EDGE_HTTP_PORT <= 65535 && RUNTRUE_EDGE_HTTPS_PORT <= 65535)) ||
  die 'edge ports must not exceed 65535'

for command in awk basename cmp cp diff docker env find grep install mktemp mv openssl python3 realpath sed sha256sum stat tail tr; do
  command -v "$command" >/dev/null 2>&1 || die "required command not found: ${command}"
done
docker compose version >/dev/null 2>&1 || die 'Docker Compose v2 is required'
docker buildx version >/dev/null 2>&1 || die 'Docker Buildx is required for repository actions'
[[ "$(docker version --format '{{.Server.Os}}/{{.Server.Arch}}' 2>/dev/null)" == linux/amd64 ]] ||
  die 'a reachable linux/amd64 Docker Engine is required by the product images'
[[ -S /var/run/docker.sock ]] || die 'the Docker Engine socket is required for autoscaling'
[[ -c /dev/fuse ]] || die '/dev/fuse is required for OCI runner containers'
RUNTRUE_DOCKER_MEMORY_BYTES=$(docker info --format '{{.MemTotal}}')
RUNTRUE_DOCKER_CPUS=$(docker info --format '{{.NCPU}}')
[[ "$RUNTRUE_DOCKER_MEMORY_BYTES" =~ ^[1-9][0-9]*$ && "$RUNTRUE_DOCKER_CPUS" =~ ^[1-9][0-9]*$ ]] ||
  die 'Docker Engine returned invalid host capacity'
RUNTRUE_EFFECTIVE_RUNNER_CAPACITY=$(python3 - \
  "$RUNTRUE_DOCKER_MEMORY_BYTES" \
  "$RUNTRUE_DOCKER_CPUS" \
  "$RUNTRUE_RUNNER_MEMORY_BYTES" \
  "$RUNTRUE_RUNNER_NANO_CPUS" \
  "$RUNTRUE_AUTOSCALER_CAPACITY_RESERVE_MEMORY_BYTES" \
  "$RUNTRUE_AUTOSCALER_CAPACITY_RESERVE_NANO_CPUS" \
  "$RUNTRUE_AUTOSCALER_MAXIMUM_WORKERS" <<'PY'
import sys

memory, cpus, runner_memory, runner_cpu, reserve_memory, reserve_cpu, maximum = map(int, sys.argv[1:])
memory_slots = max(0, memory - reserve_memory) // runner_memory
cpu_slots = max(0, cpus * 1_000_000_000 - reserve_cpu) // runner_cpu
print(min(memory_slots, cpu_slots, maximum))
PY
)
((10#$RUNTRUE_EFFECTIVE_RUNNER_CAPACITY > 0)) ||
  die 'runner sizing and host reserve leave no capacity for an autoscaled runner'
readonly RUNTRUE_DOCKER_MEMORY_BYTES RUNTRUE_DOCKER_CPUS RUNTRUE_EFFECTIVE_RUNNER_CAPACITY
printf 'quick-start: effective autoscaled runner capacity is %s (configured maximum: %s)\n' \
  "$RUNTRUE_EFFECTIVE_RUNNER_CAPACITY" "$RUNTRUE_AUTOSCALER_MAXIMUM_WORKERS"
docker pull "$RUNTRUE_RUNNER_IMAGE" >/dev/null
runner_repo_digests=$(docker image inspect "$RUNTRUE_RUNNER_IMAGE" --format '{{json .RepoDigests}}')
RUNTRUE_RUNNER_IMAGE=$(RUNTRUE_RUNNER_IMAGE_REFERENCE="$RUNTRUE_RUNNER_IMAGE" \
  RUNTRUE_RUNNER_REPO_DIGESTS="$runner_repo_digests" python3 - <<'PY'
import json, os
reference = os.environ["RUNTRUE_RUNNER_IMAGE_REFERENCE"]
repository = reference.split("@", 1)[0]
last_slash = repository.rfind("/")
last_colon = repository.rfind(":")
if last_colon > last_slash:
    repository = repository[:last_colon]
digests = json.loads(os.environ["RUNTRUE_RUNNER_REPO_DIGESTS"])
matches = [value for value in digests if value.startswith(repository + "@sha256:")]
if len(matches) != 1:
    raise SystemExit("pulled runner image did not resolve to one exact repository digest")
print(matches[0])
PY
)
readonly RUNTRUE_RUNNER_IMAGE
if [[ "$RUNTRUE_TRAEFIK_MODE" == existing ]]; then
  docker network inspect "$RUNTRUE_EDGE_NETWORK_NAME" >/dev/null 2>&1 ||
    die "existing Traefik network not found: ${RUNTRUE_EDGE_NETWORK_NAME}"
fi

require_private_file "$RUNTRUE_GITHUB_APP_PRIVATE_KEY_SOURCE" 'GitHub App private key'
require_private_file "$RUNTRUE_GITHUB_OAUTH_CLIENT_SECRET_SOURCE" 'GitHub OAuth client secret'
openssl pkey -in "$RUNTRUE_GITHUB_APP_PRIVATE_KEY_SOURCE" -noout >/dev/null 2>&1 ||
  die 'GitHub App private key is not a valid PEM private key'

install -d -m 0700 "$RUNTRUE_INSTALL_ROOT"
[[ -x "$STATE_BOOTSTRAP" && ! -L "$STATE_BOOTSTRAP" ]] ||
  die "packaged state bootstrap is missing or unsafe: ${STATE_BOOTSTRAP}"

bootstrap=(
  "$STATE_BOOTSTRAP"
  --state-dir "$RUNTRUE_STATE_DIR"
  --with-github-app
  --with-runner-tls
)
if [[ "$RUNTRUE_TRAEFIK_MODE" == bundled ]]; then
  bootstrap+=(--with-traefik)
fi
env RUNTRUE_RUNTIME_UID="$RUNTRUE_RUNTIME_UID" RUNTRUE_RUNTIME_GID="$RUNTRUE_RUNTIME_GID" \
  "${bootstrap[@]}"

install -d -m 0700 -o "$RUNTRUE_RUNTIME_UID" -g "$RUNTRUE_RUNTIME_GID" \
  "${RUNTRUE_STATE_DIR}/autoscaler" \
  "${RUNTRUE_STATE_DIR}/repository-actions" \
  "${RUNTRUE_STATE_DIR}/repository-actions/builder" \
  "$RUNTRUE_AUTOSCALER_CLAIM_ROOT"
install_runtime_bundle \
  "$RUNTRUE_RUNNER_RUNTIME_BUNDLE_IMAGE" \
  "${RUNTRUE_STATE_DIR}/autoscaler/runtime-assets"
install_repository_action_signing_key
install_repository_action_registry_credentials
env RUNTRUE_RUNTIME_UID="$RUNTRUE_RUNTIME_UID" RUNTRUE_RUNTIME_GID="$RUNTRUE_RUNTIME_GID" \
  "${bootstrap[@]}" --check-only >/dev/null

install_private_file \
  "$RUNTRUE_GITHUB_APP_PRIVATE_KEY_SOURCE" \
  "${RUNTRUE_STATE_DIR}/github-app-provider/private-key.pem" \
  "$RUNTRUE_RUNTIME_UID" \
  "$RUNTRUE_RUNTIME_GID"
install_private_file \
  "$RUNTRUE_GITHUB_OAUTH_CLIENT_SECRET_SOURCE" \
  "${RUNTRUE_STATE_DIR}/secrets/github-oauth-client.secret" \
  "$RUNTRUE_RUNTIME_UID" \
  "$RUNTRUE_RUNTIME_GID"

write_runtime_environment "$RUNTIME_ENV"
install -m 0600 -o "$RUNTRUE_RUNTIME_UID" -g "$RUNTRUE_RUNTIME_GID" \
  "${SCRIPT_DIR}/compose.yml" "$COMPOSE_FILE"

compose=(docker compose --env-file "$RUNTIME_ENV" -f "$COMPOSE_FILE")
services=(server frontend github-signer action-admission action-builder autoscaler)
base_services=(server frontend github-signer action-admission action-builder)
if [[ "$RUNTRUE_TRAEFIK_MODE" == bundled ]]; then
  services+=(traefik)
  base_services+=(traefik)
fi
"${compose[@]}" config --quiet
if [[ "$RUNTRUE_TRAEFIK_MODE" == existing ]]; then
  "${compose[@]}" --profile bundled-traefik stop traefik
  "${compose[@]}" --profile bundled-traefik rm -f traefik
fi
"${compose[@]}" pull "${services[@]}"
stale_oci_runroot=false
if [[ -e "${RUNTRUE_STATE_DIR}/autoscaler/runtime-assets/oci/image-store/.runtrue-runroot" ||
      -L "${RUNTRUE_STATE_DIR}/autoscaler/runtime-assets/oci/image-store/.runtrue-runroot" ]]; then
  stale_oci_runroot=true
fi
"${compose[@]}" stop autoscaler action-builder action-admission >/dev/null 2>&1 || true
recycle_autoscaled_runners_for_repository_action_trust "$stale_oci_runroot"
clear_stale_oci_runroot
"${compose[@]}" up -d --wait --pull always "${base_services[@]}"
render_autoscaler_template "${RUNTRUE_STATE_DIR}/autoscaler/docker-template.json"

bootstrap_token=$(tr -d '\r\n' <"${RUNTRUE_STATE_DIR}/secrets/bootstrap.token")
pool_response=$(control_plane_request \
  "$bootstrap_token" GET "/api/v1/runner-pools/${RUNTRUE_AUTOSCALER_POOL_ID}")
pool_status=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])' <<<"$pool_response")
if [[ "$pool_status" == 404 ]]; then
  pool_body=$(python3 - "$RUNTRUE_AUTOSCALER_POOL_ID" "$RUNTRUE_AUTOSCALER_TENANT_ID" <<'PY'
import json, sys
print(json.dumps({
    "id": sys.argv[1],
    "tenant_id": sys.argv[2],
    "name": "Quickstart autoscaled runners",
    "region": "single-node",
}))
PY
)
  pool_response=$(control_plane_request "$bootstrap_token" POST /api/v1/runner-pools "$pool_body")
  pool_status=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])' <<<"$pool_response")
  [[ "$pool_status" == 201 ]] || die "runner pool creation failed with HTTP ${pool_status}"
elif [[ "$pool_status" == 200 ]]; then
  QUICKSTART_EXPECTED_TENANT=$RUNTRUE_AUTOSCALER_TENANT_ID python3 -c '
import json, os, sys
outer = json.load(sys.stdin)
pool = json.loads(outer["body"])
if pool.get("tenant_id") != os.environ["QUICKSTART_EXPECTED_TENANT"]:
    raise SystemExit("existing autoscaler pool belongs to a different tenant")
' <<<"$pool_response" || die 'existing autoscaler pool does not match this installation'
else
  die "runner pool lookup failed with HTTP ${pool_status}"
fi

install_capsule_trust_key "$bootstrap_token"

autoscaler_token_file="${RUNTRUE_STATE_DIR}/runner-secrets/autoscaler.token"
if [[ -e "$autoscaler_token_file" || -L "$autoscaler_token_file" ]]; then
  [[ -f "$autoscaler_token_file" && ! -L "$autoscaler_token_file" ]] ||
    die "unsafe autoscaler token path: ${autoscaler_token_file}"
  [[ "$(stat -c '%u:%g:%a' -- "$autoscaler_token_file")" == "${RUNTRUE_RUNTIME_UID}:${RUNTRUE_RUNTIME_GID}:600" ]] ||
    die 'autoscaler token has incorrect ownership or mode'
  autoscaler_token=$(tr -d '\r\n' <"$autoscaler_token_file")
else
  token_body=$(python3 - "$RUNTRUE_AUTOSCALER_TENANT_ID" <<'PY'
import json, sys
print(json.dumps({
    "id": "api-autoscaler-quickstart",
    "principal_id": "autoscaler-quickstart",
    "tenant_id": sys.argv[1],
    "name": "Quickstart Docker autoscaler",
    "scopes": ["runner-fleet:read", "runner-fleet:write"],
    "ttl_seconds": 31536000,
}))
PY
)
  token_response=$(control_plane_request "$bootstrap_token" POST /api/v1/api-tokens "$token_body")
  token_status=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])' <<<"$token_response")
  [[ "$token_status" == 201 ]] || die "autoscaler token issuance failed with HTTP ${token_status}"
  autoscaler_token=$(python3 -c 'import json,sys; print(json.loads(json.load(sys.stdin)["body"])["token"])' <<<"$token_response")
  [[ "$autoscaler_token" =~ ^[0-9a-f]{64}$ ]] || die 'issued autoscaler token is malformed'
  temporary_token=$(mktemp -- "${RUNTRUE_STATE_DIR}/runner-secrets/.autoscaler-token.XXXXXXXX")
  printf '%s\n' "$autoscaler_token" >"$temporary_token"
  install -m 0600 -o "$RUNTRUE_RUNTIME_UID" -g "$RUNTRUE_RUNTIME_GID" \
    "$temporary_token" "$autoscaler_token_file"
  rm -f -- "$temporary_token"
fi
unset bootstrap_token

runner_template_digest=$(runner_binary_digest "$RUNTRUE_RUNNER_IMAGE")
fleet_body=$(python3 - \
  "$runner_template_digest" \
  "$RUNTRUE_AUTOSCALER_MINIMUM_WORKERS" \
  "$RUNTRUE_AUTOSCALER_MINIMUM_IDLE_WORKERS" \
  "$RUNTRUE_AUTOSCALER_MAXIMUM_WORKERS" \
  "$RUNTRUE_AUTOSCALER_SCALE_UP_BATCH" \
  "$RUNTRUE_AUTOSCALER_IDLE_TIMEOUT_MS" <<'PY'
import json, sys
template, minimum, minimum_idle, maximum, scale_up_batch, idle = sys.argv[1:]
minimum = int(minimum)
minimum_idle = int(minimum_idle)
baseline = "sha256:e5b5fc9c576175a0bdacc09872fed2390332da870ce6140503664d07b88292ca"
print(json.dumps({
    "baseline_runtime_compatibility_digest": baseline if minimum or minimum_idle else None,
    "minimum_workers": minimum,
    "minimum_idle_workers": minimum_idle,
    "maximum_workers": int(maximum),
    "scale_up_batch": int(scale_up_batch),
    "idle_timeout_ms": int(idle),
    "offline_grace_ms": 60000,
    "cooldown_ms": 5000,
    "enabled": True,
    "templates": [
        {
            "runtime_compatibility_digest": baseline,
            "provider": "docker",
            "provider_template_id": "quickstart-generic-docker-v1",
            "runner_template_digest": template,
        },
    ],
}))
PY
)
fleet_response=$(control_plane_request \
  "$autoscaler_token" PUT \
  "/api/v1/runner-pools/${RUNTRUE_AUTOSCALER_POOL_ID}/fleet/configuration" \
  "$fleet_body")
fleet_status=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])' <<<"$fleet_response")
unset autoscaler_token
[[ "$fleet_status" == 204 ]] || die "fleet configuration failed with HTTP ${fleet_status}"

"${compose[@]}" up -d --wait --pull always autoscaler

printf '\nAutoscaled runner capacity: %s effective on this host (%s configured maximum)\n' \
  "$RUNTRUE_EFFECTIVE_RUNNER_CAPACITY" "$RUNTRUE_AUTOSCALER_MAXIMUM_WORKERS"

if [[ "$RUNTRUE_TRAEFIK_MODE" == bundled ]]; then
  printf '\nRuntrue is ready at %s\n\n' "$RUNTRUE_PUBLIC_ORIGIN"
else
  printf '\nRuntrue is healthy and labeled for the existing Traefik Docker provider.\n'
  printf 'Shared network:     %s\n' "$RUNTRUE_EDGE_NETWORK_NAME"
  printf 'Router:             %s\n' "$RUNTRUE_TRAEFIK_ROUTER_NAME"
  printf 'Certificate resolver: %s\n\n' "$RUNTRUE_TRAEFIK_CERT_RESOLVER"
  if [[ -f "${RUNTRUE_INSTALL_ROOT}/traefik-route.yml" ]]; then
    printf 'Legacy file-provider route detected: %s\n' "${RUNTRUE_INSTALL_ROOT}/traefik-route.yml"
    printf 'Remove that route from Traefik after confirming Docker-label routing.\n\n'
  fi
fi
printf 'GitHub App URLs:\n'
printf '  Homepage: %s\n' "$RUNTRUE_PUBLIC_ORIGIN"
printf '  Callback: %s/auth/callback\n' "$RUNTRUE_PUBLIC_ORIGIN"
printf '  Setup:    %s/auth/github/app/callback\n' "$RUNTRUE_PUBLIC_ORIGIN"
printf '  Webhook:  %s/webhooks/github\n\n' "$RUNTRUE_PUBLIC_ORIGIN"
printf 'Webhook secret (copy into the GitHub App):\n'
tr -d '\n' <"${RUNTRUE_STATE_DIR}/secrets/github-webhook.secret"
printf '\n\nOperations:\n'
printf '  docker compose --env-file %s -f %s ps\n' "$RUNTIME_ENV" "$COMPOSE_FILE"
printf '  docker compose --env-file %s -f %s logs -f\n' "$RUNTIME_ENV" "$COMPOSE_FILE"
printf '  docker compose --env-file %s -f %s down\n' "$RUNTIME_ENV" "$COMPOSE_FILE"
