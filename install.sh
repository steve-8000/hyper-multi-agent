#!/usr/bin/env bash
set -Eeuo pipefail

# =============================================================================
# Hyper Multi-Agent — One-Click Installer
# Sets up proxy server, MCP bridge, and Claude Code plugin from scratch.
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
R="\033[0;31m" G="\033[0;32m" Y="\033[0;33m" B="\033[0;34m" C="\033[0;36m" NC="\033[0m"
info()    { echo -e "${B}[INFO]${NC} $*"; }
ok()      { echo -e "${G}[OK]${NC} $*"; }
warn()    { echo -e "${Y}[WARN]${NC} $*"; }
err()     { echo -e "${R}[ERROR]${NC} $*"; }
header()  { echo -e "\n${C}$*${NC}"; }

# Detect script directory (plugin source files)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# =============================================================================
# Argument parsing
# =============================================================================
ACTION="install"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --uninstall)   ACTION="uninstall" ;;
    --reconfigure) ACTION="reconfigure" ;;
    --help|-h)
      echo "Usage: ./install.sh [--uninstall] [--reconfigure] [--help]"
      exit 0 ;;
    *) err "Unknown option: $1"; exit 1 ;;
  esac
  shift
done

# =============================================================================
# Uninstall
# =============================================================================
do_uninstall() {
  header "=========================================="
  header "  Uninstalling Hyper Multi-Agent"
  header "=========================================="
  echo ""
  warn "This will remove:"
  echo "  - ${BASE_DIR} (binaries, config, logs)"
  echo "  - ${PLUGIN_CACHE} (plugin files)"
  echo "  - Claude Code registrations"
  echo ""
  read -r -p "Proceed? [y/N]: " confirm
  [[ "${confirm,,}" == "y" ]] || { info "Cancelled."; exit 0; }

  # Kill proxy if running
  for pf in "${PID_DIR}"/*.pid; do
    [[ -f "$pf" ]] && kill "$(cat "$pf")" 2>/dev/null || true
  done

  rm -rf "$BASE_DIR" "$PLUGIN_CACHE"

  # Clean JSON configs
  for target in installed_json settings_json mcp_json; do
    case "$target" in
      installed_json) FILE="$INSTALLED_JSON" ;;
      settings_json)  FILE="$SETTINGS_JSON" ;;
      mcp_json)       FILE="$MCP_JSON" ;;
    esac
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

[[ "$ACTION" == "uninstall" ]] && do_uninstall

# =============================================================================
# Platform detection
# =============================================================================
detect_platform() {
  local os arch
  os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  arch="$(uname -m)"
  case "$os" in
    darwin|linux) ;;
    *) err "Unsupported OS: $os"; exit 1 ;;
  esac
  case "$arch" in
    x86_64|amd64) arch="amd64" ;;
    arm64|aarch64) arch="arm64" ;;
    *) err "Unsupported arch: $arch"; exit 1 ;;
  esac
  OS="$os"; ARCH="$arch"
  ok "Platform: ${OS}-${ARCH}"
}

# =============================================================================
# Interactive config
# =============================================================================
collect_config() {
  # Load existing state if reconfiguring
  [[ -f "$STATE_FILE" ]] && source "$STATE_FILE" 2>/dev/null || true

  header "=========================================="
  header "  Hyper Multi-Agent Installer v${VERSION}"
  header "=========================================="
  echo ""
  info "Configure your connection settings."
  info "Press Enter to accept defaults shown in brackets."
  echo ""

  # Proxy URL
  echo -e "  ${C}Proxy Server URL${NC}"
  echo "  The Hyper-Proxy server that routes requests to AI models."
  echo "  Local:  http://127.0.0.1:8317"
  echo "  Remote: http://<server-ip>:8317"
  read -r -p "  URL [${PROXY_URL:-http://127.0.0.1:8317}]: " input
  PROXY_URL="${input:-${PROXY_URL:-http://127.0.0.1:8317}}"
  echo ""

  # Ollama URL
  echo -e "  ${C}Ollama Server URL${NC} (for local models like coder-fast)"
  echo "  Skip if not using local models."
  read -r -p "  URL [${OLLAMA_URL:-http://localhost:11434}]: " input
  OLLAMA_URL="${input:-${OLLAMA_URL:-http://localhost:11434}}"
  echo ""

  # API Key
  local host
  host="$(python3 -c "from urllib.parse import urlparse; print(urlparse('$PROXY_URL').hostname or '')" 2>/dev/null || echo "")"
  local is_local=false
  case "$host" in localhost|127.*|::1|0.0.0.0|"") is_local=true ;; esac

  echo -e "  ${C}API Key${NC} for proxy authentication"
  if [[ "$is_local" == "true" ]]; then
    echo "  Optional for local proxy. Required for external access."
    read -r -p "  API Key [${API_KEY:-(none)}]: " input
    API_KEY="${input:-${API_KEY:-}}"
  else
    echo "  Required for remote proxy access."
    while true; do
      read -r -p "  API Key [${API_KEY:-}]: " input
      API_KEY="${input:-${API_KEY:-}}"
      [[ -n "$API_KEY" ]] && break
      warn "API key is required for remote proxy."
    done
  fi
  echo ""

  # Summary
  header "  Configuration Summary"
  echo "  Proxy URL:  $PROXY_URL"
  echo "  Ollama URL: $OLLAMA_URL"
  echo "  API Key:    ${API_KEY:+[set]}${API_KEY:-[not set]}"
  echo ""
  read -r -p "  Proceed with installation? [Y/n]: " confirm
  confirm="${confirm:-Y}"
  [[ "${confirm,,}" =~ ^y$ ]] || { info "Cancelled."; exit 0; }

  # Save state (private, never in repo)
  mkdir -p "$BASE_DIR"
  cat > "$STATE_FILE" <<EOF
PROXY_URL="${PROXY_URL}"
OLLAMA_URL="${OLLAMA_URL}"
API_KEY="${API_KEY}"
EOF
  chmod 600 "$STATE_FILE"
}

# =============================================================================
# Binary management
# =============================================================================
BINARIES=("hyper-mcp" "hyper-ai-proxy" "cli-proxy-api-plus")

find_binary() {
  local name="$1"
  local paths=(
    "${BIN_DIR}/${name}"
    "/usr/local/bin/${name}"
    "/opt/homebrew/bin/${name}"
    "/Applications/HyperAI.app/Contents/Resources/${name}"
  )
  for p in "${paths[@]}"; do
    [[ -x "$p" ]] && echo "$p" && return 0
  done
  command -v "$name" 2>/dev/null && return 0
  return 1
}

ensure_binaries() {
  mkdir -p "$BIN_DIR"
  local missing=()

  for bin in "${BINARIES[@]}"; do
    if [[ -x "${BIN_DIR}/${bin}" ]]; then
      ok "${bin} found in ${BIN_DIR}"
    elif found="$(find_binary "$bin")"; then
      cp "$found" "${BIN_DIR}/${bin}"
      chmod +x "${BIN_DIR}/${bin}"
      ok "${bin} copied from ${found}"
    else
      missing+=("$bin")
    fi
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    info "Downloading missing binaries: ${missing[*]}"
    local tmpdir
    tmpdir="$(mktemp -d)"

    for bin in "${missing[@]}"; do
      local urls=(
        "https://github.com/${REPO}/releases/latest/download/${bin}-${OS}-${ARCH}"
        "https://github.com/${REPO}/releases/latest/download/${bin}-${OS}-${ARCH}.tar.gz"
        "https://github.com/${REPO}/releases/latest/download/${bin}_${OS}_${ARCH}"
      )
      local downloaded=false
      for url in "${urls[@]}"; do
        if curl -fsSL "$url" -o "${tmpdir}/${bin}.dl" 2>/dev/null; then
          # Check if it's an archive
          if file "${tmpdir}/${bin}.dl" | grep -qiE "gzip|tar|zip"; then
            mkdir -p "${tmpdir}/extract"
            tar -xzf "${tmpdir}/${bin}.dl" -C "${tmpdir}/extract" 2>/dev/null || continue
            local found_bin
            found_bin="$(find "${tmpdir}/extract" -name "$bin" -type f | head -1)"
            [[ -n "$found_bin" ]] && cp "$found_bin" "${BIN_DIR}/${bin}"
          else
            cp "${tmpdir}/${bin}.dl" "${BIN_DIR}/${bin}"
          fi
          chmod +x "${BIN_DIR}/${bin}"
          ok "Downloaded ${bin}"
          downloaded=true
          break
        fi
      done
      [[ "$downloaded" == "false" ]] && err "Failed to download ${bin}. Add it manually to ${BIN_DIR}/"
    done
    rm -rf "$tmpdir"
  fi
}

# =============================================================================
# Proxy server scripts
# =============================================================================
generate_proxy_scripts() {
  mkdir -p "$LOG_DIR" "$PID_DIR"

  # --- start-proxy.sh ---
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
      BACKEND_ARGS=()
      [[ -n "${API_KEY:-}" ]] && BACKEND_ARGS+=("-api-key" "$API_KEY")
      nohup "${BIN}/cli-proxy-api-plus" "${BACKEND_ARGS[@]}" >> "${LOG}/backend.log" 2>&1 &
      echo $! > "${PID}/backend.pid"
      echo "[OK] Backend started (PID $!)"
    fi
    sleep 1

    # Frontend (hyper-ai-proxy on 8317)
    if [[ -f "${PID}/frontend.pid" ]] && kill -0 "$(cat "${PID}/frontend.pid")" 2>/dev/null; then
      echo "[WARN] Frontend already running (PID $(cat "${PID}/frontend.pid"))"
    else
      FRONTEND_ARGS=("-port" "8317")
      [[ -n "${API_KEY:-}" ]] && FRONTEND_ARGS+=("-external-access" "-api-key" "$API_KEY" "-bind" "0.0.0.0")
      [[ -n "${OLLAMA_URL:-}" ]] && FRONTEND_ARGS+=("-ollama-enabled" "-ollama-url" "$OLLAMA_URL")
      nohup "${BIN}/hyper-ai-proxy" "${FRONTEND_ARGS[@]}" >> "${LOG}/frontend.log" 2>&1 &
      echo $! > "${PID}/frontend.pid"
      echo "[OK] Frontend started (PID $!)"
    fi

    echo ""
    echo "Proxy running:"
    echo "  Backend:  http://127.0.0.1:8318"
    echo "  Frontend: http://0.0.0.0:8317"
    echo "  Logs:     ${LOG}/"
    ;;
  stop)
    for svc in backend frontend; do
      if [[ -f "${PID}/${svc}.pid" ]]; then
        kill "$(cat "${PID}/${svc}.pid")" 2>/dev/null && echo "[OK] ${svc} stopped" || echo "[INFO] ${svc} not running"
        rm -f "${PID}/${svc}.pid"
      fi
    done
    ;;
  restart)
    "$0" stop; sleep 1; "$0" start ;;
  status)
    for svc in backend frontend; do
      if [[ -f "${PID}/${svc}.pid" ]] && kill -0 "$(cat "${PID}/${svc}.pid")" 2>/dev/null; then
        echo "[RUNNING] ${svc} (PID $(cat "${PID}/${svc}.pid"))"
      else
        echo "[STOPPED] ${svc}"
      fi
    done
    ;;
  *) echo "Usage: $0 {start|stop|restart|status}" ;;
esac
STARTEOF
  chmod +x "${BASE_DIR}/start-proxy.sh"
  ok "Generated ${BASE_DIR}/start-proxy.sh"
}

# =============================================================================
# Claude Code plugin setup
# =============================================================================
install_plugin() {
  mkdir -p "$PLUGIN_CACHE"

  # Copy plugin source files (commands, skills, .claude-plugin)
  for dir in .claude-plugin commands skills; do
    if [[ -d "${SCRIPT_DIR}/${dir}" ]]; then
      cp -R "${SCRIPT_DIR}/${dir}" "${PLUGIN_CACHE}/"
    fi
  done
  ok "Plugin files -> ${PLUGIN_CACHE}"
}

configure_claude() {
  local hyper_mcp="${BIN_DIR}/hyper-mcp"
  local timestamp
  timestamp="$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")"

  local MCP_TOOLS='["mcp__hyper-proxy__ask_model","mcp__hyper-proxy__run_consensus","mcp__hyper-proxy__list_models","mcp__hyper-proxy__list_aliases","mcp__hyper-proxy__get_usage","mcp__hyper-proxy__ollama_status","mcp__hyper-proxy__codex_status"]'

  # All JSON updates in one python3 call
  python3 <<PYEOF
import json, os

# --- mcp.json ---
mcp_path = "$MCP_JSON"
os.makedirs(os.path.dirname(mcp_path), exist_ok=True)
try:
    with open(mcp_path) as f: mcp = json.load(f)
except: mcp = {}
mcp.setdefault("mcpServers", {})
args = ["-proxy-url", "$PROXY_URL", "-ollama-url", "$OLLAMA_URL"]
mcp["mcpServers"]["hyper-proxy"] = {"command": "$hyper_mcp", "args": args}
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
tools = $MCP_TOOLS
for t in tools:
    if t not in st["permissions"]["allow"]:
        st["permissions"]["allow"].append(t)
with open(st_path, "w") as f: json.dump(st, f, indent=2)
PYEOF

  ok "mcp.json configured"
  ok "Plugin registered & enabled"
  ok "MCP permissions granted"
}

# =============================================================================
# Verification
# =============================================================================
verify() {
  local errors=0
  local checks=(
    "${BIN_DIR}/hyper-mcp"
    "${BIN_DIR}/hyper-ai-proxy"
    "${BIN_DIR}/cli-proxy-api-plus"
    "${PLUGIN_CACHE}/.claude-plugin/plugin.json"
    "${MCP_JSON}"
    "${BASE_DIR}/start-proxy.sh"
  )
  for f in "${checks[@]}"; do
    if [[ -e "$f" ]]; then
      ok "$(basename "$f")"
    else
      err "Missing: $f"; errors=$((errors+1))
    fi
  done

  # Test proxy connectivity (best effort)
  if curl -fsSm 2 "${PROXY_URL}" >/dev/null 2>&1 || curl -fsSm 2 "${PROXY_URL}/health" >/dev/null 2>&1; then
    ok "Proxy reachable at ${PROXY_URL}"
  else
    warn "Proxy not reachable at ${PROXY_URL} — start it with: ~/.hyper-multi-agent/start-proxy.sh"
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
  header "  Multi-model parallel orchestration"
  header "=========================================="

  info "[1/6] Preflight"
  command -v python3 >/dev/null || { err "python3 required"; exit 1; }
  command -v curl >/dev/null || { err "curl required"; exit 1; }
  detect_platform

  info "[2/6] Configuration"
  collect_config

  info "[3/6] Binaries"
  ensure_binaries

  info "[4/6] Proxy server scripts"
  generate_proxy_scripts

  info "[5/6] Claude Code plugin"
  install_plugin
  configure_claude

  info "[6/6] Verification"
  verify || true

  echo ""
  header "=========================================="
  header "  Installation Complete!"
  header "=========================================="
  echo ""
  echo "  Base directory:  ${BASE_DIR}"
  echo "  Proxy URL:       ${PROXY_URL}"
  echo "  Ollama URL:      ${OLLAMA_URL}"
  echo "  API Key:         ${API_KEY:+[configured]}${API_KEY:-[not set]}"
  echo ""
  echo "  Start proxy server:"
  echo "    ~/.hyper-multi-agent/start-proxy.sh start"
  echo ""
  echo "  Stop proxy server:"
  echo "    ~/.hyper-multi-agent/start-proxy.sh stop"
  echo ""
  echo "  Claude Code commands (after restart):"
  echo "    /hyper-dev <task>      Multi-agent parallel development"
  echo "    /hyper-review <file>   Deep architecture review"
  echo ""
  echo -e "  ${Y}Restart Claude Code to load the plugin.${NC}"
  echo ""
}

[[ "$ACTION" == "reconfigure" ]] && {
  detect_platform
  collect_config
  configure_claude
  generate_proxy_scripts
  ok "Reconfiguration complete. Restart Claude Code."
  exit 0
}

main
