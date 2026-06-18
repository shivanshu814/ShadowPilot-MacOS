#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
#  ShadowPilot macOS — One-Click Installer
# ─────────────────────────────────────────────────────────────
#  curl -fsSL https://raw.githubusercontent.com/shivanshu814/ShadowPilot-MacOS/main/install.sh | bash
# ─────────────────────────────────────────────────────────────

set -euo pipefail

# ── Colors ────────────────────────────────────────────────────
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

step()  { echo -e "\n${CYAN}▶  $1${NC}"; }
ok()    { echo -e "   ${GREEN}✓  $1${NC}"; }
warn()  { echo -e "   ${YELLOW}⚠  $1${NC}"; }
fail()  { echo -e "\n${RED}✕  $1${NC}"; exit 1; }

INSTALL_DIR="$HOME/.shadowpilot"
APP_DEST="/Applications/ShadowPilot.app"

# ── Banner ────────────────────────────────────────────────────
echo ""
echo -e "${YELLOW}"
cat << 'EOF'
   ███████╗██╗  ██╗ █████╗ ██████╗  ██████╗ ██╗    ██╗
   ██╔════╝██║  ██║██╔══██╗██╔══██╗██╔═══██╗██║    ██║
   ███████╗███████║███████║██║  ██║██║   ██║██║ █╗ ██║
   ╚════██║██╔══██║██╔══██║██║  ██║██║   ██║██║███╗██║
   ███████║██║  ██║██║  ██║██████╔╝╚██████╔╝╚███╔███╔╝
   ╚══════╝╚═╝  ╚═╝╚═╝  ╚═╝╚═════╝  ╚═════╝  ╚══╝╚══╝
EOF
echo -e "${NC}"
echo -e "   ${BOLD}P I L O T${NC}   —   macOS Installer"
echo -e "   ${DIM}Installing to: $INSTALL_DIR${NC}"
echo ""

# ── Step 1: Check macOS version ───────────────────────────────
step "Checking macOS version..."
MACOS_VERSION=$(sw_vers -productVersion)
MAJOR=$(echo "$MACOS_VERSION" | cut -d. -f1)
if [ "$MAJOR" -lt 13 ]; then
    fail "macOS 13 (Ventura) or later required. You have $MACOS_VERSION."
fi
ok "macOS $MACOS_VERSION"

# ── Step 2: Check Xcode CLI tools ────────────────────────────
step "Checking Xcode Command Line Tools..."
if ! xcode-select -p &>/dev/null; then
    warn "Xcode CLI tools not found — installing (this may take a few minutes)..."
    xcode-select --install 2>/dev/null || true
    echo -e "   ${DIM}Waiting for installation to complete...${NC}"
    until xcode-select -p &>/dev/null; do
        sleep 5
    done
    ok "Xcode CLI tools installed"
else
    ok "Xcode CLI tools found at $(xcode-select -p)"
fi

# ── Step 3: Check XcodeGen ────────────────────────────────────
step "Checking XcodeGen..."
if command -v xcodegen &>/dev/null; then
    ok "XcodeGen found"
elif command -v brew &>/dev/null; then
    warn "XcodeGen not found — installing via Homebrew..."
    brew install xcodegen
    ok "XcodeGen installed"
else
    warn "Homebrew not found — installing Homebrew first..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    # Add brew to path for Apple Silicon
    if [ -f "/opt/homebrew/bin/brew" ]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
    fi
    brew install xcodegen
    ok "Homebrew + XcodeGen installed"
fi

# ── Step 4: Clone repo ───────────────────────────────────────
step "Cloning ShadowPilot..."
if [ -d "$INSTALL_DIR" ]; then
    warn "Directory exists — pulling latest..."
    cd "$INSTALL_DIR"
    git pull origin main 2>/dev/null || true
else
    git clone https://github.com/shivanshu814/ShadowPilot-MacOS.git "$INSTALL_DIR"
    cd "$INSTALL_DIR"
fi
ok "Source ready at $INSTALL_DIR"

# ── Step 5: Setup .env ────────────────────────────────────────
step "Setting up API keys..."
ENV_FILE="$HOME/.shadowpilot.env"

if [ -f "$ENV_FILE" ] && grep -qE "(OPENAI_API_KEY=sk-|OPENROUTER_API_KEY=sk-|BEDROCK_API_KEY=.+)" "$ENV_FILE"; then
    ok "API key found in $ENV_FILE"
else
    echo ""
    echo -e "   ${BOLD}Enter your OpenAI API key (starts with sk-...):${NC}"
    echo -n "   OPENAI_API_KEY="
    read -r API_KEY

    if [[ "$API_KEY" == sk-* ]]; then
        cat > "$ENV_FILE" << EOL
# ShadowPilot API Keys
OPENAI_API_KEY=$API_KEY

# Optional: Add other providers for fallback
# OPENROUTER_API_KEY=sk-or-v1-...
# BEDROCK_API_KEY=your_bedrock_key
# BEDROCK_REGION=us-east-1
EOL
        ok "Saved to $ENV_FILE"
    else
        warn "Skipping — you can add keys later to $ENV_FILE"
        cp "$INSTALL_DIR/.env.example" "$ENV_FILE" 2>/dev/null || true
    fi
fi

# Also copy to project root for builds
if [ -f "$ENV_FILE" ]; then
    cp "$ENV_FILE" "$INSTALL_DIR/.env" 2>/dev/null || true
fi

# ── Step 6: Generate Xcode project ───────────────────────────
step "Generating Xcode project..."
cd "$INSTALL_DIR"
xcodegen generate
ok "ShadowPilot.xcodeproj generated"

# ── Step 7: Build ─────────────────────────────────────────────
step "Building ShadowPilot (Release)..."
xcodebuild -scheme ShadowPilot \
    -configuration Release \
    -derivedDataPath build \
    build \
    2>&1 | tail -5

if [ ${PIPESTATUS[0]} -ne 0 ]; then
    fail "Build failed. Check errors above."
fi
ok "Build successful"

# ── Step 8: Install to /Applications ──────────────────────────
step "Installing to /Applications..."
BUILD_APP="$INSTALL_DIR/build/Build/Products/Release/ShadowPilot.app"

if [ ! -d "$BUILD_APP" ]; then
    # Try Debug if Release doesn't exist
    BUILD_APP="$INSTALL_DIR/build/Build/Products/Debug/ShadowPilot.app"
fi

if [ -d "$BUILD_APP" ]; then
    # Remove old version
    if [ -d "$APP_DEST" ]; then
        rm -rf "$APP_DEST"
    fi
    cp -R "$BUILD_APP" "$APP_DEST"
    ok "Installed to $APP_DEST"
else
    warn "App bundle not found — you can run from Xcode instead"
fi

# ── Step 9: Create uninstall script ──────────────────────────
cat > "$INSTALL_DIR/uninstall.sh" << 'UNINSTALL'
#!/usr/bin/env bash
echo "Uninstalling ShadowPilot..."
rm -rf /Applications/ShadowPilot.app
rm -rf "$HOME/.shadowpilot"
rm -f "$HOME/.shadowpilot.env"
echo "✓ ShadowPilot uninstalled."
UNINSTALL
chmod +x "$INSTALL_DIR/uninstall.sh"

# ── Done ──────────────────────────────────────────────────────
echo ""
echo -e "${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "   ${GREEN}✓  ShadowPilot installed successfully!${NC}"
echo ""
echo -e "   ${BOLD}Hotkeys (work system-wide):${NC}"
echo -e "   ${DIM}  ⌘⇧L  →  Mic toggle (listen)${NC}"
echo -e "   ${DIM}  ⌘⇧A  →  Get AI answer${NC}"
echo -e "   ${DIM}  ⌘⇧D  →  Screenshot + analyze${NC}"
echo -e "   ${DIM}  ⌘⇧X  →  Clear${NC}"
echo -e "   ${DIM}  ⌘⇧W  →  Toggle typing mode${NC}"
echo ""
echo -e "   ${BOLD}Launch:${NC} Open ShadowPilot from /Applications or Spotlight"
echo -e "   ${DIM}Uninstall: bash ~/.shadowpilot/uninstall.sh${NC}"
echo ""

read -rp "   Launch ShadowPilot now? (Y/n) " LAUNCH
if [[ "$LAUNCH" != "n" && "$LAUNCH" != "N" ]]; then
    open "$APP_DEST" 2>/dev/null || open "$BUILD_APP" 2>/dev/null || echo "   Open ShadowPilot.app from Xcode."
fi
