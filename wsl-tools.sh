#!/bin/bash
set -euo pipefail

# WSL Tools — Interactive menu for WSL2 setup tasks
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/mosaicws/wsl-tools/main/wsl-tools.sh -o /tmp/wsl-tools.sh && bash /tmp/wsl-tools.sh
#   bash /tmp/wsl-tools.sh --debug

REPO_URL="https://api.github.com/repos/mosaicws/wsl-tools/contents"
REPO_RAW="https://raw.githubusercontent.com/mosaicws/wsl-tools/main"
TTY_IN=$([ -e /dev/tty ] && echo /dev/tty || echo /dev/stdin)

DEBUG=false
for arg in "$@"; do
    [[ "$arg" == "--debug" || "$arg" == "-d" ]] && DEBUG=true
done
debug() { $DEBUG && echo -e "\033[0;36m[DEBUG]\033[0m $1" >&2 || true; }

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

if ! grep -qi microsoft /proc/version 2>/dev/null; then
    error "This tool is designed to run inside WSL2."
    exit 1
fi

if ! command -v whiptail &>/dev/null; then
    info "Installing whiptail..."
    apt-get update -qq && apt-get install -y -qq whiptail 2>/dev/null \
        || { sudo apt-get update -qq && sudo apt-get install -y -qq whiptail; }
fi

download_script() {
    local script="$1" dest="$2"
    debug "Downloading $script"
    curl -H "Accept: application/vnd.github.v3.raw" -fsSL "$REPO_URL/$script" > "$dest" 2>/dev/null \
        || curl -fsSL "$REPO_RAW/$script" > "$dest"
    chmod 755 "$dest"
    debug "Downloaded $(wc -c < "$dest") bytes"
}

run_remote_script() {
    local tmpfile
    tmpfile=$(mktemp /tmp/wsl-tools.XXXXXX)
    download_script "$1" "$tmpfile"
    WSL_TOOLS_MENU=1 bash "$tmpfile"
    rm -f "$tmpfile"
}

find_normal_user() {
    local user
    user=$(grep '^default=' /etc/wsl.conf 2>/dev/null | cut -d= -f2) || true
    if [ -n "$user" ] && [ "$user" != "root" ] && id "$user" &>/dev/null; then
        echo "$user"; return
    fi
    awk -F: '$3 >= 1000 && $3 < 65534 {print $1; exit}' /etc/passwd
}

# ── Menu ─────────────────────────────────────────────────────

show_menu() {
    local ssh_status="not found" user_status="root" ssh_home="$HOME"
    if [ "$(id -u)" -eq 0 ]; then
        local nu; nu=$(find_normal_user)
        [ -n "$nu" ] && { user_status="$nu"; ssh_home=$(eval echo "~$nu"); }
    else
        user_status="$(whoami)"
    fi
    [ -f "$ssh_home/.ssh/id_ed25519" ] && ssh_status="configured"

    whiptail --title "WSL Tools" \
        --menu "Current: user=$user_status | ssh=$ssh_status\n\nSelect an operation:" \
        18 70 6 \
        "1" "Create user account (run as root)" \
        "2" "Import SSH keys from another WSL instance" \
        "3" "Test GitHub SSH connection" \
        "4" "Show system info" \
        "5" "Exit" \
        3>&1 1>&2 2>&3 || echo "5"
}

# ── Operations ───────────────────────────────────────────────

op_create_user() {
    if [ "$(id -u)" -ne 0 ]; then
        error "User setup must be run as root."
        read -rp "Press ENTER to continue..." < "$TTY_IN"
        return
    fi
    run_remote_script "user-setup.sh"

    local default_user
    default_user=$(find_normal_user)
    if [ -n "$default_user" ]; then
        read -rp "Switch to '$default_user' and relaunch menu? [Y/n] " switch_user < "$TTY_IN"
        if [[ ! "$switch_user" =~ ^[Nn]$ ]]; then
            info "Switching to '$default_user'..."
            exec su - "$default_user" -c "bash /tmp/wsl-tools.sh" < "$TTY_IN"
        fi
    fi
}

op_import_ssh() {
    local target_user="" target_home=""

    if [ "$(id -u)" -eq 0 ]; then
        target_user=$(find_normal_user)
        if [ -z "$target_user" ]; then
            error "No normal user account found. Create a user first (option 1)."
            read -rp "Press ENTER to continue..." < "$TTY_IN"
            return
        fi
        target_home=$(eval echo "~$target_user")
        debug "Importing SSH keys for '$target_user' (home=$target_home)"
    fi

    local tmpscript
    tmpscript=$(mktemp /tmp/ssh-import.XXXXXX)
    download_script "ssh-import.sh" "$tmpscript"

    if [ -n "$target_user" ]; then
        info "Importing SSH keys for '$target_user'..."
        HOME="$target_home" USER="$target_user" bash "$tmpscript"
        chown -R "$target_user:$target_user" "$target_home/.ssh" 2>/dev/null || true
    else
        bash "$tmpscript"
    fi
    rm -f "$tmpscript"
    read -rp "Press ENTER to continue..." < "$TTY_IN"
}

op_test_ssh() {
    local ssh_home="$HOME"
    if [ "$(id -u)" -eq 0 ]; then
        local target_user
        target_user=$(find_normal_user)
        [ -n "$target_user" ] && ssh_home=$(eval echo "~$target_user")
    fi

    echo ""
    if [ ! -f "$ssh_home/.ssh/id_ed25519" ]; then
        error "No SSH key found at $ssh_home/.ssh/id_ed25519"
    else
        info "Key fingerprint:"
        ssh-keygen -lf "$ssh_home/.ssh/id_ed25519.pub" 2>/dev/null || true
        echo ""
        if command -v ssh &>/dev/null; then
            info "Testing GitHub connection..."
            ssh -i "$ssh_home/.ssh/id_ed25519" -T git@github.com 2>&1 || true
        else
            warn "openssh-client not installed — install it to test SSH connections."
        fi
    fi
    echo ""
    read -rp "Press ENTER to continue..." < "$TTY_IN"
}

op_system_info() {
    echo ""
    echo "── System ──────────────────────────────────────────"
    echo "  Distro:  ${WSL_DISTRO_NAME:-unknown}"
    grep -E '^PRETTY_NAME=' /etc/os-release 2>/dev/null | sed 's/^PRETTY_NAME=/  OS:     /' | tr -d '"'
    echo "  Kernel:  $(uname -r)"
    echo "  User:    $(whoami) (uid=$(id -u))"
    echo ""
    echo "── Tools ───────────────────────────────────────────"
    for tool in git curl ansible bun node; do
        ver=$($tool --version 2>/dev/null | head -1) || ver="not installed"
        printf "  %-9s %s\n" "$tool:" "$ver"
    done
    printf "  %-9s %s\n" "wsl.exe:" "$(command -v wsl.exe &>/dev/null && echo 'available' || echo 'not available')"
    echo ""
    echo "── SSH ─────────────────────────────────────────────"
    if [ -f "$HOME/.ssh/id_ed25519.pub" ]; then
        ssh-keygen -lf "$HOME/.ssh/id_ed25519.pub" 2>/dev/null | sed 's/^/  /'
    else
        echo "  No SSH key found"
    fi
    echo ""
    read -rp "Press ENTER to continue..." < "$TTY_IN"
}

# ── Main loop ────────────────────────────────────────────────

debug "Starting wsl-tools (uid=$(id -u), user=$(whoami))"

while true; do
    choice=$(show_menu)
    debug "Menu choice: $choice"
    case "$choice" in
        1) op_create_user ;;
        2) op_import_ssh ;;
        3) op_test_ssh ;;
        4) op_system_info ;;
        *) exit 0 ;;
    esac
done
