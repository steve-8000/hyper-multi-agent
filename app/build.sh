#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GO_DIR="${SCRIPT_DIR}/go-proxy"
SWIFT_DIR="${SCRIPT_DIR}"
OUTPUT_DIR="${SCRIPT_DIR}/build"

R="\033[0;31m" G="\033[0;32m" Y="\033[0;33m" C="\033[0;36m" NC="\033[0m"
info() { echo -e "${C}[BUILD]${NC} $*"; }
ok()   { echo -e "${G}  [OK]${NC} $*"; }
err()  { echo -e "${R}[ERROR]${NC} $*"; }

# =============================================================================
# Parse arguments
# =============================================================================
BUILD_TARGET="${1:-all}"  # all, go, swift, app
RELEASE_MODE="${2:-release}"  # release, debug

case "$BUILD_TARGET" in
  all|go|swift|app) ;;
  *) echo "Usage: $0 [all|go|swift|app] [release|debug]"; exit 1 ;;
esac

mkdir -p "$OUTPUT_DIR"

# =============================================================================
# Build Go binaries
# =============================================================================
build_go() {
  info "Building Go binaries..."
  cd "$GO_DIR"

  local os arch
  os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  arch="$(uname -m)"
  case "$arch" in x86_64|amd64) arch="amd64" ;; arm64|aarch64) arch="arm64" ;; esac

  # hyper-ai-proxy
  GOOS="$os" GOARCH="$arch" go build -o "${OUTPUT_DIR}/hyper-ai-proxy" ./cmd/hyper-ai-proxy/
  ok "hyper-ai-proxy"

  # hyper-mcp
  GOOS="$os" GOARCH="$arch" go build -o "${OUTPUT_DIR}/hyper-mcp" ./cmd/hyper-mcp/
  ok "hyper-mcp"
}

# Cross-compile Go binaries for all platforms (for GitHub releases)
build_go_all() {
  info "Cross-compiling Go binaries for all platforms..."
  cd "$GO_DIR"

  for bin in hyper-ai-proxy hyper-mcp; do
    for platform in darwin-arm64 darwin-amd64 linux-amd64 linux-arm64; do
      local os="${platform%-*}"
      local arch="${platform#*-}"
      GOOS="$os" GOARCH="$arch" go build -o "${OUTPUT_DIR}/${bin}-${platform}" "./cmd/${bin}/"
      ok "${bin}-${platform}"
    done
  done
}

# =============================================================================
# Build Swift app
# =============================================================================
build_swift() {
  info "Building HyperAI.app..."
  cd "$SWIFT_DIR"

  # Copy Go binaries into app resources before building
  local resources="${SWIFT_DIR}/Sources/Resources"
  mkdir -p "$resources"

  if [[ -f "${OUTPUT_DIR}/hyper-ai-proxy" ]]; then
    cp "${OUTPUT_DIR}/hyper-ai-proxy" "$resources/"
    cp "${OUTPUT_DIR}/hyper-mcp" "$resources/"
    ok "Go binaries copied to Resources"
  else
    info "Go binaries not built yet — building first..."
    build_go
    cp "${OUTPUT_DIR}/hyper-ai-proxy" "$resources/"
    cp "${OUTPUT_DIR}/hyper-mcp" "$resources/"
  fi

  # Ensure cli-proxy-api-plus is in resources
  if [[ ! -f "$resources/cli-proxy-api-plus" ]]; then
    if [[ -f "/Applications/HyperAI.app/Contents/Resources/cli-proxy-api-plus" ]]; then
      cp "/Applications/HyperAI.app/Contents/Resources/cli-proxy-api-plus" "$resources/"
      ok "cli-proxy-api-plus copied from existing app"
    else
      err "cli-proxy-api-plus not found. Place it in ${resources}/"
      exit 1
    fi
  fi

  # Build
  local config="release"
  [[ "$RELEASE_MODE" == "debug" ]] && config="debug"

  swift build -c "$config"
  ok "Swift build ($config)"

  # Package as .app bundle
  local app_dir="${OUTPUT_DIR}/HyperAI.app/Contents"
  mkdir -p "${app_dir}/MacOS"
  mkdir -p "${app_dir}/Resources"

  # Copy binary
  local build_dir=".build/arm64-apple-macosx/${config}"
  cp "${build_dir}/HyperAI" "${app_dir}/MacOS/"

  # Copy all resources
  local bundle_resources
  bundle_resources="$(find "${build_dir}" -name "HyperAI_HyperAI.bundle" -type d 2>/dev/null | head -1)"
  if [[ -n "$bundle_resources" && -d "$bundle_resources" ]]; then
    cp -R "${bundle_resources}/"* "${app_dir}/Resources/" 2>/dev/null || true
  fi
  # Ensure resources are there
  for f in "$resources"/*; do
    [[ -f "$f" ]] && cp "$f" "${app_dir}/Resources/"
  done

  # Info.plist
  cat > "${app_dir}/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>HyperAI</string>
    <key>CFBundleDisplayName</key>
    <string>HyperAI</string>
    <key>CFBundleIdentifier</key>
    <string>com.hyper.ai</string>
    <key>CFBundleVersion</key>
    <string>${VERSION:-1.0.0}</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION:-1.0.0}</string>
    <key>CFBundleExecutable</key>
    <string>HyperAI</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

  chmod +x "${app_dir}/MacOS/HyperAI"
  ok "HyperAI.app packaged → ${OUTPUT_DIR}/HyperAI.app"
}

# =============================================================================
# Main
# =============================================================================
echo ""
info "Hyper Multi-Agent Build System"
echo ""

case "$BUILD_TARGET" in
  go)    build_go ;;
  swift) build_swift ;;
  app)   build_go; build_swift ;;
  all)   build_go_all; build_swift ;;
esac

echo ""
ok "Build complete → ${OUTPUT_DIR}/"
ls -lh "$OUTPUT_DIR"/ | tail -20
