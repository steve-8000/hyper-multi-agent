#!/usr/bin/env bash
# shellcheck disable=SC1090
set -Eeuo pipefail

# =============================================================================
# Hyper Multi-Agent — Installer
#
# Server: HyperAI 앱이 프록시를 관리. 이 스크립트는 Claude Code 플러그인만 설치.
# Client: hyper-mcp + Claude Code 플러그인 설치 (원격 프록시에 연결)
# =============================================================================

VERSION="1.0.0"
REPO="steve-8000/hyper-multi-agent"

# Directories
BASE_DIR="${HOME}/.hyper-multi-agent"
BIN_DIR="${BASE_DIR}/bin"
STATE_FILE="${BASE_DIR}/state.env"

CLAUDE_DIR="${HOME}/.claude"
PLUGIN_NAME="hyper-multi-agent"
PLUGIN_CACHE="${CLAUDE_DIR}/plugins/cache/local/${PLUGIN_NAME}/${VERSION}"
INSTALLED_JSON="${CLAUDE_DIR}/plugins/installed_plugins.json"
SETTINGS_JSON="${CLAUDE_DIR}/settings.json"
MCP_JSON="${CLAUDE_DIR}/mcp.json"

# Colors
R="\033[0;31m" G="\033[0;32m" Y="\033[0;33m" B="\033[0;34m" C="\033[0;36m" W="\033[1;37m" NC="\033[0m"
info()    { echo -e "${B}[INFO]${NC} $*"; }
ok()      { echo -e "${G}  [OK]${NC} $*"; }
warn()    { echo -e "${Y}[WARN]${NC} $*"; }
err()     { echo -e "${R}[ERROR]${NC} $*"; }
header()  { echo -e "${C}$*${NC}"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Globals
INSTALL_MODE=""
PROXY_URL=""
API_KEY=""
OS=""
ARCH=""

# =============================================================================
# Argument parsing
# =============================================================================
ACTION="install"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --server)      INSTALL_MODE="server" ;;
    --client)      INSTALL_MODE="client" ;;
    --uninstall)   ACTION="uninstall" ;;
    --reconfigure) ACTION="reconfigure" ;;
    --help|-h)
      cat <<EOF
Usage: ./install.sh [MODE] [OPTIONS]

Modes:
  --server        Server mode (HyperAI app runs proxy, this installs Claude Code plugin)
  --client        Client mode (connects to remote proxy)
  (no flag)       Interactive mode selection

Options:
  --uninstall     Remove everything
  --reconfigure   Update connection settings
  --help          Show this help
EOF
      exit 0 ;;
    *) err "Unknown option: $1"; exit 1 ;;
  esac
  shift
done

# =============================================================================
# Uninstall
# =============================================================================
[[ "$ACTION" == "uninstall" ]] && {
  echo ""
  header "  Uninstalling Hyper Multi-Agent"
  echo ""
  read -r -p "  Proceed? [y/N]: " confirm
  [[ "$(echo "${confirm:-N}" | tr '[:upper:]' '[:lower:]')" == "y" ]] || { info "Cancelled."; exit 0; }

  rm -rf "$BASE_DIR" "$PLUGIN_CACHE"
  for FILE in "$INSTALLED_JSON" "$SETTINGS_JSON" "$MCP_JSON"; do
    [[ -f "$FILE" ]] && python3 -c "
import json
with open('$FILE') as f: data = json.load(f)
if isinstance(data, dict):
    data.get('plugins',{}).pop('${PLUGIN_NAME}@local', None)
    data.get('enabledPlugins',{}).pop('${PLUGIN_NAME}@local', None)
    data.get('mcpServers',{}).pop('hyper-proxy', None)
    if 'permissions' in data and 'allow' in data['permissions']:
        data['permissions']['allow'] = [x for x in data['permissions']['allow'] if 'hyper-proxy' not in x]
with open('$FILE','w') as f: json.dump(data, f, indent=2)
" 2>/dev/null || true
  done
  ok "Uninstall complete. Restart Claude Code."
  exit 0
}

# =============================================================================
# Platform detection
# =============================================================================
detect_platform() {
  local os arch
  os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  arch="$(uname -m)"
  case "$os" in darwin|linux) ;; *) err "Unsupported OS: $os"; exit 1 ;; esac
  case "$arch" in x86_64|amd64) arch="amd64" ;; arm64|aarch64) arch="arm64" ;; *) err "Unsupported arch: $arch"; exit 1 ;; esac
  OS="$os"; ARCH="$arch"
  ok "Platform: ${OS}-${ARCH}"
}

# =============================================================================
# URL helper
# =============================================================================
normalize_url() {
  local url="$1" default_port="$2"
  [[ "$url" =~ ^https?:// ]] || url="http://${url}"
  echo "$url" | grep -qE ':[0-9]+$' || url="${url}:${default_port}"
  echo "$url"
}

# =============================================================================
# Mode selection
# =============================================================================
select_mode() {
  [[ -n "$INSTALL_MODE" ]] && return

  echo ""
  header "=========================================="
  header "  Hyper Multi-Agent Installer v${VERSION}"
  header "=========================================="
  echo ""
  echo -e "  ${W}Choose installation mode:${NC}"
  echo ""
  echo -e "  ${G}[1] Server${NC} — I'm running HyperAI app on this machine"
  echo "      The app manages all proxy servers."
  echo "      This installs the Claude Code plugin only."
  echo ""
  echo -e "  ${B}[2] Client${NC} — I'm connecting to a remote proxy"
  echo "      Installs: MCP bridge + Claude Code plugin"
  echo ""
  read -r -p "  Select [1/2]: " choice
  case "$choice" in
    1|server|s) INSTALL_MODE="server" ;;
    2|client|c) INSTALL_MODE="client" ;;
    *) INSTALL_MODE="client" ;;
  esac
  echo ""
}

# =============================================================================
# Configuration
# =============================================================================
collect_config() {
  local saved_mode="$INSTALL_MODE"
  [[ -f "$STATE_FILE" ]] && source "$STATE_FILE" 2>/dev/null || true
  INSTALL_MODE="$saved_mode"

  if [[ "$INSTALL_MODE" == "server" ]]; then
    info "Server mode: HyperAI app manages the proxy."
    echo ""
    echo -e "  ${Y}Make sure:${NC}"
    echo "    1. HyperAI app is running"
    echo "    2. Settings > External Access is ON"
    echo ""

    PROXY_URL="http://127.0.0.1:8317"

    # Check if proxy is running
    if curl -fsSm 2 http://127.0.0.1:8317/internal/health >/dev/null 2>&1; then
      ok "Proxy running on port 8317"
    else
      warn "Proxy not responding. Open HyperAI app and click Start."
    fi
    echo ""

  else
    info "Client mode: connecting to a remote proxy server."
    echo ""

    echo -e "  ${C}Proxy Server URL${NC}"
    echo "  Ask your server admin for the IP and port."
    read -r -p "  URL [${PROXY_URL:-}]: " input
    PROXY_URL="$(normalize_url "${input:-${PROXY_URL:-}}" 8317)"
    [[ "$PROXY_URL" == "http://:8317" ]] && { err "Proxy URL is required."; exit 1; }
    echo ""

    echo -e "  ${C}API Key${NC} (optional — leave empty if server has no key)"
    read -r -p "  API Key [${API_KEY:-(none)}]: " input
    API_KEY="${input:-${API_KEY:-}}"
    echo ""
  fi

  # Summary
  header "  Configuration Summary"
  echo "  Mode:       ${INSTALL_MODE}"
  echo "  Proxy URL:  ${PROXY_URL}"
  [[ -n "${API_KEY:-}" ]] && echo "  API Key:    ${API_KEY:0:8}...${API_KEY: -4}"
  echo ""
  read -r -p "  Proceed? [Y/n]: " confirm
  [[ "$(echo "${confirm:-Y}" | tr '[:upper:]' '[:lower:]')" =~ ^y$ ]] || { info "Cancelled."; exit 0; }

  # Save state
  mkdir -p "$BASE_DIR"
  cat > "$STATE_FILE" <<EOF
INSTALL_MODE="${INSTALL_MODE}"
PROXY_URL="${PROXY_URL}"
API_KEY="${API_KEY}"
EOF
  chmod 600 "$STATE_FILE"
}

# =============================================================================
# Binary management (hyper-mcp only)
# =============================================================================
find_binary() {
  local name="$1"
  for p in "${BIN_DIR}/${name}" "/usr/local/bin/${name}" "/opt/homebrew/bin/${name}" "/Applications/HyperAI.app/Contents/Resources/${name}"; do
    [[ -x "$p" ]] && echo "$p" && return 0
  done
  command -v "$name" 2>/dev/null && return 0
  return 1
}

download_binary() {
  local bin="$1"
  local url="https://github.com/${REPO}/releases/latest/download/${bin}-${OS}-${ARCH}"
  local tmpdir
  tmpdir="$(mktemp -d)"
  if curl -fsSL "$url" -o "${tmpdir}/${bin}" 2>/dev/null; then
    cp "${tmpdir}/${bin}" "${BIN_DIR}/${bin}"
    chmod +x "${BIN_DIR}/${bin}"
    ok "Downloaded ${bin}"
  else
    err "Failed to download ${bin} from ${url}"
  fi
  rm -rf "$tmpdir"
}

ensure_hyper_mcp() {
  mkdir -p "$BIN_DIR"
  if [[ -x "${BIN_DIR}/hyper-mcp" ]]; then
    ok "hyper-mcp ready"
  elif found="$(find_binary "hyper-mcp")"; then
    cp "$found" "${BIN_DIR}/hyper-mcp"
    chmod +x "${BIN_DIR}/hyper-mcp"
    ok "hyper-mcp copied from ${found}"
  else
    download_binary "hyper-mcp"
  fi
}

# =============================================================================
# Claude Code plugin + MCP config
# =============================================================================
install_plugin() {
  mkdir -p "$PLUGIN_CACHE"
  for dir in .claude-plugin commands skills; do
    [[ -d "${SCRIPT_DIR}/${dir}" ]] && cp -R "${SCRIPT_DIR}/${dir}" "${PLUGIN_CACHE}/"
  done
  ok "Plugin files installed"
}

configure_claude() {
  local hyper_mcp="${BIN_DIR}/hyper-mcp"
  local timestamp
  timestamp="$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")"
  local MCP_TOOLS='["mcp__hyper-proxy__ask_model","mcp__hyper-proxy__run_consensus","mcp__hyper-proxy__list_models","mcp__hyper-proxy__list_aliases","mcp__hyper-proxy__get_usage","mcp__hyper-proxy__ollama_status","mcp__hyper-proxy__codex_status"]'

  python3 <<PYEOF
import json, os

# --- mcp.json ---
mcp_path = "$MCP_JSON"
os.makedirs(os.path.dirname(mcp_path), exist_ok=True)
try:
    with open(mcp_path) as f: mcp = json.load(f)
except: mcp = {}
mcp.setdefault("mcpServers", {})
mcp_args = ["-proxy-url", "$PROXY_URL"]
api_key = "$API_KEY"
if api_key:
    mcp_args += ["-api-key", api_key]
mcp["mcpServers"]["hyper-proxy"] = {
    "command": "$hyper_mcp",
    "args": mcp_args
}
with open(mcp_path, "w") as f: json.dump(mcp, f, indent=2)

# --- installed_plugins.json ---
ip_path = "$INSTALLED_JSON"
os.makedirs(os.path.dirname(ip_path), exist_ok=True)
try:
    with open(ip_path) as f: ip = json.load(f)
except: ip = {"version": 2, "plugins": {}}
ip.setdefault("version", 2)
ip.setdefault("plugins", {})
ip["plugins"]["${PLUGIN_NAME}@local"] = [{
    "scope": "user",
    "installPath": "$PLUGIN_CACHE",
    "version": "$VERSION",
    "installedAt": "$timestamp",
    "lastUpdated": "$timestamp"
}]
with open(ip_path, "w") as f: json.dump(ip, f, indent=2)

# --- settings.json ---
st_path = "$SETTINGS_JSON"
try:
    with open(st_path) as f: st = json.load(f)
except: st = {}
st.setdefault("enabledPlugins", {})
st["enabledPlugins"]["${PLUGIN_NAME}@local"] = True
st.setdefault("permissions", {}).setdefault("allow", [])
for t in $MCP_TOOLS:
    if t not in st["permissions"]["allow"]:
        st["permissions"]["allow"].append(t)
with open(st_path, "w") as f: json.dump(st, f, indent=2)
PYEOF

  ok "mcp.json configured (proxy: ${PROXY_URL})"
  ok "Plugin registered & enabled"
  ok "MCP permissions granted"
}

# =============================================================================
# Verification
# =============================================================================
verify() {
  local errors=0
  check_exists() {
    local path="$1" label="$2"
    if [[ -e "$path" ]]; then ok "$label"; else err "Missing: $label ($path)"; errors=$((errors+1)); fi
  }

  check_exists "${BIN_DIR}/hyper-mcp" "hyper-mcp binary"
  check_exists "${PLUGIN_CACHE}/.claude-plugin/plugin.json" "Plugin files"
  check_exists "${MCP_JSON}" "mcp.json"

  # Proxy connectivity
  local auth_header=""
  [[ -n "${API_KEY:-}" ]] && auth_header="-H Authorization: Bearer ${API_KEY}"
  if curl -fsSm 3 ${auth_header} "${PROXY_URL}/v1/models" >/dev/null 2>&1; then
    ok "Proxy reachable at ${PROXY_URL}"
  elif curl -fsSm 3 ${auth_header} "${PROXY_URL}/internal/health" >/dev/null 2>&1; then
    ok "Proxy reachable at ${PROXY_URL}"
  else
    if [[ "$INSTALL_MODE" == "server" ]]; then
      warn "Proxy not responding — open HyperAI app and start the server"
    else
      warn "Proxy not reachable at ${PROXY_URL} — check server is running"
    fi
  fi

  return $errors
}

# =============================================================================
# Main
# =============================================================================
main() {
  echo ""
  header "=========================================="
  header "  Hyper Multi-Agent Installer v${VERSION}"
  header "=========================================="

  select_mode

  info "[1/3] Preflight"
  command -v python3 >/dev/null || { err "python3 required"; exit 1; }
  command -v curl >/dev/null || { err "curl required"; exit 1; }
  detect_platform
  echo ""

  info "[2/3] Configuration"
  collect_config
  echo ""

  info "[3/3] Claude Code plugin"
  ensure_hyper_mcp
  install_plugin
  configure_claude
  echo ""

  info "Verification"
  verify || true

  echo ""
  header "=========================================="
  header "  Installation Complete! (${INSTALL_MODE} mode)"
  header "=========================================="
  echo ""

  if [[ "$INSTALL_MODE" == "server" ]]; then
    echo "  Proxy is managed by HyperAI app."
    echo ""
    echo -e "  ${W}Share with team members:${NC}"
    local external_ip
    external_ip="$(curl -fsSm 3 https://ifconfig.me 2>/dev/null || echo '<your-server-ip>')"
    echo "    Proxy URL: http://${external_ip}:8317"
    echo "    API Key:   (from HyperAI app Settings > External Access)"
    echo "    Install:   git clone https://github.com/${REPO}.git && cd hyper-multi-agent && ./install.sh --client"
  else
    echo "  Proxy URL:  ${PROXY_URL}"
    [[ -n "${API_KEY:-}" ]] && echo "  API Key:    ${API_KEY:0:8}...${API_KEY: -4}"
    echo ""
    echo "  Ready to use! Just restart Claude Code."
  fi

  echo ""
  echo "  Claude Code commands (after restart):"
  echo "    /hyper-dev <task>      Multi-agent parallel development"
  echo "    /hyper-review <file>   Deep architecture review"
  echo ""
  echo -e "  ${Y}Restart Claude Code to load the plugin.${NC}"
  echo ""
}

# Reconfigure shortcut
[[ "$ACTION" == "reconfigure" ]] && {
  detect_platform
  [[ -f "$STATE_FILE" ]] && source "$STATE_FILE" 2>/dev/null || true
  [[ -z "$INSTALL_MODE" ]] && select_mode
  collect_config
  configure_claude
  ok "Reconfiguration complete. Restart Claude Code."
  exit 0
}

main
