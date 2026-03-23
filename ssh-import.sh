#!/bin/bash
set -euo pipefail

# WSL2 SSH Key Importer
# Scans other WSL instances for SSH keys and imports them interactively.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/mosaicws/wsl-tools/main/ssh-import.sh | bash
#
# Or download and run:
#   wget -qO ssh-import.sh https://raw.githubusercontent.com/mosaicws/wsl-tools/main/ssh-import.sh
#   bash ssh-import.sh

SSH_DIR="$HOME/.ssh"
SSH_KEY="$SSH_DIR/id_ed25519"

# ── Colours ──────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

# ── Pre-flight checks ───────────────────────────────────────

if [ ! -f /proc/version ] || ! grep -qi microsoft /proc/version 2>/dev/null; then
    error "This script is designed to run inside WSL2."
    exit 1
fi

mkdir -p "$SSH_DIR" && chmod 700 "$SSH_DIR"

if [ -f "$SSH_KEY" ]; then
    info "SSH key already exists at $SSH_KEY"
    echo ""
    ssh-keygen -lf "$SSH_KEY.pub" 2>/dev/null || true
    echo ""
    read -rp "Overwrite with a key from another WSL instance? [y/N] " overwrite < /dev/tty
    if [[ ! "$overwrite" =~ ^[Yy]$ ]]; then
        info "Keeping existing key. Nothing to do."
        exit 0
    fi
fi

# ── Discover WSL distros with SSH keys ───────────────────────

if ! command -v wsl.exe &>/dev/null; then
    error "wsl.exe not available. Windows interop may be disabled in /etc/wsl.conf"
    exit 1
fi

info "Scanning WSL instances for SSH keys..."

# Get current distro to exclude it
current_distro="${WSL_DISTRO_NAME:-}"
if [ -z "$current_distro" ]; then
    current_distro=$(wsl.exe -l -q 2>/dev/null | iconv -f UTF-16LE -t UTF-8 | tr -d '\r' | head -1) || true
fi

# Build list of distros that have SSH keys
candidates=()
menu_items=()
while IFS= read -r distro; do
    [ -z "$distro" ] && continue
    [ "$distro" = "$current_distro" ] && continue

    if wsl.exe -d "$distro" -- test -f "/home/$USER/.ssh/id_ed25519" 2>/dev/null; then
        candidates+=("$distro")
        comment=$(wsl.exe -d "$distro" -- cat "/home/$USER/.ssh/id_ed25519.pub" 2>/dev/null | tr -d '\r' | awk '{print $3}') || comment=""
        menu_items+=("$distro" "${comment:-SSH key found}")
    fi
done < <(wsl.exe -l -q 2>/dev/null | iconv -f UTF-16LE -t UTF-8 | tr -d '\r' | sed '/^$/d')

if [ ${#candidates[@]} -eq 0 ]; then
    warn "No other WSL instances found with SSH keys for user '$USER'"
    echo ""
    echo "You can copy keys manually:"
    echo "  From Windows Explorer, copy the files from:"
    echo "    \\\\wsl\$\\<source-distro>\\home\\$USER\\.ssh\\"
    echo "  Into:"
    echo "    \\\\wsl\$\\${WSL_DISTRO_NAME:-this-distro}\\home\\$USER\\.ssh\\"
    echo ""
    echo "Files needed: id_ed25519, id_ed25519.pub, known_hosts"
    exit 1
fi

# ── Interactive selection ────────────────────────────────────

# Use whiptail if available, otherwise fall back to simple numbered menu
if command -v whiptail &>/dev/null; then
    selected=$(whiptail --title "SSH Key Import" \
        --menu "Select the WSL instance to copy SSH keys from:" \
        16 70 ${#candidates[@]} \
        "${menu_items[@]}" \
        3>&1 1>&2 2>&3) || {
        warn "Selection cancelled."
        exit 1
    }
else
    echo ""
    echo "Available WSL instances with SSH keys:"
    echo ""
    for i in "${!candidates[@]}"; do
        echo "  $((i+1))) ${candidates[$i]}  (${menu_items[$((i*2+1))]})"
    done
    echo ""
    read -rp "Select [1-${#candidates[@]}]: " choice < /dev/tty
    if [[ ! "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt ${#candidates[@]} ]; then
        error "Invalid selection."
        exit 1
    fi
    selected="${candidates[$((choice-1))]}"
fi

# ── Confirmation ─────────────────────────────────────────────

pub_key=$(wsl.exe -d "$selected" -- cat "/home/$USER/.ssh/id_ed25519.pub" 2>/dev/null | tr -d '\r')

echo ""
echo "Source:     $selected"
echo "Public key: $pub_key"
echo "Target:     $SSH_DIR/"
echo ""

if command -v whiptail &>/dev/null; then
    whiptail --title "Confirm Import" \
        --yesno "Import SSH keys from $selected?\n\n$pub_key\n\nFiles will be copied to $SSH_DIR/" \
        12 78 || {
        warn "Import cancelled."
        exit 1
    }
else
    read -rp "Proceed? [Y/n] " confirm < /dev/tty
    if [[ "$confirm" =~ ^[Nn]$ ]]; then
        warn "Import cancelled."
        exit 1
    fi
fi

# ── Copy keys ────────────────────────────────────────────────

info "Copying SSH keys from $selected..."

wsl.exe -d "$selected" -- cat "/home/$USER/.ssh/id_ed25519" | tr -d '\r' > "$SSH_KEY"
chmod 600 "$SSH_KEY"

if wsl.exe -d "$selected" -- test -f "/home/$USER/.ssh/id_ed25519.pub" 2>/dev/null; then
    wsl.exe -d "$selected" -- cat "/home/$USER/.ssh/id_ed25519.pub" | tr -d '\r' > "$SSH_KEY.pub"
    chmod 644 "$SSH_KEY.pub"
fi

if wsl.exe -d "$selected" -- test -f "/home/$USER/.ssh/known_hosts" 2>/dev/null; then
    wsl.exe -d "$selected" -- cat "/home/$USER/.ssh/known_hosts" | tr -d '\r' > "$SSH_DIR/known_hosts"
    chmod 644 "$SSH_DIR/known_hosts"
fi

# ── Configure SSH for GitHub ─────────────────────────────────

if [ ! -f "$SSH_DIR/config" ]; then
    cat > "$SSH_DIR/config" << 'SSHCONFIG'
Host github.com
  HostName github.com
  User git
  IdentityFile ~/.ssh/id_ed25519
  IdentitiesOnly yes
SSHCONFIG
    chmod 600 "$SSH_DIR/config"
    info "Created ~/.ssh/config for GitHub"
fi

# ── Verify ───────────────────────────────────────────────────

echo ""
info "SSH keys imported successfully from $selected"
info "Key fingerprint:"
ssh-keygen -lf "$SSH_KEY.pub" 2>/dev/null || true
echo ""
info "Testing GitHub connection..."
ssh -T git@github.com 2>&1 | head -1 || true
echo ""
