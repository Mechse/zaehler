#!/usr/bin/env bash
# zaehler installer for macOS and Linux.
#
# Usage:
#   curl -sSL https://raw.githubusercontent.com/Mechse/zaehler/main/install.sh | bash
#
# Or after cloning:
#   ./install.sh

set -euo pipefail

REPO="https://github.com/Mechse/zaehler.git"
INSTALL_DIR="${HOME}/.local/bin"
RC_MARKER="# zaehler"

# ----- pretty output --------------------------------------------------------

red()    { printf "\033[31m%s\033[0m" "$*"; }
green()  { printf "\033[32m%s\033[0m" "$*"; }
yellow() { printf "\033[33m%s\033[0m" "$*"; }
cyan()   { printf "\033[36m%s\033[0m" "$*"; }

info()  { echo "$(green '==>') $*"; }
warn()  { echo "$(yellow 'warn:') $*" >&2; }
fail()  { echo "$(red 'error:') $*" >&2; exit 1; }

# Prompts inside `curl | bash` only work if we read from /dev/tty directly.
# When there's no tty we silently skip the question.
ask_yn() {
    local prompt="$1"
    local default="${2:-n}"
    if [ ! -t 0 ] && [ ! -r /dev/tty ]; then
        return 1   # no tty; treat as "no"
    fi
    local hint="[y/N]"
    [ "$default" = "y" ] && hint="[Y/n]"

    local answer
    if [ -r /dev/tty ]; then
        read -r -p "$prompt $hint " answer </dev/tty
    else
        read -r -p "$prompt $hint " answer
    fi
    answer="${answer:-$default}"
    [[ "$answer" =~ ^[yY](es)?$ ]]
}

# ----- platform detection ---------------------------------------------------

case "$(uname -s)" in
    Darwin) PLATFORM=macos ;;
    Linux)  PLATFORM=linux ;;
    *)      fail "unsupported platform: $(uname -s)" ;;
esac

info "platform: ${PLATFORM}"

# ----- Homebrew check (macOS only) -----------------------------------------

if [ "$PLATFORM" = "macos" ]; then
    if ! command -v brew >/dev/null 2>&1; then
        cat <<EOM

$(red 'Homebrew is required but not installed.')

Install it first by following the instructions at:
    https://brew.sh

Then re-run this script.

EOM
        exit 1
    fi
    info "Homebrew: $(brew --version | head -1)"
fi

# ----- dependency checks ----------------------------------------------------

MISSING=()

# Odin
if ! command -v odin >/dev/null 2>&1; then
    MISSING+=("odin")
else
    info "odin:    $(odin version 2>&1 | head -1)"
fi

# OpenSSL 3
if [ "$PLATFORM" = "macos" ]; then
    if [ -d "/opt/homebrew/opt/openssl@3" ] || [ -d "/usr/local/opt/openssl@3" ]; then
        info "openssl: openssl@3 (Homebrew)"
    else
        MISSING+=("openssl@3")
    fi
else
    if [ -f "/usr/lib/x86_64-linux-gnu/libssl.so" ] \
       || [ -f "/usr/lib/aarch64-linux-gnu/libssl.so" ] \
       || [ -f "/usr/lib/libssl.so" ]; then
        info "openssl: libssl present"
    else
        MISSING+=("libssl-dev")
    fi
fi

# SQLite — macOS provides it via the dyld shared cache; check on Linux only.
if [ "$PLATFORM" = "linux" ]; then
    if [ -f "/usr/lib/x86_64-linux-gnu/libsqlite3.so.0" ] \
       || [ -f "/usr/lib/aarch64-linux-gnu/libsqlite3.so.0" ] \
       || [ -f "/usr/lib/libsqlite3.so.0" ]; then
        info "sqlite:  libsqlite3 present"
    else
        MISSING+=("libsqlite3-0")
    fi
else
    info "sqlite:  (system)"
fi

# ----- bail if anything is missing -----------------------------------------

if [ ${#MISSING[@]} -gt 0 ]; then
    echo
    echo "$(red 'Missing dependencies:') ${MISSING[*]}"
    echo
    if [ "$PLATFORM" = "macos" ]; then
        echo "install with:"
        echo "    $(cyan "brew install ${MISSING[*]}")"
    else
        echo "install with:"
        echo "    $(cyan "sudo apt update && sudo apt install -y ${MISSING[*]}")"
    fi
    echo
    echo "then re-run this script."
    exit 1
fi

# ----- get the source -------------------------------------------------------

if [ -f "src/main.odin" ] && [ -f "build.sh" ]; then
    info "running from source checkout"
    SRC_DIR="$(pwd)"
    CLONED=0
else
    SRC_DIR="$(mktemp -d)"
    info "cloning into ${SRC_DIR}"
    git clone --depth 1 "$REPO" "$SRC_DIR"
    cd "$SRC_DIR"
    CLONED=1
fi

# ----- build ----------------------------------------------------------------

info "building..."
./build.sh

# ----- install --------------------------------------------------------------

mkdir -p "$INSTALL_DIR"
cp zlr "$INSTALL_DIR/zlr"
chmod +x "$INSTALL_DIR/zlr"

info "installed: ${INSTALL_DIR}/zlr"

# ----- PATH hint ------------------------------------------------------------

if ! echo ":$PATH:" | grep -q ":$INSTALL_DIR:"; then
    echo
    warn "${INSTALL_DIR} is not on your PATH."
    echo "add this to your shell rc:"
    echo "    $(cyan "export PATH=\"\$HOME/.local/bin:\$PATH\"")"
fi

# ----- offer to set ANTHROPIC_BASE_URL in shell rc -------------------------

# Detect the user's shell rc. Defaults to ~/.zshrc on macOS, ~/.bashrc on Linux.
RC_FILE=""
case "${SHELL##*/}" in
    zsh)  RC_FILE="${HOME}/.zshrc" ;;
    bash)
        # macOS bash uses .bash_profile by convention; Linux uses .bashrc
        if [ "$PLATFORM" = "macos" ] && [ -f "${HOME}/.bash_profile" ]; then
            RC_FILE="${HOME}/.bash_profile"
        else
            RC_FILE="${HOME}/.bashrc"
        fi
        ;;
    fish) RC_FILE="${HOME}/.config/fish/config.fish" ;;
esac

if [ -n "$RC_FILE" ]; then
    echo
    if grep -q "ANTHROPIC_BASE_URL=http://localhost:8765" "$RC_FILE" 2>/dev/null; then
        info "ANTHROPIC_BASE_URL already set in ${RC_FILE}"
    elif ask_yn "Append \`export ANTHROPIC_BASE_URL=http://localhost:8765\` to ${RC_FILE}?"; then
        {
            echo ""
            echo "${RC_MARKER} — route AI tools through the local proxy"
            if [ "${RC_FILE##*.}" = "fish" ]; then
                echo "set -x ANTHROPIC_BASE_URL http://localhost:8765"
            else
                echo "export ANTHROPIC_BASE_URL=http://localhost:8765"
            fi
        } >> "$RC_FILE"
        info "added to ${RC_FILE}"
        echo
        echo "to apply in this shell, run:"
        echo "    $(cyan "source ${RC_FILE}")"
        echo "or open a new terminal."
    else
        echo
        echo "skipped. to enable manually:"
        echo "    $(cyan "export ANTHROPIC_BASE_URL=http://localhost:8765")"
    fi
fi

# ----- cleanup --------------------------------------------------------------

if [ "$CLONED" = "1" ]; then
    rm -rf "$SRC_DIR"
fi

cat <<EOM

$(green 'done.') start the daemon with:

    $(cyan 'zlr start')

then use Claude Code (or any Anthropic SDK) normally. Watch usage with:

    $(cyan 'zlr today')
    $(cyan 'zlr tail')

EOM
