#!/usr/bin/env bash
set -euo pipefail

SERVICE_NAME="lunch-http-server"
DISPLAY_NAME="Lunch HTTP Server"
RELEASE_REPO="${RELEASE_REPO:-wxyjay/lunch-http-server-releases}"
INSTALL_DIR="${INSTALL_DIR:-/opt/lunch-http-server}"
DATA_DIR="${DATA_DIR:-/var/lib/lunch-http-server}"
UNIT_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
BRANCH="main"
ACTION=""
TMP_DIR_TO_CLEAN=""

cleanup_tmp_dir() {
  if [[ -n "${TMP_DIR_TO_CLEAN:-}" ]]; then
    rm -rf "$TMP_DIR_TO_CLEAN"
  fi
}
trap cleanup_tmp_dir EXIT

usage() {
  cat <<'EOF'
Usage:
  install-http-server.sh [--branch main|debug] [--install|--uninstall|--purge|--status|--interactive]

Environment:
  RELEASE_REPO                Public release repo, default wxyjay/lunch-http-server-releases.
  INSTALL_DIR                 Program directory, default /opt/lunch-http-server.
  DATA_DIR                    Runtime data directory, default /var/lib/lunch-http-server.
  LUNCH_HTTP_RELEASE_PASSWORD Archive password. If empty, /etc/lunch-http-server/release-password is used.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --branch)
      BRANCH="${2:-}"
      shift 2
      ;;
    --install)
      ACTION="install"
      shift
      ;;
    --uninstall)
      ACTION="uninstall"
      shift
      ;;
    --purge)
      ACTION="purge"
      shift
      ;;
    --status)
      ACTION="status"
      shift
      ;;
    --interactive)
      ACTION="interactive"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ "$BRANCH" != "main" && "$BRANCH" != "debug" ]]; then
  echo "--branch must be main or debug." >&2
  exit 1
fi

require_root() {
  if [[ "$(id -u)" != "0" ]]; then
    echo "Please run as root." >&2
    exit 1
  fi
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing command: $1" >&2; exit 1; }
}

ensure_dependencies() {
  local missing=()
  local cmd
  for cmd in curl tar systemctl awk sed grep find mv cp rm chmod mkdir cat id uname mktemp openssl; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  if [[ "${#missing[@]}" -eq 0 ]]; then
    return
  fi
  echo "Missing required commands: ${missing[*]}" >&2
  echo "Install them first, then rerun this script." >&2
  exit 1
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo "amd64" ;;
    aarch64|arm64) echo "aarch64" ;;
    *) echo "Unsupported architecture: $(uname -m)" >&2; exit 1 ;;
  esac
}

sha256_file() {
  openssl dgst -sha256 "$1" | awk '{print $NF}'
}

manifest_url() {
  local channel="$1"
  printf 'https://raw.githubusercontent.com/%s/%s/manifests/http-server/%s.json' "$RELEASE_REPO" "$BRANCH" "$channel"
}

extract_asset_sha() {
  local manifest="$1"
  local asset="$2"
  awk -v target="$asset" '
    index($0, "\"name\"") {
      line=$0
      sub(/^.*"name"[[:space:]]*:[[:space:]]*"/, "", line)
      sub(/".*$/, "", line)
      current=line
    }
    index($0, "\"sha256\"") && current == target {
      line=$0
      sub(/^.*"sha256"[[:space:]]*:[[:space:]]*"/, "", line)
      sub(/".*$/, "", line)
      print line
      exit
    }
  ' "$manifest"
}

release_password() {
  if [[ -n "${LUNCH_HTTP_RELEASE_PASSWORD:-}" ]]; then
    printf '%s' "$LUNCH_HTTP_RELEASE_PASSWORD"
    return
  fi
  local password_file="/etc/lunch-http-server/release-password"
  if [[ -f "$password_file" ]]; then
    tr -d '\r\n' < "$password_file"
    return
  fi
  if [[ -t 0 ]]; then
    read -r -s -p "Release archive password: " password
    echo
    printf '%s' "$password"
    return
  fi
  echo "Missing release archive password. Set LUNCH_HTTP_RELEASE_PASSWORD or /etc/lunch-http-server/release-password." >&2
  exit 1
}

download_asset() {
  local arch="$1"
  local channel="stable"
  [[ "$BRANCH" == "debug" ]] && channel="debug"
  local tmp_dir="$2"
  local manifest="${tmp_dir}/manifest.json"

  curl -fsSL "$(manifest_url "$channel")" -o "$manifest"
  local tag
  tag="$(sed -n 's/.*"tag"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$manifest" | head -n 1)"
  local asset
  asset="$(sed -n 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*linux-'"${arch}"'\.tar\.gz\.enc\)".*/\1/p' "$manifest" | head -n 1)"
  if [[ -z "$tag" || -z "$asset" ]]; then
    echo "No http-server encrypted asset found for arch=${arch} in ${channel} manifest." >&2
    exit 1
  fi

  local expected_sha
  expected_sha="$(extract_asset_sha "$manifest" "$asset" || true)"
  if [[ -z "$expected_sha" ]]; then
    echo "No SHA256 found for asset=${asset}." >&2
    exit 1
  fi

  local encrypted_archive="${tmp_dir}/${asset}"
  curl -fL "https://github.com/${RELEASE_REPO}/releases/download/${tag}/${asset}" -o "$encrypted_archive"
  local actual_sha
  actual_sha="$(sha256_file "$encrypted_archive")"
  if [[ "$actual_sha" != "$expected_sha" ]]; then
    echo "SHA256 mismatch for ${asset}: got ${actual_sha}, expected ${expected_sha}" >&2
    exit 1
  fi

  local archive="${encrypted_archive%.enc}"
  local password
  password="$(release_password)"
  openssl enc -d -aes-256-cbc -pbkdf2 -md sha256 -salt \
    -pass "pass:${password}" \
    -in "$encrypted_archive" \
    -out "$archive"
  printf '%s\n' "$archive"
}

write_unit() {
  cat > "$UNIT_FILE" <<EOF
[Unit]
Description=${DISPLAY_NAME}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=${DATA_DIR}
Environment=LUNCH_SERVER_BASE_DIR=${DATA_DIR}
ExecStart=${INSTALL_DIR}/HttpServerBackend
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
}

install_or_update() {
  ensure_dependencies
  local arch
  arch="$(detect_arch)"
  TMP_DIR_TO_CLEAN="$(mktemp -d)"
  local archive
  archive="$(download_asset "$arch" "$TMP_DIR_TO_CLEAN")"

  mkdir -p "$INSTALL_DIR" "$DATA_DIR"
  if [[ -x "${INSTALL_DIR}/HttpServerBackend" ]]; then
    cp -f "${INSTALL_DIR}/HttpServerBackend" "${INSTALL_DIR}/HttpServerBackend.bak"
  fi
  tar -xzf "$archive" -C "$INSTALL_DIR"
  chmod +x "${INSTALL_DIR}/HttpServerBackend"
  write_unit
  systemctl daemon-reload
  systemctl enable "$SERVICE_NAME"
  systemctl restart "$SERVICE_NAME"
  systemctl --no-pager status "$SERVICE_NAME" || true
}

uninstall_keep_data() {
  need_cmd systemctl
  systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
  systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true
  rm -f "$UNIT_FILE"
  systemctl daemon-reload
  rm -rf "$INSTALL_DIR"
  echo "Removed program files. Data preserved at ${DATA_DIR}."
}

purge_all() {
  uninstall_keep_data
  rm -rf "$DATA_DIR"
  echo "Removed data directory: ${DATA_DIR}"
}

show_status() {
  need_cmd systemctl
  systemctl --no-pager status "$SERVICE_NAME" || true
}

interactive_menu() {
  echo "${DISPLAY_NAME} installer"
  echo "1) Install or update"
  echo "2) Uninstall (keep data)"
  echo "3) Purge (remove data)"
  echo "4) Status"
  read -r -p "Choose: " choice
  case "$choice" in
    1)
      read -r -p "Branch main/debug (Enter keeps ${BRANCH}): " input_branch
      BRANCH="${input_branch:-$BRANCH}"
      install_or_update
      ;;
    2) uninstall_keep_data ;;
    3) purge_all ;;
    4) show_status ;;
    *) echo "Cancelled." ;;
  esac
}

if [[ -z "$ACTION" ]]; then
  if [[ -t 0 ]]; then
    ACTION="interactive"
  else
    ACTION="install"
  fi
fi

require_root

case "$ACTION" in
  install) install_or_update ;;
  uninstall) uninstall_keep_data ;;
  purge) purge_all ;;
  status) show_status ;;
  interactive) interactive_menu ;;
  *) usage; exit 1 ;;
esac
