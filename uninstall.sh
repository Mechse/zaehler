#!/usr/bin/env bash
# zaehler uninstaller.
#
# Removes the binary, the rc-file export (if present, with confirmation),
# and the data directory (with confirmation).

set -euo pipefail

BIN="${HOME}/.local/bin/zlr"
DATA_DIR="${HOME}/.zaehler"
RC_MARKER="# zaehler"

# ----- pretty output --------------------------------------------------------

red()    { printf "\033[31m%s\033[0m" "$*"; }
green()  { printf "\033[32m%s\033[0m" "$*"; }
yellow() { printf "\033[33m%s\033[0m" "$*"; }
cyan()   { printf "\033[36m%s\033[0m" "$*"; }

info()  { echo "$(green '==>') $*"; }
warn()  { echo "$(yellow 'warn:') $*" >&2; }

ask_yn() {
    local prompt="$1"
    local default="${2:-n}"
    if [ ! -t 0 ] && [ ! -r /dev/tty ]; then
        return 1
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

# ----- stop the daemon if running -------------------------------------------

if [ -x "$BIN" ] && [ -f "${DATA_DIR}/zlr.pid" ]; then
    info "stopping running daemon..."
    "$BIN" stop || true
fi

# ----- remove the binary ----------------------------------------------------

if [ -f "$BIN" ]; then
    rm -f "$BIN"
    info "removed $BIN"
else
    info "$BIN not found (already uninstalled?)"
fi

# ----- remove rc-file lines we added during install ------------------------

remove_from_rc() {
    local rc_file="$1"
    [ -f "$rc_file" ] || return 0

    # Look for our marker line; remove it plus the next line (the export).
    if grep -q "^${RC_MARKER}" "$rc_file"; then
        if ask_yn "Remove zaehler lines from ${rc_file}?"; then
            # Portable sed: write to temp file and replace.
            local tmp
            tmp="$(mktemp)"
            # Skip the marker line and the immediately following line.
            awk -v marker="${RC_MARKER}" '
                $0 ~ "^" marker { skip = 2 }
                skip > 0 { skip--; next }
                { print }
            ' "$rc_file" > "$tmp"
            mv "$tmp" "$rc_file"
            info "cleaned up ${rc_file}"
            echo
            echo "to unset in this shell, run:"
            echo "    $(cyan 'unset ANTHROPIC_BASE_URL')"
        else
            info "left ${rc_file} alone"
        fi
    fi
}

remove_from_rc "${HOME}/.zshrc"
remove_from_rc "${HOME}/.bashrc"
remove_from_rc "${HOME}/.bash_profile"
remove_from_rc "${HOME}/.config/fish/config.fish"

# ----- ask about data dir ---------------------------------------------------

if [ -d "$DATA_DIR" ]; then
    echo
    warn "${DATA_DIR} still exists (contains your usage history)."
    if ask_yn "Delete it too?"; then
        rm -rf "$DATA_DIR"
        info "removed $DATA_DIR"
    else
        info "left $DATA_DIR in place"
    fi
fi

echo
info "uninstall complete."
