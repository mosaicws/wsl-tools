#!/bin/bash
set -euo pipefail

# WSL2 User Setup
# Creates a user with sudo privileges and sets it as the default WSL login.
# Run as root on a fresh WSL2 instance.
#
# Usage:
#   apt update && apt install -y curl
#   curl -fsSL https://raw.githubusercontent.com/mosaicws/wsl-tools/main/user-setup.sh -o /tmp/user-setup.sh && bash /tmp/user-setup.sh

REPO_URL="https://api.github.com/repos/mosaicws/wsl-tools/contents"
REPO_RAW="https://raw.githubusercontent.com/mosaicws/wsl-tools/main"
TTY_IN=$([ -e /dev/tty ] && echo /dev/tty || echo /dev/stdin)

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

download_script() {
    curl -H "Accept: application/vnd.github.v3.raw" -fsSL "$REPO_URL/$1" 2>/dev/null \
        || curl -fsSL "$REPO_RAW/$1"
}

if [ "$(id -u)" -ne 0 ]; then
    error "This script must be run as root."
    exit 1
fi

if ! grep -qi microsoft /proc/version 2>/dev/null; then
    error "This script is designed to run inside WSL2."
    exit 1
fi

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║     WSL2 User Setup                                  ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""

read -rp "Enter username to create: " username < "$TTY_IN"
[ -z "$username" ] && { error "Username cannot be empty."; exit 1; }

if id "$username" &>/dev/null; then
    warn "User '$username' already exists."
    read -rp "Continue with configuring sudo and default login? [Y/n] " cont < "$TTY_IN"
    [[ "$cont" =~ ^[Nn]$ ]] && exit 0
else
    info "Creating user '$username'..."
    useradd -m -s /bin/bash "$username"
    info "Set password for '$username':"
    passwd "$username" < "$TTY_IN"
fi

# Install sudo and curl if needed
if ! command -v sudo &>/dev/null || ! command -v curl &>/dev/null || ! command -v ssh &>/dev/null; then
    info "Installing required packages..."
    apt-get update -qq && apt-get install -y -qq sudo curl openssh-client
fi

if ! groups "$username" | grep -q '\bsudo\b'; then
    info "Adding '$username' to sudo group..."
    usermod -aG sudo "$username"
fi

# Write wsl.conf cleanly (always overwrite — this is initial setup)
info "Configuring WSL..."
cat > /etc/wsl.conf << EOF
[boot]
systemd=true

[interop]
enabled=true
appendWindowsPath=true

[user]
default=$username
EOF

# Bashrc additions for the new user
bashrc="/home/$username/.bashrc"
if ! grep -q 'MANAGED BY WSL-TOOLS' "$bashrc" 2>/dev/null; then
    cat >> "$bashrc" << 'BASHRC'

# BEGIN MANAGED BY WSL-TOOLS
[[ "$PWD" == /mnt/* || "$PWD" == "/" ]] && cd ~
alias cls='clear'
# END MANAGED BY WSL-TOOLS
BASHRC
    chown "$username:$username" "$bashrc"
fi

echo ""
info "User '$username' is ready."

# Offer SSH key import if wsl.exe is available
if command -v wsl.exe &>/dev/null; then
    read -rp "Import SSH keys from another WSL instance now? [Y/n] " import_ssh < "$TTY_IN"
    if [[ ! "$import_ssh" =~ ^[Nn]$ ]]; then
        tmpscript=$(mktemp /tmp/ssh-import.XXXXXX)
        download_script "ssh-import.sh" > "$tmpscript"
        chmod 755 "$tmpscript"
        # Run as root with target user's identity — avoids su TTY issues
        HOME="/home/$username" USER="$username" bash "$tmpscript"
        chown -R "$username:$username" "/home/$username/.ssh" 2>/dev/null || true
        rm -f "$tmpscript"
    fi
else
    warn "Windows interop not available in this session."
    echo "  Restart WSL, then run:"
    echo "  curl -fsSL $REPO_RAW/ssh-import.sh -o /tmp/ssh-import.sh && bash /tmp/ssh-import.sh"
fi

# Switch to new user (only when run standalone, not from wsl-tools menu)
if [ -z "${WSL_TOOLS_MENU:-}" ]; then
    echo ""
    info "Switching to '$username'..."
    exec su - "$username"
fi
