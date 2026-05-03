#!/usr/bin/env bash
# Installs / updates Planulix gateway on a Linux VPS.
#
# Fast path: download a ready Linux binary from GitHub Releases.
# Fallback: build from source only if the release asset is not available.
#
# Environment:
#   AUTH_TOKEN              required, shared secret for the app and gateway
#   PORT                    default: 8990
#   PLANULIX_HOME           default: ~/.planulix-gateway
#   PLANULIX_REPO_SLUG      default: pyatkovpetr/Planulix
#   PLANULIX_RELEASE_TAG    default: gateway-latest
#   PLANULIX_DOWNLOAD_BASE  optional direct asset base URL
#   PLANULIX_ALLOW_BUILD_FALLBACK=0 disables source build fallback

set -euo pipefail

: "${AUTH_TOKEN:?missing AUTH_TOKEN}"

PORT="${PORT:-8990}"
BASE="${PLANULIX_HOME:-${HOME:?}/.planulix-gateway}"
BIN_DIR="$BASE/bin"
LOGDIR="$BASE/logs"
RUNDIR="$BASE/run"
REPODIR="$BASE/repo"
ENV_FILE="$BASE/planulix.env"
BIN="$BIN_DIR/planulix-gateway"
SERVICE_NAME="${PLANULIX_SERVICE_NAME:-planulix-gateway}"
REPO_SLUG="${PLANULIX_REPO_SLUG:-pyatkovpetr/Planulix}"
RELEASE_TAG="${PLANULIX_RELEASE_TAG:-gateway-latest}"
DOWNLOAD_BASE="${PLANULIX_DOWNLOAD_BASE:-https://github.com/${REPO_SLUG}/releases/download/${RELEASE_TAG}}"
ALLOW_BUILD_FALLBACK="${PLANULIX_ALLOW_BUILD_FALLBACK:-1}"
SOURCE_REPO="${PLANULIX_REPO:-https://github.com/${REPO_SLUG}.git}"
PLANULIX_GO_VERSION="${PLANULIX_GO_VERSION:-1.25.0}"
GO_MIN_GOENV="go${PLANULIX_GO_VERSION}"

mkdir -p "$BIN_DIR" "$LOGDIR" "$RUNDIR"

unset GIT_ASKPASS SSH_ASKPASS
export GIT_TERMINAL_PROMPT=0

log() {
  printf 'PLANULIX: %s\n' "$*"
}

die() {
  printf 'PLANULIX_ERROR: %s\n' "$*" >&2
  exit "${2:-1}"
}

maybe_sudo() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  else
    sudo -n "$@"
  fi
}

has_noninteractive_sudo() {
  [ "$(id -u)" -eq 0 ] || sudo -n true >/dev/null 2>&1
}

install_apt_packages() {
  command -v apt-get >/dev/null 2>&1 || return 1
  has_noninteractive_sudo || return 1
  maybe_sudo apt-get update -qq
  maybe_sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
}

ensure_tool() {
  local tool="$1"
  shift || true
  if command -v "$tool" >/dev/null 2>&1; then
    return 0
  fi
  log "Installing missing tool: $tool"
  install_apt_packages "$@" || die "Missing '$tool'. Install it manually or run as root/passwordless sudo." 20
}

detect_arch() {
  local raw
  raw="$(uname -m || true)"
  case "$raw" in
    x86_64 | amd64) printf 'amd64' ;;
    aarch64 | arm64) printf 'arm64' ;;
    *) die "Unsupported Linux architecture: $raw (need amd64 or arm64)" 14 ;;
  esac
}

probe() {
  curl -fsS "http://127.0.0.1:${PORT}/healthz" >/dev/null 2>&1
}

download_binary() {
  local arch asset url tmp
  arch="$(detect_arch)"
  asset="planulix-gateway-linux-${arch}.tar.gz"
  url="${DOWNLOAD_BASE}/${asset}"
  tmp="$(mktemp -d)"

  log "Downloading gateway binary: ${url}"
  if ! curl -fsSL "$url" -o "$tmp/$asset"; then
    rm -rf "$tmp"
    return 1
  fi

  tar -xzf "$tmp/$asset" -C "$tmp"
  if [ ! -f "$tmp/planulix-gateway" ]; then
    rm -rf "$tmp"
    die "Release asset does not contain planulix-gateway" 21
  fi

  install -m 0755 "$tmp/planulix-gateway" "$BIN"
  rm -rf "$tmp"
  log "Binary installed to $BIN"
  return 0
}

go_version_ok() {
  command -v go >/dev/null 2>&1 || return 1
  local v oldest
  v="$(go env GOVERSION 2>/dev/null || echo go0.0.0)"
  oldest="$(printf '%s\n' "$v" "$GO_MIN_GOENV" | sort -V | head -n1)"
  [ "$oldest" = "$GO_MIN_GOENV" ]
}

install_go_upstream() {
  local arch url tmp
  arch="$(detect_arch)"
  url="https://go.dev/dl/go${PLANULIX_GO_VERSION}.linux-${arch}.tar.gz"
  tmp="$(mktemp)"

  has_noninteractive_sudo || die "Go fallback needs root/passwordless sudo to install /usr/local/go" 22
  log "Installing Go ${PLANULIX_GO_VERSION} from go.dev"
  curl -fsSL "$url" -o "$tmp"
  maybe_sudo rm -rf /usr/local/go
  maybe_sudo tar -C /usr/local -xzf "$tmp"
  rm -f "$tmp"
  export PATH="/usr/local/go/bin:${PATH}"
}

build_from_source() {
  [ "$ALLOW_BUILD_FALLBACK" = "1" ] || return 1

  log "Release binary unavailable; falling back to source build"
  ensure_tool git git
  export PATH="/usr/local/go/bin:${PATH}"
  if ! go_version_ok; then
    install_go_upstream
  fi
  go_version_ok || die "Need Go >= ${GO_MIN_GOENV} to build fallback" 12

  if [ -d "$REPODIR/.git" ]; then
    git -c credential.helper= -C "$REPODIR" fetch --depth 1 origin
    git -c credential.helper= -C "$REPODIR" reset --hard origin/HEAD
  else
    rm -rf "$REPODIR"
    git -c credential.helper= clone --depth 1 "$SOURCE_REPO" "$REPODIR"
  fi

  (cd "$REPODIR/server" && go build -trimpath -ldflags="-s -w" -o "$BIN" .)
  chmod 0755 "$BIN"
}

write_env_file() {
  cat >"$ENV_FILE" <<EOF
AUTH_TOKEN=${AUTH_TOKEN}
PORT=${PORT}
EOF
  chmod 0600 "$ENV_FILE"
}

start_with_systemd() {
  command -v systemctl >/dev/null 2>&1 || return 1
  has_noninteractive_sudo || return 1

  local svc_tmp svc_path run_user
  svc_tmp="$(mktemp)"
  svc_path="/etc/systemd/system/${SERVICE_NAME}.service"
  run_user="$(id -un)"

  cat >"$svc_tmp" <<EOF
[Unit]
Description=Planulix Gateway
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${run_user}
WorkingDirectory=${BASE}
EnvironmentFile=${ENV_FILE}
ExecStart=${BIN}
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

  maybe_sudo install -m 0644 "$svc_tmp" "$svc_path"
  rm -f "$svc_tmp"
  maybe_sudo systemctl daemon-reload
  maybe_sudo systemctl enable --now "$SERVICE_NAME"
  maybe_sudo systemctl restart "$SERVICE_NAME"
  log "Started systemd service: ${SERVICE_NAME}"
  return 0
}

start_with_nohup() {
  if [ -f "$RUNDIR/planulix.pid" ]; then
    oldpid="$(cat "$RUNDIR/planulix.pid" || true)"
    if [ -n "${oldpid:-}" ]; then
      kill "$oldpid" 2>/dev/null || true
    fi
    rm -f "$RUNDIR/planulix.pid"
  fi

  nohup env AUTH_TOKEN="$AUTH_TOKEN" PORT="$PORT" "$BIN" >>"$LOGDIR/planulix.log" 2>&1 &
  echo $! >"$RUNDIR/planulix.pid"
  log "Started with nohup (pid $(cat "$RUNDIR/planulix.pid"))"
}

ensure_tool curl curl ca-certificates
ensure_tool tar tar

if ! download_binary; then
  build_from_source || die "Could not download release binary and source build fallback failed" 23
fi

write_env_file

if ! start_with_systemd; then
  log "systemd unavailable; using nohup fallback"
  start_with_nohup
fi

for _ in $(seq 1 40); do
  if probe; then
    log "Gateway is healthy on http://127.0.0.1:${PORT}"
    echo "PLANULIX_INSTALL_OK"
    exit 0
  fi
  sleep 1
done

echo "PLANULIX_VERIFY_FAILED" >&2
if command -v systemctl >/dev/null 2>&1 && has_noninteractive_sudo; then
  maybe_sudo systemctl --no-pager --full status "$SERVICE_NAME" >&2 || true
fi
tail -80 "$LOGDIR/planulix.log" >&2 || true
exit 3
