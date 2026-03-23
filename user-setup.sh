#!/bin/bash
set -euo pipefail

# WSL2 User Setup
# Creates a user with sudo privileges and sets it as the default WSL login.
# Run as root on a fresh WSL2 instance.
#
# Usage:
#   apt update && apt install -y curl
#   curl -fsSL https://raw.githubusercontent.com/mosaicws/wsl-tools/main/user-setup.sh | bash

# ── Colours ──────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

# ── Pre-flight checks ───────────────────────────────────────

if [ "$(id -u)" -ne 0 ]; then
    error "This script must be run as root."
    echo "  On a fresh WSL instance, you should already be root."
    exit 1
fi

if [ ! -f /proc/version ] || ! grep -qi microsoft /proc/version 2>/dev/null; then
    error "This script is designed to run inside WSL2."
    exit 1
fi

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║     WSL2 User Setup                                  ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""

# ── Get username ─────────────────────────────────────────────

read -rp "Enter username to create: " username < /dev/tty

if [ -z "$username" ]; then
    error "Username cannot be empty."
    exit 1
fi

# Check if user already exists
if id "$username" &>/dev/null; then
    warn "User '$username' already exists."
    read -rp "Continue with configuring sudo and default login? [Y/n] " cont < /dev/tty
    if [[ "$cont" =~ ^[Nn]$ ]]; then
        exit 0
    fi
else
    # ── Create user ──────────────────────────────────────────
    info "Creating user '$username'..."
    useradd -m -s /bin/bash "$username"

    info "Set password for '$username':"
    passwd "$username" < /dev/tty
fi

# ── Configure sudo ───────────────────────────────────────────

# Ensure sudo and curl are installed
info "Installing required packages..."
apt-get update -qq && apt-get install -y -qq sudo curl

# Add to sudo group
if ! groups "$username" | grep -q '\bsudo\b'; then
    info "Adding '$username' to sudo group..."
    usermod -aG sudo "$username"
else
    info "User '$username' is already in the sudo group."
fi

# ── Set as default WSL user ──────────────────────────────────

info "Configuring '$username' as default WSL login user..."

# Ensure wsl.conf exists with correct sections
if [ -f /etc/wsl.conf ]; then
    # Update existing file
    if grep -q '^\[user\]' /etc/wsl.conf; then
        # Replace existing default= line under [user]
        sed -i '/^\[user\]/,/^\[/{s/^default=.*/default='"$username"'/}' /etc/wsl.conf
        # If no default= line exists under [user], add it
        if ! grep -q "^default=$username" /etc/wsl.conf; then
            sed -i '/^\[user\]/a default='"$username" /etc/wsl.conf
        fi
    else
        # Append [user] section
        printf '\n[user]\ndefault=%s\n' "$username" >> /etc/wsl.conf
    fi
else
    # Create new wsl.conf
    cat > /etc/wsl.conf << EOF
[boot]
systemd=true

[interop]
enabled=true
appendWindowsPath=true

[user]
default=$username
EOF
fi

# Ensure interop section exists in wsl.conf (for existing files too)
if ! grep -q '^\[interop\]' /etc/wsl.conf; then
    printf '\n[interop]\nenabled=true\nappendWindowsPath=true\n' >> /etc/wsl.conf
fi

# Ensure shell starts in home directory (not /mnt/c/Users/...)
if ! grep -q 'cd ~' "/home/$username/.bashrc" 2>/dev/null; then
    cat >> "/home/$username/.bashrc" << 'BASHRC'

# Start in home directory (not Windows mount)
if [ "$(pwd)" = "/" ] || echo "$(pwd)" | grep -q '^/mnt/'; then
    cd ~
fi

# Aliases
alias cls='clear'
BASHRC
    chown "$username:$username" "/home/$username/.bashrc"
fi

# ── SSH key import ────────────────────────────────────────────

echo ""
info "User '$username' is ready."

# Check if wsl.exe interop is available
if command -v wsl.exe &>/dev/null; then
    echo ""
    read -rp "Import SSH keys from another WSL instance now? [Y/n] " import_ssh < /dev/tty

    if [[ ! "$import_ssh" =~ ^[Nn]$ ]]; then
        # Download and run as the new user with tty access
        tmpscript=$(mktemp)
        curl -fsSL https://raw.githubusercontent.com/mosaicws/wsl-tools/main/ssh-import.sh > "$tmpscript"
        chmod +x "$tmpscript"
        su - "$username" -c "bash $tmpscript" < /dev/tty
        rm -f "$tmpscript"
    fi
else
    warn "Windows interop (wsl.exe) is not available in this session."
    echo ""
    echo "  To import SSH keys, restart this WSL instance first:"
    echo ""
    echo "    1. Exit this session (type 'exit' twice)"
    echo "    2. From PowerShell: wsl --terminate ${WSL_DISTRO_NAME:-<distro>}"
    echo "    3. Reopen: wsl -d ${WSL_DISTRO_NAME:-<distro>}"
    echo "    4. Run: curl -fsSL https://raw.githubusercontent.com/mosaicws/wsl-tools/main/ssh-import.sh | bash"
    echo ""
fi

# ── Switch to new user ───────────────────────────────────────

echo ""
info "Switching to '$username'..."
exec su - "$username"
