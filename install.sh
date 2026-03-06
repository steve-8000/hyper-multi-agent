#!/usr/bin/env bash
# shellcheck disable=SC1090
set -Eeuo pipefail

# =============================================================================
# Hyper Multi-Agent — One-Click Installer
#
# Two modes:
#   Server Mode: Runs proxy + installs plugin (the host machine)
#   Client Mode: Installs hyper-mcp + plugin only (connects to remote proxy)
# =============================================================================

VERSION="1.0.0"
REPO="steve-8000/hyper-multi-agent"

# Directories
BASE_DIR="${HOME}/.hyper-multi-agent"
BIN_DIR="${BASE_DIR}/bin"
LOG_DIR="${BASE_DIR}/logs"
PID_DIR="${BASE_DIR}/pids"
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
INSTALL_MODE=""  # server or client
PROXY_URL=""
OLLAMA_URL=""
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
  --server        Install proxy server + plugin (host machine)
  --client        Install plugin only (connects to remote proxy)
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
  warn "This will remove:"
  echo "  - ${BASE_DIR}"
  echo "  - ${PLUGIN_CACHE}"
  echo "  - Claude Code registrations"
  echo ""
  read -r -p "  Proceed? [y/N]: " confirm
  [[ "$(echo "${confirm:-N}" | tr '[:upper:]' '[:lower:]')" == "y" ]] || { info "Cancelled."; exit 0; }

  # Kill proxy
  for pf in "${PID_DIR}"/*.pid; do
    [[ -f "$pf" ]] && kill "$(cat "$pf")" 2>/dev/null || true
  done
  rm -rf "$BASE_DIR" "$PLUGIN_CACHE"

  # Clean JSON configs
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
  echo -e "  ${G}[1] Server${NC} — I'm running the proxy on this machine"
  echo "      Installs: proxy server + MCP bridge + Claude Code plugin"
  echo "      For: the host machine that serves AI model requests"
  echo ""
  echo -e "  ${B}[2] Client${NC} — I'm connecting to an existing proxy server"
  echo "      Installs: MCP bridge + Claude Code plugin only"
  echo "      For: anyone who wants to use a remote proxy"
  echo ""
  read -r -p "  Select [1/2]: " choice
  case "$choice" in
    1|server|s) INSTALL_MODE="server" ;;
    2|client|c) INSTALL_MODE="client" ;;
    *) INSTALL_MODE="client" ;;  # default to client (most common)
  esac
  echo ""
}

# =============================================================================
# Interactive config
# =============================================================================
collect_config() {
  # Load previous values for defaults, but preserve current INSTALL_MODE
  local saved_mode="$INSTALL_MODE"
  [[ -f "$STATE_FILE" ]] && source "$STATE_FILE" 2>/dev/null || true
  INSTALL_MODE="$saved_mode"

  if [[ "$INSTALL_MODE" == "server" ]]; then
    info "Server mode: proxy will run on this machine."
    echo ""

    # Ollama URL (server might have local ollama)
    echo -e "  ${C}Ollama Server URL${NC} (for Hyper-AI(Low) local models)"
    read -r -p "  URL [${OLLAMA_URL:-http://localhost:11434}]: " input
    OLLAMA_URL="$(normalize_url "${input:-${OLLAMA_URL:-http://localhost:11434}}" 11434)"
    echo ""

    # API Key for external access
    echo -e "  ${C}API Key${NC} for client authentication"
    echo "  Clients will use this key to connect to your proxy."
    read -r -p "  API Key [${API_KEY:-(auto-generate)}]: " input
    if [[ -n "$input" ]]; then
      API_KEY="$input"
    elif [[ -z "${API_KEY:-}" ]]; then
      API_KEY="hyper-$(LC_ALL=C tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 32)"
      info "Auto-generated API key"
    fi
    echo ""

    PROXY_URL="http://127.0.0.1:8317"

  else
    info "Client mode: connecting to a remote proxy server."
    echo ""

    # Proxy URL (remote server)
    echo -e "  ${C}Proxy Server URL${NC}"
    echo "  Ask your server admin for the IP and port."
    echo "  Example: http://203.0.113.50:8317 or just 203.0.113.50"
    read -r -p "  URL [${PROXY_URL:-}]: " input
    PROXY_URL="$(normalize_url "${input:-${PROXY_URL:-}}" 8317)"
    [[ "$PROXY_URL" == "http://:8317" ]] && { err "Proxy URL is required."; exit 1; }
    echo ""

    # Client doesn't need Ollama URL — proxy handles all models including local Ollama
    OLLAMA_URL=""

    # API Key (required for client)
    echo -e "  ${C}API Key${NC} (ask your server admin)"
    while true; do
      read -r -p "  API Key [${API_KEY:-}]: " input
      API_KEY="${input:-${API_KEY:-}}"
      [[ -n "$API_KEY" ]] && break
      warn "API key is required to connect to the proxy."
    done
    echo ""
  fi

  # Summary
  header "  Configuration Summary"
  echo "  Mode:       ${INSTALL_MODE}"
  echo "  Proxy URL:  ${PROXY_URL}"
  echo "  Ollama URL: ${OLLAMA_URL}"
  if [[ -n "${API_KEY:-}" ]]; then
    echo "  API Key:    ${API_KEY:0:8}...${API_KEY: -4}"
  fi
  echo ""
  read -r -p "  Proceed? [Y/n]: " confirm
  [[ "$(echo "${confirm:-Y}" | tr '[:upper:]' '[:lower:]')" =~ ^y$ ]] || { info "Cancelled."; exit 0; }

  # Save state
  mkdir -p "$BASE_DIR"
  cat > "$STATE_FILE" <<EOF
INSTALL_MODE="${INSTALL_MODE}"
PROXY_URL="${PROXY_URL}"
OLLAMA_URL="${OLLAMA_URL}"
API_KEY="${API_KEY}"
EOF
  chmod 600 "$STATE_FILE"
}

# =============================================================================
# Binary management
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
  local tmpdir
  tmpdir="$(mktemp -d)"
  local url="https://github.com/${REPO}/releases/latest/download/${bin}-${OS}-${ARCH}"

  if curl -fsSL "$url" -o "${tmpdir}/${bin}" 2>/dev/null; then
    cp "${tmpdir}/${bin}" "${BIN_DIR}/${bin}"
    chmod +x "${BIN_DIR}/${bin}"
    ok "Downloaded ${bin}"
  else
    err "Failed to download ${bin} from ${url}"
    err "Add it manually to ${BIN_DIR}/"
  fi
  rm -rf "$tmpdir"
}

ensure_binary() {
  local bin="$1"
  if [[ -x "${BIN_DIR}/${bin}" ]]; then
    ok "${bin} ready"
  elif found="$(find_binary "$bin")"; then
    cp "$found" "${BIN_DIR}/${bin}"
    chmod +x "${BIN_DIR}/${bin}"
    ok "${bin} copied from ${found}"
  else
    download_binary "$bin"
  fi
}

ensure_binaries() {
  mkdir -p "$BIN_DIR"

  # hyper-mcp is always needed (MCP bridge for Claude Code)
  ensure_binary "hyper-mcp"

  # Server mode: also need proxy binaries
  if [[ "$INSTALL_MODE" == "server" ]]; then
    ensure_binary "hyper-ai-proxy"
    ensure_binary "cli-proxy-api-plus"
  fi
}

# =============================================================================
# Proxy server scripts (server mode only)
# =============================================================================
generate_proxy_scripts() {
  [[ "$INSTALL_MODE" != "server" ]] && return
  mkdir -p "$LOG_DIR" "$PID_DIR"

  cat > "${BASE_DIR}/start-proxy.sh" <<'STARTEOF'
#!/usr/bin/env bash
set -euo pipefail
BASE="${HOME}/.hyper-multi-agent"
source "${BASE}/state.env" 2>/dev/null || true
BIN="${BASE}/bin"; LOG="${BASE}/logs"; PID="${BASE}/pids"
mkdir -p "$LOG" "$PID"

case "${1:-start}" in
  start)
    # Backend (cli-proxy-api-plus on 8318)
    if [[ -f "${PID}/backend.pid" ]] && kill -0 "$(cat "${PID}/backend.pid")" 2>/dev/null; then
      echo "[WARN] Backend already running (PID $(cat "${PID}/backend.pid"))"
    else
      CONFIG="${HOME}/.cli-proxy-api/merged-config.yaml"
      [[ ! -f "$CONFIG" ]] && CONFIG=""
      nohup "${BIN}/cli-proxy-api-plus" ${CONFIG:+-config "$CONFIG"} >> "${LOG}/backend.log" 2>&1 &
      echo $! > "${PID}/backend.pid"
      echo "[OK] Backend started (PID $!)"
    fi
    sleep 1
    # Frontend (hyper-ai-proxy on 8317)
    if [[ -f "${PID}/frontend.pid" ]] && kill -0 "$(cat "${PID}/frontend.pid")" 2>/dev/null; then
      echo "[WARN] Frontend already running (PID $(cat "${PID}/frontend.pid"))"
    else
      ARGS=("-port" "8317")
      [[ -n "${API_KEY:-}" ]] && ARGS+=("-external-access" "-api-key" "$API_KEY" "-bind" "0.0.0.0")
      [[ -n "${OLLAMA_URL:-}" ]] && ARGS+=("-ollama-enabled" "-ollama-url" "$OLLAMA_URL")
      nohup "${BIN}/hyper-ai-proxy" "${ARGS[@]}" >> "${LOG}/frontend.log" 2>&1 &
      echo $! > "${PID}/frontend.pid"
      echo "[OK] Frontend started (PID $!)"
    fi
    echo ""
    echo "Proxy running on port 8317 (external access: ${API_KEY:+enabled}${API_KEY:-disabled})"
    echo "Logs: ${LOG}/"
    ;;
  stop)
    for svc in backend frontend; do
      [[ -f "${PID}/${svc}.pid" ]] && {
        kill "$(cat "${PID}/${svc}.pid")" 2>/dev/null && echo "[OK] ${svc} stopped" || echo "[INFO] ${svc} not running"
        rm -f "${PID}/${svc}.pid"
      }
    done ;;
  restart) "$0" stop; sleep 1; "$0" start ;;
  status)
    for svc in backend frontend; do
      if [[ -f "${PID}/${svc}.pid" ]] && kill -0 "$(cat "${PID}/${svc}.pid")" 2>/dev/null; then
        echo "[RUNNING] ${svc} (PID $(cat "${PID}/${svc}.pid"))"
      else echo "[STOPPED] ${svc}"; fi
    done ;;
  *) echo "Usage: $0 {start|stop|restart|status}" ;;
esac
STARTEOF
  chmod +x "${BASE_DIR}/start-proxy.sh"
  ok "Generated start-proxy.sh"
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
else:
    mcp_args += ["-ollama-url", "$OLLAMA_URL"]
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

  # Check a file/binary exists
  check_exists() {
    local path="$1" label="$2"
    if [[ -e "$path" ]]; then ok "$label"; else err "Missing: $label ($path)"; errors=$((errors+1)); fi
  }

  # hyper-mcp always required
  check_exists "${BIN_DIR}/hyper-mcp" "hyper-mcp binary"

  # Server mode: check proxy binaries
  if [[ "$INSTALL_MODE" == "server" ]]; then
    check_exists "${BIN_DIR}/hyper-ai-proxy" "hyper-ai-proxy binary"
    check_exists "${BIN_DIR}/cli-proxy-api-plus" "cli-proxy-api-plus binary"
    check_exists "${BASE_DIR}/start-proxy.sh" "start-proxy.sh"
  fi

  # Plugin + config
  check_exists "${PLUGIN_CACHE}/.claude-plugin/plugin.json" "Plugin files"
  check_exists "${MCP_JSON}" "mcp.json"

  # Connectivity test
  if curl -fsSm 3 "${PROXY_URL}" >/dev/null 2>&1 || curl -fsSm 3 "${PROXY_URL}/health" >/dev/null 2>&1; then
    ok "Proxy reachable at ${PROXY_URL}"
  else
    if [[ "$INSTALL_MODE" == "server" ]]; then
      warn "Proxy not running yet — start with: ~/.hyper-multi-agent/start-proxy.sh start"
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

  # Step 1: Mode + Preflight
  select_mode
  local total_steps=4
  [[ "$INSTALL_MODE" == "server" ]] && total_steps=5

  info "[1/${total_steps}] Preflight"
  command -v python3 >/dev/null || { err "python3 required"; exit 1; }
  command -v curl >/dev/null || { err "curl required"; exit 1; }
  detect_platform
  echo ""

  # Step 2: Config
  info "[2/${total_steps}] Configuration"
  collect_config
  echo ""

  # Step 3: Binaries
  info "[3/${total_steps}] Binaries"
  ensure_binaries
  echo ""

  # Step 4 (server only): Proxy scripts
  if [[ "$INSTALL_MODE" == "server" ]]; then
    info "[4/${total_steps}] Proxy server"
    generate_proxy_scripts
    echo ""
  fi

  # Plugin step
  local plugin_step=$((total_steps - 0))
  [[ "$INSTALL_MODE" == "server" ]] && plugin_step=$((total_steps - 1))
  info "[${plugin_step}/${total_steps}] Claude Code plugin"
  install_plugin
  configure_claude
  echo ""

  # Step N: Verify — skip numbering, just verify
  info "Verification"
  verify || true

  # Summary
  echo ""
  header "=========================================="
  header "  Installation Complete! (${INSTALL_MODE} mode)"
  header "=========================================="
  echo ""
  echo "  Proxy URL:  ${PROXY_URL}"
  echo "  Ollama URL: ${OLLAMA_URL}"
  echo "  API Key:    ${API_KEY:0:8}...${API_KEY: -4}"
  echo ""

  if [[ "$INSTALL_MODE" == "server" ]]; then
    echo -e "  ${W}Start the proxy server:${NC}"
    echo "    ~/.hyper-multi-agent/start-proxy.sh start"
    echo ""
    echo -e "  ${W}Share with team members:${NC}"
    local external_ip
    external_ip="$(curl -fsSm 3 https://ifconfig.me 2>/dev/null || echo '<your-server-ip>')"
    echo "    Proxy URL: http://${external_ip}:8317"
    echo "    API Key:   ${API_KEY}"
    echo "    Install:   git clone https://github.com/${REPO}.git && cd hyper-multi-agent && ./install.sh --client"
  else
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
  [[ "$INSTALL_MODE" == "server" ]] && generate_proxy_scripts
  ok "Reconfiguration complete. Restart Claude Code."
  exit 0
}

main
