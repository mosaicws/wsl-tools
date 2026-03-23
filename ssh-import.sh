#!/bin/bash
set -euo pipefail

# WSL2 SSH Key Importer
# Scans other WSL instances for SSH keys and imports them interactively.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/mosaicws/wsl-tools/main/ssh-import.sh -o /tmp/ssh-import.sh && bash /tmp/ssh-import.sh

SSH_DIR="$HOME/.ssh"
SSH_KEY="$SSH_DIR/id_ed25519"
TTY_IN=$([ -e /dev/tty ] && echo /dev/tty || echo /dev/stdin)

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

# WSL2 check
if ! grep -qi microsoft /proc/version 2>/dev/null; then
    error "This script is designed to run inside WSL2."
    exit 1
fi

mkdir -p "$SSH_DIR" && chmod 700 "$SSH_DIR"

if [ -f "$SSH_KEY" ]; then
    info "SSH key already exists at $SSH_KEY"
    ssh-keygen -lf "$SSH_KEY.pub" 2>/dev/null || true
    echo ""
    read -rp "Overwrite with a key from another WSL instance? [y/N] " overwrite < "$TTY_IN"
    if [[ ! "$overwrite" =~ ^[Yy]$ ]]; then
        info "Keeping existing key."
        exit 0
    fi
fi

if ! command -v wsl.exe &>/dev/null; then
    error "wsl.exe not available. Windows interop may be disabled in /etc/wsl.conf"
    exit 1
fi

info "Scanning WSL instances for SSH keys..."

# Get distro list once, detect current distro
all_distros=$(wsl.exe -l -q 2>/dev/null | iconv -f UTF-16LE -t UTF-8 | tr -d '\r' | sed '/^$/d')
current_distro="${WSL_DISTRO_NAME:-$(echo "$all_distros" | head -1)}"

candidates=()
menu_items=()
declare -A pub_keys

while IFS= read -r distro; do
    if [ -z "$distro" ]; then continue; fi
    if [ "$distro" = "$current_distro" ]; then
        echo "  Skipping $distro (current instance)" >&2
        continue
    fi

    echo -n "  Checking $distro... " >&2
    # Single call: test existence and read pub key in one shot
    pub=$(wsl.exe -d "$distro" -- cat "/home/$USER/.ssh/id_ed25519.pub" 2>/dev/null | tr -d '\r') || true
    if [ -n "$pub" ]; then
        candidates+=("$distro")
        comment=$(echo "$pub" | awk '{print $3}')
        menu_items+=("$distro" "${comment:-SSH key found}")
        pub_keys["$distro"]="$pub"
        echo "found key" >&2
    else
        echo "no key" >&2
    fi
done <<< "$all_distros"

echo "  Found ${#candidates[@]} distro(s) with keys (excluded self: ${current_distro:-none})" >&2

if [ ${#candidates[@]} -eq 0 ]; then
    warn "No other WSL instances found with SSH keys for user '$USER'"
    echo ""
    echo "Copy keys manually via Windows Explorer:"
    echo "  From: \\\\wsl\$\\<source-distro>\\home\\$USER\\.ssh\\"
    echo "  To:   \\\\wsl\$\\${WSL_DISTRO_NAME:-this-distro}\\home\\$USER\\.ssh\\"
    echo "  Files: id_ed25519, id_ed25519.pub, known_hosts"
    exit 1
fi

# Selection — whiptail if available, numbered list otherwise
if command -v whiptail &>/dev/null && [ -e /dev/tty ]; then
    selected=$(whiptail --title "SSH Key Import" \
        --menu "Select the WSL instance to copy SSH keys from:" \
        16 70 ${#candidates[@]} \
        "${menu_items[@]}" \
        3>&1 1>&2 2>&3) || { warn "Selection cancelled."; exit 1; }
else
    echo ""
    echo "Available WSL instances with SSH keys:"
    for i in "${!candidates[@]}"; do
        echo "  $((i+1))) ${candidates[$i]}  (${menu_items[$((i*2+1))]})"
    done
    echo ""
    read -rp "Select [1-${#candidates[@]}]: " choice < "$TTY_IN"
    if [[ ! "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt ${#candidates[@]} ]; then
        error "Invalid selection."; exit 1
    fi
    selected="${candidates[$((choice-1))]}"
fi

# Confirmation using cached pub key
echo ""
echo "Source:     $selected"
echo "Public key: ${pub_keys[$selected]}"
echo "Target:     $SSH_DIR/"
echo ""
read -rp "Proceed? [Y/n] " confirm < "$TTY_IN"
if [[ "$confirm" =~ ^[Nn]$ ]]; then
    warn "Import cancelled."; exit 1
fi

# Copy keys — cat directly (skip test, handle missing gracefully)
info "Copying SSH keys from $selected..."
wsl.exe -d "$selected" -- cat "/home/$USER/.ssh/id_ed25519" 2>/dev/null | tr -d '\r' > "$SSH_KEY"
chmod 600 "$SSH_KEY"

wsl.exe -d "$selected" -- cat "/home/$USER/.ssh/id_ed25519.pub" 2>/dev/null | tr -d '\r' > "$SSH_KEY.pub" || true
[ -f "$SSH_KEY.pub" ] && chmod 644 "$SSH_KEY.pub"

wsl.exe -d "$selected" -- cat "/home/$USER/.ssh/known_hosts" 2>/dev/null | tr -d '\r' > "$SSH_DIR/known_hosts" || true
[ -f "$SSH_DIR/known_hosts" ] && chmod 644 "$SSH_DIR/known_hosts"

# GitHub SSH config
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

echo ""
info "SSH keys imported successfully from $selected"
ssh-keygen -lf "$SSH_KEY.pub" 2>/dev/null || true
echo ""
if command -v ssh &>/dev/null; then
    info "Testing GitHub connection..."
    ssh -T git@github.com 2>&1 | head -1 || true
fi
echo ""
