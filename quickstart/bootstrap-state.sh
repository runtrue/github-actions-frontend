#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly SCRIPT_DIR
STATE_DIR=
WITH_TRAEFIK=false
CHECK_ONLY=false
TEMP_PATHS=()

die() {
  printf 'bootstrap: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  local path
  for path in "${TEMP_PATHS[@]:-}"; do
    if [[ -n "$path" && -e "$path" && ! -L "$path" ]]; then
      rm -rf -- "$path"
    fi
  done
}
trap cleanup EXIT HUP INT TERM

while (($#)); do
  case "$1" in
    --state-dir)
      (($# >= 2)) || die '--state-dir requires a path'
      STATE_DIR=$2
      shift 2
      ;;
    --with-github-app | --with-runner-tls)
      # These are always enabled by the quickstart package.
      shift
      ;;
    --with-traefik)
      WITH_TRAEFIK=true
      shift
      ;;
    --check-only)
      CHECK_ONLY=true
      shift
      ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ -n "$STATE_DIR" ]] || die '--state-dir is required'
[[ "${RUNTRUE_RUNTIME_UID:-}" =~ ^[1-9][0-9]*$ ]] ||
  die 'RUNTRUE_RUNTIME_UID must be a positive number'
[[ "${RUNTRUE_RUNTIME_GID:-}" =~ ^[1-9][0-9]*$ ]] ||
  die 'RUNTRUE_RUNTIME_GID must be a positive number'
readonly RUNTIME_UID=$RUNTRUE_RUNTIME_UID
readonly RUNTIME_GID=$RUNTRUE_RUNTIME_GID

if [[ "$STATE_DIR" != /* ]]; then
  STATE_DIR=$(realpath -m -s -- "${PWD}/${STATE_DIR}")
else
  STATE_DIR=$(realpath -m -s -- "$STATE_DIR")
fi
[[ "$STATE_DIR" =~ ^/[A-Za-z0-9_./-]+$ && "$STATE_DIR" != / ]] ||
  die 'state directory must be a safe absolute path other than /'
readonly STATE_DIR

reject_symlink_components() {
  local path=$1 current=/ component
  local -a components
  IFS='/' read -r -a components <<<"${path#/}"
  for component in "${components[@]}"; do
    [[ -n "$component" && "$component" != . ]] || continue
    [[ "$component" != .. ]] || die "parent traversal is not allowed: ${path}"
    current="${current%/}/${component}"
    [[ ! -L "$current" ]] || die "symbolic-link path component rejected: ${current}"
  done
}

owner_mode() {
  stat -c '%u:%g:%a' -- "$1"
}

validate_private_directory() {
  local path=$1
  reject_symlink_components "$path"
  [[ -d "$path" && ! -L "$path" ]] || die "private directory is missing or unsafe: ${path}"
  [[ "$(owner_mode "$path")" == "${RUNTIME_UID}:${RUNTIME_GID}:700" ]] ||
    die "private directory must be owned by ${RUNTIME_UID}:${RUNTIME_GID} with mode 0700: ${path}"
}

ensure_private_directory() {
  local path=$1
  if [[ -e "$path" || -L "$path" ]]; then
    validate_private_directory "$path"
    return
  fi
  reject_symlink_components "$(dirname -- "$path")"
  install -d -m 0700 -o "$RUNTIME_UID" -g "$RUNTIME_GID" -- "$path"
  validate_private_directory "$path"
}

validate_private_file() {
  local path=$1 expected_bytes=${2:-}
  reject_symlink_components "$path"
  [[ -f "$path" && ! -L "$path" ]] || die "private file is missing or unsafe: ${path}"
  [[ "$(owner_mode "$path")" == "${RUNTIME_UID}:${RUNTIME_GID}:600" ]] ||
    die "private file must be owned by ${RUNTIME_UID}:${RUNTIME_GID} with mode 0600: ${path}"
  [[ "$(stat -c '%h' -- "$path")" == 1 ]] || die "hard-linked private file rejected: ${path}"
  if [[ -n "$expected_bytes" ]]; then
    [[ "$(stat -c '%s' -- "$path")" == "$expected_bytes" ]] ||
      die "private file has an invalid byte length: ${path}"
  fi
}

publish_new_file() {
  local temporary=$1 destination=$2
  [[ ! -e "$destination" && ! -L "$destination" ]] ||
    die "refusing to replace existing file: ${destination}"
  chmod 0600 -- "$temporary"
  chown "${RUNTIME_UID}:${RUNTIME_GID}" -- "$temporary"
  ln -- "$temporary" "$destination"
  rm -f -- "$temporary"
}

new_temporary_file() {
  local directory=$1 stem=$2
  mktemp -- "${directory}/.${stem}.tmp.XXXXXXXX"
}

create_random_file() {
  local destination=$1 encoding=$2 bytes=$3 temporary
  if [[ -e "$destination" || -L "$destination" ]]; then
    validate_private_file "$destination"
    return
  fi
  temporary=$(new_temporary_file "$(dirname -- "$destination")" "$(basename -- "$destination")")
  TEMP_PATHS+=("$temporary")
  case "$encoding" in
    raw) openssl rand "$bytes" >"$temporary" ;;
    hex) openssl rand -hex "$bytes" >"$temporary" ;;
    *) die "unsupported random encoding: ${encoding}" ;;
  esac
  publish_new_file "$temporary" "$destination"
}

create_empty_file() {
  local destination=$1 temporary
  if [[ -e "$destination" || -L "$destination" ]]; then
    validate_private_file "$destination" 0
    return
  fi
  temporary=$(new_temporary_file "$(dirname -- "$destination")" "$(basename -- "$destination")")
  TEMP_PATHS+=("$temporary")
  : >"$temporary"
  publish_new_file "$temporary" "$destination"
}

install_managed_file() {
  local source=$1 destination=$2 temporary
  [[ -f "$source" && ! -L "$source" ]] || die "managed source is missing or unsafe: ${source}"
  if [[ -e "$destination" || -L "$destination" ]]; then
    validate_private_file "$destination"
    cmp -s -- "$source" "$destination" && return
  fi
  temporary=$(new_temporary_file "$(dirname -- "$destination")" "$(basename -- "$destination")")
  TEMP_PATHS+=("$temporary")
  install -m 0600 -o "$RUNTIME_UID" -g "$RUNTIME_GID" -- "$source" "$temporary"
  if [[ -e "$destination" ]]; then
    mv -fT -- "$temporary" "$destination"
  else
    publish_new_file "$temporary" "$destination"
  fi
}

validate_tls_material() {
  local directory="${STATE_DIR}/tls" public_key certificate_key
  local name
  for name in runner-ca.key runner-ca.pem runner-server.key runner-server.pem; do
    validate_private_file "${directory}/${name}"
  done
  openssl pkey -in "${directory}/runner-ca.key" -noout >/dev/null 2>&1 || die 'runner CA key is invalid'
  openssl x509 -in "${directory}/runner-ca.pem" -noout >/dev/null 2>&1 || die 'runner CA certificate is invalid'
  openssl pkey -in "${directory}/runner-server.key" -noout >/dev/null 2>&1 || die 'runner server key is invalid'
  openssl x509 -in "${directory}/runner-server.pem" -noout >/dev/null 2>&1 || die 'runner server certificate is invalid'
  openssl x509 -in "${directory}/runner-ca.pem" -noout -text 2>/dev/null |
    grep -q 'CA:TRUE' || die 'runner CA certificate lacks CA constraints'
  openssl verify -CAfile "${directory}/runner-ca.pem" "${directory}/runner-server.pem" >/dev/null 2>&1 ||
    die 'runner server certificate does not verify under the runner CA'
  openssl x509 -in "${directory}/runner-server.pem" -checkhost server -noout >/dev/null 2>&1 ||
    die 'runner server certificate is not valid for the server service'
  public_key=$(new_temporary_file "$directory" server-public)
  certificate_key=$(new_temporary_file "$directory" certificate-public)
  TEMP_PATHS+=("$public_key" "$certificate_key")
  openssl pkey -in "${directory}/runner-server.key" -pubout -out "$public_key" 2>/dev/null
  openssl x509 -in "${directory}/runner-server.pem" -pubkey -noout >"$certificate_key" 2>/dev/null
  cmp -s -- "$public_key" "$certificate_key" || die 'runner server certificate and key do not match'
  rm -f -- "$public_key" "$certificate_key"
}

create_tls_material() {
  local directory="${STATE_DIR}/tls" temporary serial name present=0
  local -a names=(runner-ca.key runner-ca.pem runner-server.key runner-server.pem)
  for name in "${names[@]}"; do
    [[ -e "${directory}/${name}" || -L "${directory}/${name}" ]] && ((present += 1))
  done
  if ((present == ${#names[@]})); then
    validate_tls_material
    return
  fi
  ((present == 0)) || die 'partial runner TLS state found; refusing to replace credentials'
  temporary=$(mktemp -d -- "${directory}/.bootstrap-tls.XXXXXXXX")
  TEMP_PATHS+=("$temporary")
  chmod 0700 -- "$temporary"
  openssl genpkey -algorithm ED25519 -out "${temporary}/runner-ca.key" 2>/dev/null
  openssl req -new -x509 -key "${temporary}/runner-ca.key" \
    -out "${temporary}/runner-ca.pem" -days 3650 \
    -subj '/CN=Runtrue local evaluation runner CA' \
    -addext 'basicConstraints=critical,CA:TRUE,pathlen:0' \
    -addext 'keyUsage=critical,keyCertSign,cRLSign' 2>/dev/null
  openssl genpkey -algorithm ED25519 -out "${temporary}/runner-server.key" 2>/dev/null
  openssl req -new -key "${temporary}/runner-server.key" \
    -out "${temporary}/runner-server.csr" -subj '/CN=server' \
    -addext 'subjectAltName=DNS:server,DNS:localhost,IP:127.0.0.1' 2>/dev/null
  cat >"${temporary}/server.ext" <<'EOF'
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=serverAuth
subjectAltName=DNS:server,DNS:localhost,IP:127.0.0.1
EOF
  serial=$(openssl rand -hex 16)
  openssl x509 -req -in "${temporary}/runner-server.csr" \
    -CA "${temporary}/runner-ca.pem" -CAkey "${temporary}/runner-ca.key" \
    -set_serial "0x${serial}" -days 30 -extfile "${temporary}/server.ext" \
    -out "${temporary}/runner-server.pem" 2>/dev/null
  for name in "${names[@]}"; do
    chmod 0600 -- "${temporary}/${name}"
    chown "${RUNTIME_UID}:${RUNTIME_GID}" -- "${temporary}/${name}"
    publish_new_file "${temporary}/${name}" "${directory}/${name}"
  done
  rm -rf -- "$temporary"
  validate_tls_material
}

validate_state_tree() {
  local image_store="${STATE_DIR}/autoscaler/runtime-assets/oci/image-store"
  # Older quickstart releases persisted Podman's ephemeral directories here.
  # They remain opaque during validation so upgrades can safely stop using them.
  local podman_home="${STATE_DIR}/autoscaler/runtime-assets/oci/podman-home"
  local podman_runtime="${STATE_DIR}/autoscaler/runtime-assets/oci/podman-runtime"
  local podman_tmp="${STATE_DIR}/autoscaler/runtime-assets/oci/podman-tmp"
  local runtime_tmp="${STATE_DIR}/autoscaler/runtime-assets/oci/tmp"
  local action_builder_root="${STATE_DIR}/repository-actions/builder"
  local opaque_root opaque_root_mode link unsafe
  local -a opaque_roots=(
    "$image_store"
    "$podman_home"
    "$podman_runtime"
    "$podman_tmp"
    "$runtime_tmp"
  )
  reject_symlink_components "$STATE_DIR"
  # Podman-managed stores and temporary state are opaque runtime content.
  # Rootfs links may be absolute or cross layer boundaries, so validate their
  # location without following or interpreting their targets on the host.
  while IFS= read -r -d '' link; do
    case "$link" in
      "${image_store}/"* | "${podman_home}/"* | "${podman_runtime}/"* | "${podman_tmp}/"* | "${runtime_tmp}/"*) ;;
      *) die "symbolic link in managed state rejected: ${link}" ;;
    esac
  done < <(find -P "$STATE_DIR" -xdev -type l -print0)
  for opaque_root in "${opaque_roots[@]}"; do
    if [[ -e "$opaque_root" || -L "$opaque_root" ]]; then
      [[ -d "$opaque_root" && ! -L "$opaque_root" ]] ||
        die "opaque runtime root is missing or unsafe: ${opaque_root}"
      [[ "$(stat -c '%u:%g' -- "$opaque_root")" == "${RUNTIME_UID}:${RUNTIME_GID}" ]] ||
        die "opaque runtime root has an unexpected owner: ${opaque_root}"
      opaque_root_mode=$(stat -c '%a' -- "$opaque_root")
      (((8#$opaque_root_mode & 8#022) == 0)) ||
        die "opaque runtime root is writable by group or other: ${opaque_root}"
    fi
  done
  unsafe=$(find -P "$STATE_DIR" -xdev \
    \( -path "$image_store" -o -path "$podman_home" -o -path "$podman_runtime" \
      -o -path "$podman_tmp" -o -path "$runtime_tmp" \) -prune -o \
    -type d ! -path "$action_builder_root" ! -perm 0700 -print -quit)
  [[ -z "$unsafe" ]] || die "managed directory does not have exact mode 0700: ${unsafe}"
  if [[ -d "$action_builder_root" && ! -L "$action_builder_root" ]]; then
    case "$(stat -c '%a' -- "$action_builder_root")" in
      700 | 750) ;;
      *) die "repository-action builder directory has an unsafe mode: ${action_builder_root}" ;;
    esac
  fi
  unsafe=$(find -P "$STATE_DIR" -xdev \
    \( -path "$image_store" -o -path "$podman_home" -o -path "$podman_runtime" \
      -o -path "$podman_tmp" -o -path "$runtime_tmp" \) -prune -o \
    -type f \( -perm /022 -o ! -perm -0400 \) -print -quit)
  [[ -z "$unsafe" ]] ||
    die "managed file is not owner-readable or is writable by group/other: ${unsafe}"
  unsafe=$(find -P "$STATE_DIR" -xdev \
    \( -path "$image_store" -o -path "$podman_home" -o -path "$podman_runtime" \
      -o -path "$podman_tmp" -o -path "$runtime_tmp" \) -prune -o \
    ! -uid "$RUNTIME_UID" -print -quit)
  [[ -z "$unsafe" ]] || die "managed path has an unexpected owner: ${unsafe}"
  unsafe=$(find -P "$STATE_DIR" -xdev \
    \( -path "$image_store" -o -path "$podman_home" -o -path "$podman_runtime" \
      -o -path "$podman_tmp" -o -path "$runtime_tmp" \) -prune -o \
    ! -gid "$RUNTIME_GID" -print -quit)
  [[ -z "$unsafe" ]] || die "managed path has an unexpected group: ${unsafe}"
}

directories=(
  "$STATE_DIR"
  "${STATE_DIR}/server"
  "${STATE_DIR}/server/git-mirrors"
  "${STATE_DIR}/secrets"
  "${STATE_DIR}/keys"
  "${STATE_DIR}/backups"
  "${STATE_DIR}/restores"
  "${STATE_DIR}/recovery-config"
  "${STATE_DIR}/runner"
  "${STATE_DIR}/runner/state"
  "${STATE_DIR}/runner/credentials"
  "${STATE_DIR}/workspaces"
  "${STATE_DIR}/tls"
  "${STATE_DIR}/runner-trust"
  "${STATE_DIR}/runner-trust/capsule-keys"
  "${STATE_DIR}/runner-secrets"
  "${STATE_DIR}/github-app-provider"
)
if "$WITH_TRAEFIK"; then
  directories+=("${STATE_DIR}/traefik")
fi

if "$CHECK_ONLY"; then
  for directory in "${directories[@]}"; do
    validate_private_directory "$directory"
  done
else
  for directory in "${directories[@]}"; do
    ensure_private_directory "$directory"
  done
  create_random_file "${STATE_DIR}/secrets/bootstrap.token" hex 32
  create_random_file "${STATE_DIR}/keys/security.key" raw 32
  create_random_file "${STATE_DIR}/secrets/github-webhook.secret" hex 32
  create_random_file "${STATE_DIR}/secrets/browser-cookie.key" raw 32
  create_tls_material
  if "$WITH_TRAEFIK"; then
    create_empty_file "${STATE_DIR}/traefik/acme.json"
    install_managed_file "${SCRIPT_DIR}/traefik-entrypoint.sh" "${STATE_DIR}/traefik/entrypoint.sh"
  fi
fi

validate_private_file "${STATE_DIR}/secrets/bootstrap.token" 65
validate_private_file "${STATE_DIR}/keys/security.key" 32
validate_private_file "${STATE_DIR}/secrets/github-webhook.secret" 65
validate_private_file "${STATE_DIR}/secrets/browser-cookie.key" 32
validate_tls_material
if "$WITH_TRAEFIK"; then
  validate_private_file "${STATE_DIR}/traefik/acme.json" 0
  validate_private_file "${STATE_DIR}/traefik/entrypoint.sh"
  cmp -s -- "${SCRIPT_DIR}/traefik-entrypoint.sh" "${STATE_DIR}/traefik/entrypoint.sh" ||
    die 'managed Traefik entrypoint is stale'
fi
validate_state_tree

printf 'Runtrue quickstart state preflight passed for %s (runtime uid:gid %s:%s).\n' \
  "$STATE_DIR" "$RUNTIME_UID" "$RUNTIME_GID"
printf 'No credential values were printed or replaced.\n'
