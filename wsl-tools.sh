#!/bin/bash
set -euo pipefail

# WSL Tools — Interactive menu for WSL2 setup tasks
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/mosaicws/wsl-tools/main/wsl-tools.sh -o /tmp/wsl-tools.sh && bash /tmp/wsl-tools.sh

REPO_BASE="https://raw.githubusercontent.com/mosaicws/wsl-tools/main"

# ── Colours ──────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

# ── Pre-flight ───────────────────────────────────────────────

if [ ! -f /proc/version ] || ! grep -qi microsoft /proc/version 2>/dev/null; then
    error "This tool is designed to run inside WSL2."
    exit 1
fi

# Ensure whiptail is available
if ! command -v whiptail &>/dev/null; then
    echo "Installing whiptail..."
    apt-get update -qq && apt-get install -y -qq whiptail 2>/dev/null || sudo apt-get update -qq && sudo apt-get install -y -qq whiptail
fi

# ── Helpers ──────────────────────────────────────────────────

run_remote_script() {
    local script="$1"
    local tmpfile
    tmpfile=$(mktemp)
    info "Downloading $script..."
    curl -fsSL "$REPO_BASE/$script" > "$tmpfile"
    chmod +x "$tmpfile"
    WSL_TOOLS_MENU=1 bash "$tmpfile"
    rm -f "$tmpfile"
}

# ── Status detection ─────────────────────────────────────────

get_status() {
    local items=()

    # User setup
    if [ "$(id -u)" -eq 0 ]; then
        items+=("user" "NEEDED")
    else
        items+=("user" "$(whoami)")
    fi

    # SSH keys
    if [ -f "$HOME/.ssh/id_ed25519" ]; then
        local comment
        comment=$(awk '{print $3}' "$HOME/.ssh/id_ed25519.pub" 2>/dev/null) || comment=""
        items+=("ssh" "${comment:-configured}")
    else
        items+=("ssh" "NOT FOUND")
    fi

    # Git
    if command -v git &>/dev/null; then
        local git_name
        git_name=$(git config --global user.name 2>/dev/null) || git_name=""
        items+=("git" "${git_name:-not configured}")
    else
        items+=("git" "not installed")
    fi

    # WSL interop
    if command -v wsl.exe &>/dev/null; then
        items+=("interop" "enabled")
    else
        items+=("interop" "DISABLED")
    fi

    printf '%s\n' "${items[@]}"
}

# ── Menu ─────────────────────────────────────────────────────

show_menu() {
    # Build status line
    local ssh_status="not found"
    local user_status="root"
    [ -f "$HOME/.ssh/id_ed25519" ] && ssh_status="configured"
    [ "$(id -u)" -ne 0 ] && user_status="$(whoami)"

    local choice
    choice=$(whiptail --title "WSL Tools" \
        --menu "Current: user=$user_status | ssh=$ssh_status\n\nSelect an operation:" \
        18 70 6 \
        "1" "Create user account (run as root)" \
        "2" "Import SSH keys from another WSL instance" \
        "3" "Test GitHub SSH connection" \
        "4" "Show system info" \
        "5" "Exit" \
        3>&1 1>&2 2>&3) || exit 0

    echo "$choice"
}

# ── Operations ───────────────────────────────────────────────

op_create_user() {
    if [ "$(id -u)" -ne 0 ]; then
        error "User setup must be run as root."
        echo "  Run this tool as root: sudo bash /tmp/wsl-tools.sh"
        read -rp "Press ENTER to continue..." < /dev/tty
        return
    fi
    run_remote_script "user-setup.sh"

    # After user creation, offer to switch
    local default_user
    default_user=$(grep '^default=' /etc/wsl.conf 2>/dev/null | cut -d= -f2) || true
    if [ -n "$default_user" ] && [ "$default_user" != "root" ] && id "$default_user" &>/dev/null; then
        echo ""
        read -rp "Switch to '$default_user' now? [Y/n] " switch_user < /dev/tty
        if [[ ! "$switch_user" =~ ^[Nn]$ ]]; then
            info "Switching to '$default_user'..."
            exec su - "$default_user" -c "bash /tmp/wsl-tools.sh" < /dev/tty
        fi
    fi
}

# Find a non-root user to run commands as
find_normal_user() {
    # Check wsl.conf default user first
    local default_user
    default_user=$(grep '^default=' /etc/wsl.conf 2>/dev/null | cut -d= -f2) || true
    if [ -n "$default_user" ] && [ "$default_user" != "root" ] && id "$default_user" &>/dev/null; then
        echo "$default_user"
        return
    fi
    # Fall back to first user with uid >= 1000
    awk -F: '$3 >= 1000 && $3 < 65534 {print $1; exit}' /etc/passwd
}

op_import_ssh() {
    if [ "$(id -u)" -eq 0 ]; then
        local target_user
        target_user=$(find_normal_user)
        if [ -n "$target_user" ]; then
            info "Running SSH import as '$target_user'..."
            local tmpscript
            tmpscript=$(mktemp /tmp/ssh-import.XXXXXX)
            curl -fsSL "$REPO_BASE/ssh-import.sh" > "$tmpscript"
            chmod 755 "$tmpscript"
            su - "$target_user" -c "bash $tmpscript" < /dev/tty
            rm -f "$tmpscript"
        else
            error "No normal user account found. Create a user first (option 1)."
            read -rp "Press ENTER to continue..." < /dev/tty
        fi
        return
    fi
    run_remote_script "ssh-import.sh"
}

op_test_ssh() {
    echo ""
    if [ ! -f "$HOME/.ssh/id_ed25519" ]; then
        error "No SSH key found at ~/.ssh/id_ed25519"
    else
        info "Key fingerprint:"
        ssh-keygen -lf "$HOME/.ssh/id_ed25519.pub" 2>/dev/null || true
        echo ""
        info "Testing GitHub connection..."
        ssh -T git@github.com 2>&1 || true
    fi
    echo ""
    read -rp "Press ENTER to continue..." < /dev/tty
}

op_system_info() {
    echo ""
    echo "── System ──────────────────────────────────────────"
    echo "  Distro:    ${WSL_DISTRO_NAME:-unknown}"
    cat /etc/os-release 2>/dev/null | grep -E '^(PRETTY_NAME|VERSION)=' | sed 's/^/  /'
    echo "  Kernel:    $(uname -r)"
    echo "  User:      $(whoami) (uid=$(id -u))"
    echo "  Home:      $HOME"
    echo ""
    echo "── Tools ───────────────────────────────────────────"
    echo "  git:       $(git --version 2>/dev/null || echo 'not installed')"
    echo "  curl:      $(curl --version 2>/dev/null | head -1 || echo 'not installed')"
    echo "  ansible:   $(ansible --version 2>/dev/null | head -1 || echo 'not installed')"
    echo "  bun:       $(bun --version 2>/dev/null || echo 'not installed')"
    echo "  node:      $(node --version 2>/dev/null || echo 'not installed')"
    echo "  wsl.exe:   $(command -v wsl.exe &>/dev/null && echo 'available' || echo 'NOT available')"
    echo ""
    echo "── SSH ─────────────────────────────────────────────"
    if [ -f "$HOME/.ssh/id_ed25519" ]; then
        ssh-keygen -lf "$HOME/.ssh/id_ed25519.pub" 2>/dev/null | sed 's/^/  /'
    else
        echo "  No SSH key found"
    fi
    echo ""
    echo "── WSL Config ──────────────────────────────────────"
    cat /etc/wsl.conf 2>/dev/null | sed 's/^/  /' || echo "  No wsl.conf"
    echo ""
    read -rp "Press ENTER to continue..." < /dev/tty
}

# ── Main loop ────────────────────────────────────────────────

while true; do
    choice=$(show_menu)
    case "$choice" in
        1) op_create_user ;;
        2) op_import_ssh ;;
        3) op_test_ssh ;;
        4) op_system_info ;;
        5) exit 0 ;;
    esac
done
