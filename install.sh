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

# ----- pretty output --------------------------------------------------------

red()    { printf "\033[31m%s\033[0m" "$*"; }
green()  { printf "\033[32m%s\033[0m" "$*"; }
yellow() { printf "\033[33m%s\033[0m" "$*"; }

info()  { echo "$(green '==>') $*"; }
warn()  { echo "$(yellow 'warn:') $*" >&2; }
die()   { echo "$(red 'error:') $*" >&2; exit 1; }

# ----- platform detection ---------------------------------------------------

case "$(uname -s)" in
    Darwin) PLATFORM=macos ;;
    Linux)  PLATFORM=linux ;;
    *)      die "unsupported platform: $(uname -s)" ;;
esac

info "detected platform: ${PLATFORM}"

# ----- dependency checks ----------------------------------------------------

check_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        return 1
    fi
}

if ! check_cmd odin; then
    if [ "$PLATFORM" = "macos" ]; then
        die "odin not found. install with:  brew install odin"
    else
        die "odin not found. install instructions: https://odin-lang.org/docs/install/"
    fi
fi
info "odin: $(odin version 2>&1 | head -1)"

# OpenSSL: macOS uses Homebrew's openssl@3; Linux uses the system package.
if [ "$PLATFORM" = "macos" ]; then
    if [ ! -d "/opt/homebrew/opt/openssl@3" ] && [ ! -d "/usr/local/opt/openssl@3" ]; then
        die "openssl@3 not found. install with:  brew install openssl@3"
    fi
    info "openssl@3 present"
else
    if [ ! -f "/usr/lib/x86_64-linux-gnu/libssl.so" ] \
       && [ ! -f "/usr/lib/aarch64-linux-gnu/libssl.so" ] \
       && [ ! -f "/usr/lib/libssl.so" ]; then
        warn "libssl development files not found; you may need:  apt install libssl-dev"
    else
        info "libssl present"
    fi
fi

# SQLite: macOS provides it in the dyld shared cache; Linux needs the package.
if [ "$PLATFORM" = "linux" ]; then
    if [ ! -f "/usr/lib/x86_64-linux-gnu/libsqlite3.so.0" ] \
       && [ ! -f "/usr/lib/aarch64-linux-gnu/libsqlite3.so.0" ] \
       && [ ! -f "/usr/lib/libsqlite3.so.0" ]; then
        warn "libsqlite3 not found; you may need:  apt install libsqlite3-0"
    else
        info "libsqlite3 present"
    fi
fi

# ----- get the source -------------------------------------------------------

# If we're running from inside a clone, use it. Otherwise clone to a temp dir.
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
    cat <<EOF

$(yellow 'note:') ${INSTALL_DIR} is not on your PATH.
add this to your shell rc (~/.zshrc or ~/.bashrc):

    export PATH="\$HOME/.local/bin:\$PATH"

EOF
fi

# ----- cleanup --------------------------------------------------------------

if [ "$CLONED" = "1" ]; then
    rm -rf "$SRC_DIR"
fi

cat <<EOF

$(green 'done.') start the daemon with:

    zlr daemon

then in another terminal:

    export ANTHROPIC_BASE_URL=http://localhost:8765
    claude  # or whatever you use

and watch:

    zlr today
    zlr tail

EOF
