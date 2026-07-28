#!/usr/bin/env bash
#
#  WA Business for macOS - installer
#
#    curl -fsSL https://raw.githubusercontent.com/shivanshu814/ShadowPilot-MacOS/main/install.sh | bash
#
#  Flags:
#    --local         build the checkout you are standing in, skip the clone
#    --uninstall     remove the app and source (keeps your API keys)
#    --purge         with --uninstall, also delete ~/.wabusiness.env
#    --help          show usage
#
set -euo pipefail

REPO_URL="https://github.com/shivanshu814/ShadowPilot-MacOS.git"
BRANCH="main"
INSTALL_DIR="$HOME/.wabusiness"
ENV_FILE="$HOME/.wabusiness.env"
LEGACY_ENV="$HOME/.shadowpilot.env"
APP_DEST="/Applications/WA Business.app"
BUILD_LOG="$(mktemp -t wabusiness-build)"
# Where the user ran the installer from, captured before any cd. If they ran it
# inside a checkout that already has a filled .env, those keys get picked up.
SOURCE_PWD="$PWD"
IMPORTED_KEYS=""
SKIPPED=0

# ---------------------------------------------------------------------------
# Output helpers. Colour only when stdout is a terminal, so piping to a file
# or to CI produces clean text instead of escape codes.
# ---------------------------------------------------------------------------
if [ -t 1 ]; then
    BOLD=$'\033[1m'; DIM=$'\033[2m'; NC=$'\033[0m'
    CYAN=$'\033[36m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RED=$'\033[31m'
else
    BOLD=""; DIM=""; NC=""; CYAN=""; GREEN=""; YELLOW=""; RED=""
fi

STEP_NO=0
TOTAL_STEPS=7

step() { STEP_NO=$((STEP_NO + 1)); printf "\n${CYAN}${BOLD}[%d/%d] %s${NC}\n" "$STEP_NO" "$TOTAL_STEPS" "$1"; }
ok()   { printf "      ${GREEN}ok${NC}    %s\n" "$1"; }
info() { printf "      ${DIM}...${NC}   %s\n" "$1"; }
warn() { printf "      ${YELLOW}warn${NC}  %s\n" "$1"; }
die()  { printf "\n${RED}${BOLD}Failed:${NC} %s\n\n" "$1" >&2; exit 1; }

rule() { printf "${DIM}%s${NC}\n" "--------------------------------------------------------------"; }

banner() {
    printf "\n"
    printf "${YELLOW}${BOLD}  W A   B U S I N E S S${NC}\n"
    printf "${DIM}  macOS installer${NC}\n"
    printf "\n"
    rule
}

# ---------------------------------------------------------------------------
# Interactive input.
#
# This script is normally run as `curl ... | bash`, which means stdin is the
# script itself. A bare `read` would swallow the next lines of the script and
# use them as the answer, so every prompt must come from the terminal directly.
# When there is no terminal (CI, nohup) we fall back to the default answer.
# ---------------------------------------------------------------------------
# A -r test on /dev/tty passes even when there is no controlling terminal, so
# actually try to open it rather than trusting the permission bits.
have_tty() { { : < /dev/tty; } >/dev/null 2>&1; }

ask() {                       # ask "prompt" "default" -> echoes the answer
    local prompt="$1" default="${2:-}" reply=""
    if ! have_tty; then echo "$default"; return; fi
    printf "      ${BOLD}%s${NC}" "$prompt" > /dev/tty
    IFS= read -r reply < /dev/tty || reply=""
    [ -n "$reply" ] && echo "$reply" || echo "$default"
}

confirm() {                   # confirm "prompt" -> 0 for yes, 1 for no
    local reply
    reply="$(ask "$1 [Y/n] " "y")"
    case "$reply" in [nN]*) return 1 ;; *) return 0 ;; esac
}

on_error() {
    local line=$1
    printf "\n${RED}${BOLD}Install failed${NC} (line %s)\n" "$line" >&2
    [ -s "$BUILD_LOG" ] && printf "${DIM}Build log: %s${NC}\n" "$BUILD_LOG" >&2
    printf "\n"
}
trap 'on_error $LINENO' ERR

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------
do_uninstall() {
    local purge="${1:-no}"
    banner
    printf "\n  Removing WA Business\n\n"
    rm -rf "$APP_DEST"     && ok "removed $APP_DEST"
    rm -rf "$INSTALL_DIR"  && ok "removed $INSTALL_DIR"
    if [ "$purge" = "purge" ]; then
        rm -f "$ENV_FILE"  && ok "removed $ENV_FILE"
    elif [ -f "$ENV_FILE" ]; then
        info "kept your API keys at $ENV_FILE"
        info "delete them with: rm $ENV_FILE"
    fi
    printf "\n  Done.\n\n"
    exit 0
}

usage() {
    cat <<'USAGE'

WA Business for macOS - installer

  install.sh                 install or update from GitHub
  install.sh --local         build the checkout you are standing in
  install.sh --uninstall     remove the app and source, keep API keys
  install.sh --uninstall --purge
                             remove everything including API keys
  install.sh --help          this message

USAGE
    exit 0
}

PURGE="no"
UNINSTALL="no"
LOCAL_MODE="no"
for arg in "$@"; do
    case "$arg" in
        --local)     LOCAL_MODE="yes" ;;
        --uninstall) UNINSTALL="yes" ;;
        --purge)     PURGE="purge" ;;
        --help|-h)   usage ;;
        *)           die "unknown flag: $arg (try --help)" ;;
    esac
done
[ "$UNINSTALL" = "yes" ] && do_uninstall "$PURGE"

# Local builds skip the clone and the uninstaller, so the checkout is never
# touched and no stray file lands in the working tree.
[ "$LOCAL_MODE" = "yes" ] && TOTAL_STEPS=6

# ---------------------------------------------------------------------------
# 1. Environment checks
# ---------------------------------------------------------------------------
banner

step "Checking your system"

case "$(uname -s)" in
    Darwin) ;;
    *) die "this installer is macOS only" ;;
esac

MACOS_VERSION="$(sw_vers -productVersion)"
if [ "${MACOS_VERSION%%.*}" -lt 13 ]; then
    die "macOS 13 (Ventura) or later is required. You have $MACOS_VERSION."
fi
ok "macOS $MACOS_VERSION on $(uname -m)"

if ! xcode-select -p >/dev/null 2>&1; then
    warn "Xcode command line tools missing, requesting install"
    xcode-select --install >/dev/null 2>&1 || true
    info "accept the dialog, this can take several minutes"
    until xcode-select -p >/dev/null 2>&1; do sleep 5; done
fi
ok "Xcode tools at $(xcode-select -p)"

command -v git >/dev/null 2>&1 || die "git not found even though Xcode tools are installed"

# ---------------------------------------------------------------------------
# 2. Build dependencies
# ---------------------------------------------------------------------------
step "Checking build dependencies"

if ! command -v brew >/dev/null 2>&1; then
    for candidate in /opt/homebrew/bin/brew /usr/local/bin/brew; do
        [ -x "$candidate" ] && eval "$("$candidate" shellenv)" && break
    done
fi

if command -v xcodegen >/dev/null 2>&1; then
    ok "XcodeGen $(xcodegen --version 2>/dev/null | head -1)"
else
    if ! command -v brew >/dev/null 2>&1; then
        warn "Homebrew missing, installing it first"
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
        for candidate in /opt/homebrew/bin/brew /usr/local/bin/brew; do
            [ -x "$candidate" ] && eval "$("$candidate" shellenv)" && break
        done
        command -v brew >/dev/null 2>&1 || die "Homebrew install did not complete"
        ok "Homebrew installed"
    fi
    info "installing XcodeGen"
    brew install xcodegen >/dev/null
    ok "XcodeGen installed"
fi

# ---------------------------------------------------------------------------
# 3. Source
# ---------------------------------------------------------------------------
if [ "$LOCAL_MODE" = "yes" ]; then
    step "Using the local checkout"
    INSTALL_DIR="$SOURCE_PWD"
    [ -f "$INSTALL_DIR/project.yml" ] || die "no project.yml in $INSTALL_DIR — run this from the repo root"
    cd "$INSTALL_DIR"
    ok "building $INSTALL_DIR"
    info "local checkout, nothing fetched from GitHub"
else

step "Fetching the source"

if [ -d "$INSTALL_DIR/.git" ]; then
    cd "$INSTALL_DIR"
    if [ -n "$(git status --porcelain)" ]; then
        warn "local changes in $INSTALL_DIR, leaving them alone and building as-is"
    else
        git fetch --quiet origin "$BRANCH"
        git reset --hard --quiet "origin/$BRANCH"
        ok "updated to latest $BRANCH"
    fi
else
    rm -rf "$INSTALL_DIR"
    git clone --quiet --depth 1 --branch "$BRANCH" "$REPO_URL" "$INSTALL_DIR"
    cd "$INSTALL_DIR"
    ok "cloned to $INSTALL_DIR"
fi

fi

# ---------------------------------------------------------------------------
# 4. API keys
#
# Any one provider is enough to run. The key's own prefix tells us which
# provider it belongs to, so the prompt stays a single question.
# ---------------------------------------------------------------------------
step "Setting up API keys"

key_var_for() {
    case "$1" in
        gsk_*)       echo "GROQ_API_KEY" ;;
        sk-or-v1-*)  echo "OPENROUTER_API_KEY" ;;
        sk-*)        echo "OPENAI_API_KEY" ;;
        *)           echo "" ;;
    esac
}

has_value() { grep -qE "^$1=[^[:space:]]" "$ENV_FILE" 2>/dev/null; }

# Written without sed so a value containing & / | or any other metacharacter
# (Neon URLs, tokens) is stored exactly as given.
set_key() {
    local key="$1" val="$2" tmp line found=0
    tmp="$(mktemp)"
    if [ -f "$ENV_FILE" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            if [ "${line%%=*}" = "$key" ]; then
                printf '%s=%s\n' "$key" "$val" >> "$tmp"; found=1
            else
                printf '%s\n' "$line" >> "$tmp"
            fi
        done < "$ENV_FILE"
    fi
    [ "$found" -eq 0 ] && printf '%s=%s\n' "$key" "$val" >> "$tmp"
    mv "$tmp" "$ENV_FILE"
    chmod 600 "$ENV_FILE"
}

# Copy every filled key out of an existing env file. Keys already set in
# ENV_FILE always win, so re-running the installer never downgrades them.
import_env() {
    local src="$1" line key val
    [ -f "$src" ] || return 0
    [ "$src" -ef "$ENV_FILE" ] 2>/dev/null && return 0
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in ''|'#'*) continue ;; esac
        case "$line" in *=*) ;; *) continue ;; esac
        key="${line%%=*}"
        val="${line#*=}"
        # Trim surrounding whitespace only. Inner spaces mean the line is
        # malformed ("cursor api key = ..."), and a malformed name must be
        # skipped rather than silently repaired into a key nothing reads.
        key="${key#"${key%%[![:space:]]*}"}"
        key="${key%"${key##*[![:space:]]}"}"
        case "$key" in ''|*[!A-Za-z0-9_]*) SKIPPED=$((SKIPPED + 1)); continue ;; esac
        [ -z "$val" ] && continue
        has_value "$key" && continue
        set_key "$key" "$val"
        IMPORTED_KEYS="$IMPORTED_KEYS $key"
    done < "$src"
}

has_any_key() {
    [ -f "$ENV_FILE" ] || return 1
    grep -qE '^(GROQ_API_KEY|OPENROUTER_API_KEY|OPENAI_API_KEY|BEDROCK_API_KEY|API_TOKEN)=[^[:space:]]+' "$ENV_FILE"
}

if [ ! -f "$ENV_FILE" ]; then
    cp "$INSTALL_DIR/.env.example" "$ENV_FILE" 2>/dev/null || touch "$ENV_FILE"
fi
chmod 600 "$ENV_FILE"

# Pull in everything already configured, in priority order.
for candidate in "$SOURCE_PWD/.env" "$LEGACY_ENV" "$HOME/.env" "$INSTALL_DIR/.env"; do
    import_env "$candidate"
done

if [ -n "$IMPORTED_KEYS" ]; then
    ok "carried over:$IMPORTED_KEYS"
    info "values copied into $ENV_FILE, never printed"
fi
if [ "$SKIPPED" -gt 0 ]; then
    warn "$SKIPPED malformed line(s) skipped, a key name cannot contain spaces"
fi

if has_any_key; then
    ok "keys ready in $ENV_FILE"
else
    printf "\n"
    info "Paste any one provider key. Groq is fastest for live answers,"
    info "OpenRouter unlocks Claude Sonnet for everything code related."
    info "Leave blank to add keys later."
    printf "\n"
    API_KEY="$(ask "key: " "")"
    KEY_VAR="$(key_var_for "$API_KEY")"

    if [ -n "$API_KEY" ] && [ -z "$KEY_VAR" ]; then
        warn "unrecognised key prefix, storing it as OPENAI_API_KEY"
        KEY_VAR="OPENAI_API_KEY"
    fi

    if [ -n "$KEY_VAR" ]; then
        set_key "$KEY_VAR" "$API_KEY"
        ok "saved $KEY_VAR to $ENV_FILE"
    else
        warn "no key set, add one to $ENV_FILE before using the app"
    fi
fi

# ---------------------------------------------------------------------------
# 5. Build
# ---------------------------------------------------------------------------
step "Building"

cd "$INSTALL_DIR"
xcodegen generate >/dev/null
ok "Xcode project generated"

info "compiling, this takes a minute"
if ! xcodebuild -scheme WABusiness \
        -configuration Release \
        -derivedDataPath build \
        build > "$BUILD_LOG" 2>&1; then
    printf "\n"
    grep -E "error:" "$BUILD_LOG" | head -15 || tail -25 "$BUILD_LOG"
    die "build failed, full log at $BUILD_LOG"
fi
ok "build succeeded"

# ---------------------------------------------------------------------------
# 6. Install
# ---------------------------------------------------------------------------
step "Installing to /Applications"

BUILD_APP="$INSTALL_DIR/build/Build/Products/Release/WA Business.app"
[ -d "$BUILD_APP" ] || BUILD_APP="$INSTALL_DIR/build/Build/Products/Debug/WA Business.app"
[ -d "$BUILD_APP" ] || die "built app not found under $INSTALL_DIR/build"

rm -rf "$APP_DEST" 2>/dev/null || true
if cp -R "$BUILD_APP" "$APP_DEST" 2>/dev/null; then
    ok "installed $APP_DEST"
else
    # Managed Macs sometimes lock /Applications. Fall back rather than
    # demanding a sudo password from a piped installer that has no terminal.
    warn "/Applications is not writable"
    mkdir -p "$HOME/Applications"
    APP_DEST="$HOME/Applications/WA Business.app"
    rm -rf "$APP_DEST"
    cp -R "$BUILD_APP" "$APP_DEST"
    ok "installed $APP_DEST instead"
fi

# ---------------------------------------------------------------------------
# 7. Uninstaller
# ---------------------------------------------------------------------------
if [ "$LOCAL_MODE" != "yes" ]; then
    step "Writing the uninstaller"
    cat > "$INSTALL_DIR/uninstall.sh" <<'UNINSTALL'
#!/usr/bin/env bash
# Removes WA Business. Pass --purge to also delete ~/.wabusiness.env
set -euo pipefail
exec bash "$HOME/.wabusiness/install.sh" --uninstall "$@"
UNINSTALL
    chmod +x "$INSTALL_DIR/uninstall.sh"
    ok "bash ~/.wabusiness/uninstall.sh"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
printf "\n"
rule
printf "\n  ${GREEN}${BOLD}WA Business is installed.${NC}\n\n"

printf "  ${BOLD}Global hotkeys${NC}\n"
printf "    Cmd+Shift+L    start or stop listening\n"
printf "    Cmd+Shift+A    get an answer\n"
printf "    Cmd+Shift+D    capture the screen and analyze it\n"
printf "    Cmd+Shift+B    scan the loaded repo for bugs\n"
printf "    Cmd+Shift+X    clear everything\n"
printf "    Cmd+Shift+W    toggle typing mode\n\n"

printf "  ${BOLD}Working with a codebase${NC}\n"
printf "    /repo ~/code/my-service        index a local folder\n"
printf "    /repo github.com/owner/name    clone it, then index\n"
printf "    Cloud pill                     full review by a Cursor agent\n\n"

printf "  ${BOLD}First launch${NC}\n"
printf "    macOS will ask for Microphone, Speech Recognition and Screen\n"
printf "    Recording. If hotkeys do nothing, add WA Business under\n"
printf "    System Settings > Privacy and Security > Accessibility.\n\n"

printf "  ${DIM}Keys:      %s${NC}\n" "$ENV_FILE"
printf "  ${DIM}Source:    %s${NC}\n" "$INSTALL_DIR"
if [ "$LOCAL_MODE" = "yes" ]; then
    printf "  ${DIM}Uninstall: rm -rf \"%s\"${NC}\n\n" "$APP_DEST"
else
    printf "  ${DIM}Uninstall: bash %s/uninstall.sh${NC}\n\n" "$INSTALL_DIR"
fi

rm -f "$BUILD_LOG"

if confirm "Launch WA Business now?"; then
    open "$APP_DEST" 2>/dev/null || warn "could not launch, open it from /Applications"
fi
printf "\n"
