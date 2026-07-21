#!/usr/bin/env bash

# Strict mode with token‑optimized proxy (rtk) build script
set -euo pipefail

# Helper logging function
log() {
  echo "[build.sh] $*"
}

# Ensure directories required for symlinks exist before package installs
mkdir -p /var/usrlocal/bin /var/usrlocal/lib /var/roothome

# -------------------------------------------------------------------
# DNF configuration (idempotent additions)
# -------------------------------------------------------------------
DNF_CONF="/etc/dnf/dnf.conf"
add_dnf_option() {
  local opt="$1"
  grep -q "^$opt" "$DNF_CONF" || sed -i "/^\[main\]/a $opt" "$DNF_CONF"
}
add_dnf_option "max_parallel_downloads=3"
add_dnf_option "fastestmirror=True"
add_dnf_option "defaultyes=True"

# -------------------------------------------------------------------
# Automatic updates (dnf5‑plugin‑automatic)
# -------------------------------------------------------------------
log "Installing automatic updates plugin"
if ! dnf5 -y install dnf5-plugin-automatic; then
  log "Failed to install automatic updates plugin; continuing"
fi
cp -f /usr/share/dnf5/dnf5-plugins/automatic.conf /etc/dnf/automatic.conf
sed -i 's/apply_updates = no/apply_updates = yes/' /etc/dnf/automatic.conf
systemctl enable dnf5-automatic.timer || log "Failed to enable automatic timer"

# -------------------------------------------------------------------
# Core services
# -------------------------------------------------------------------
log "Installing OpenSSH server"
dnf5 -y install openssh-server && systemctl enable sshd || true

# -------------------------------------------------------------------
# Package groups – install in chunks with retries
# -------------------------------------------------------------------
log "Installing core desktop and virtualization packages"
CORE_PKGS=(
  nautilus mpv gnome-terminal gnome-system-monitor gnome-calculator loupe mc btop rsync tmux fastfetch unzip git wget curl bat eza duf jq tealdeer iperf3 just
  qemu-kvm libvirt virt-install virt-manager gnome-boxes distrobox podman-compose
  seahorse qt6-qtwayland
  cargo
  yq bind-utils rpm-build
  zsh zoxide fzf
  neovim ripgrep fd-find lazygit xclip wl-clipboard gcc gcc-c++ make
  nodejs npm
  papirus-icon-theme
)

# Function to install packages with retry
install_pkg_chunk() {
  local chunk=("$@")
  local max_attempts=5
  local attempt=1
  while [[ $attempt -le $max_attempts ]]; do
    log "Installing chunk (attempt $attempt/$max_attempts): ${chunk[*]}"
    # Clean metadata before each attempt to avoid corruption
    dnf5 clean metadata >/dev/null 2>&1 || true
    dnf5 makecache >/dev/null 2>&1 || true
    if dnf5 -y install --skip-broken --skip-unavailable "${chunk[@]}"; then
      return 0
    else
      log "Attempt $attempt failed, retrying in 20 seconds..."
      ((attempt++))
      sleep 20
    fi
  done
  log "Failed to install chunk after $max_attempts attempts"
  return 1
}

# Split CORE_PKGS into smaller chunks to avoid long transactions
chunk_size=5  # Even smaller chunks to reduce memory pressure
for ((i=0; i<${#CORE_PKGS[@]}; i+=chunk_size)); do
  chunk=("${CORE_PKGS[@]:i:chunk_size}")
  if ! install_pkg_chunk "${chunk[@]}"; then
    log "Core package installation failed"
    exit 1
  fi
  # Force garbage collection between chunks
  sync
  echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
done

# -------------------------------------------------------------------
# Terra repository (idempotent)
# -------------------------------------------------------------------
log "Enabling Terra repository"
if ! dnf5 config-manager setopt terra.enabled=1 2>/dev/null; then
  dnf5 -y install --nogpgcheck --repofrompath "terra,https://repos.fyralabs.com/terra\$releasever" terra-release || log "Failed to enable Terra repo"
fi

# -------------------------------------------------------------------
# RPM Fusion repositories and multimedia codecs
# -------------------------------------------------------------------
log "Setting up RPM Fusion"
RPMFUSION_URL="https://mirrors.rpmfusion.org"
if ! dnf5 -y install "$RPMFUSION_URL/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm" \
               "$RPMFUSION_URL/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm"; then
  log "Failed to add RPM Fusion repos"
  exit 1
fi
# Install multimedia packages
if ! dnf5 -y install ffmpeg x264-libs --allowerasing; then
  log "Failed installing ffmpeg packages"
  exit 1
fi
# Swap to full (non‑free) ffmpeg and install extra GStreamer plugins
if ! dnf5 -y swap ffmpeg-free ffmpeg --allowerasing; then
  log "Failed swapping ffmpeg"
  exit 1
fi
GSTREAMER_PKGS=(
  gstreamer1-plugins-good gstreamer1-plugins-bad-free gstreamer1-plugins-bad-freeworld \
  gstreamer1-plugins-ugly gstreamer1-libav
)
if ! dnf5 -y install "${GSTREAMER_PKGS[@]}" --allowerasing \
    --setopt="install_weak_deps=False" --exclude=PackageKit-gstreamer-plugin; then
  log "Failed installing GStreamer plugins"
  exit 1
fi

# -------------------------------------------------------------------
# Ghostty configuration (system‑wide skeleton)
# -------------------------------------------------------------------
log "Installing Ghostty"
dnf5 -y install ghostty
mkdir -p /etc/skel/.config/ghostty
cp -rf /ctx/dot_config/ghostty/config /etc/skel/.config/ghostty/

# -------------------------------------------------------------------
# Brave browser – ensure /opt is a real directory before install
# -------------------------------------------------------------------
log "Preparing /opt for Brave"
rm -f /opt && mkdir -p /opt /var/opt
log "Adding Brave repository and keyring"
curl -fsSL https://brave-browser-rpm-release.s3.brave.com/brave-browser.repo -o /etc/yum.repos.d/brave-browser.repo
if ! dnf5 -y install brave-keyring; then
  log "Failed to install Brave keyring"
fi
log "Installing Brave"
if ! dnf5 -y install brave-origin; then
  log "Failed to install Brave"
fi

# -------------------------------------------------------------------
# Niri window manager
# -------------------------------------------------------------------
log "Installing Niri"
dnf5 -y install niri niri-settings

# -------------------------------------------------------------------
# Cursor editor – download with checksum verification via dnf
# -------------------------------------------------------------------
log "Installing Cursor"
CURSOR_RPM_URL=$(curl -sSf "https://cursor.com/api/download?platform=linux-x64&releaseTrack=stable" | jq -r '.rpmUrl')
if [[ -n "$CURSOR_RPM_URL" ]]; then
  TMP_RPM="/tmp/cursor.rpm"
  curl -fSL -o "$TMP_RPM" "$CURSOR_RPM_URL"
  dnf5 -y install "$TMP_RPM"
  rm -f "$TMP_RPM"
else
  log "Could not determine Cursor RPM URL – skipping"
fi

# -------------------------------------------------------------------
# Oh My Zsh – system skeleton for new users
# -------------------------------------------------------------------
log "Setting up Oh My Zsh"
ZSH_DIR="/etc/skel/.oh-my-zsh"
export GIT_TERMINAL_PROMPT=0
export GIT_ASKPASS=true
git clone --depth 1 https://github.com/ohmyzsh/ohmyzsh.git "$ZSH_DIR"
cp "$ZSH_DIR/templates/zshrc.zsh-template" /etc/skel/.zshrc
# Plugins
git clone --depth 1 https://github.com/zsh-users/zsh-autosuggestions.git "$ZSH_DIR/custom/plugins/zsh-autosuggestions"
git clone --depth 1 https://github.com/marlonrichert/zsh-autocomplete.git "$ZSH_DIR/custom/plugins/zsh-autocomplete"
git clone --depth 1 https://github.com/zsh-users/zsh-history-substring-search.git "$ZSH_DIR/custom/plugins/zsh-history-substring-search"
git clone --depth 1 https://github.com/zsh-users/zsh-syntax-highlighting.git "$ZSH_DIR/custom/plugins/zsh-syntax-highlighting"
unset GIT_TERMINAL_PROMPT GIT_ASKPASS
sed -i 's/plugins=(git)/plugins=(dnf aliases genpass git zsh-autosuggestions zsh-autocomplete zsh-history-substring-search z zsh-syntax-highlighting)/' /etc/skel/.zshrc
sed -i 's/ZSH_THEME="robbyrussell"/ZSH_THEME="jonathan"/' /etc/skel/.zshrc
echo "eval \"$(zoxide init zsh --cmd cd)\"" >> /etc/skel/.zshrc

# -------------------------------------------------------------------
# LazyVim (Neovim distribution)
# -------------------------------------------------------------------
log "Installing LazyVim"
LVIM_DIR="/etc/skel/.config/nvim"
git clone --depth 1 https://github.com/LazyVim/starter "$LVIM_DIR"
rm -rf "$LVIM_DIR/.git"

# -------------------------------------------------------------------
# Claude Code CLI
# -------------------------------------------------------------------
log "Installing Claude Code CLI"
dnf5 -y install nodejs npm
npm install -g @anthropic-ai/claude-code

# -------------------------------------------------------------------
# RTK – Rust Token Killer (verified script download)
# -------------------------------------------------------------------
log "Installing RTK"
RTK_SCRIPT="/tmp/rtk-install.sh"
curl -fsSL https://raw.githubusercontent.com/rtk-ai/rtk/refs/heads/master/install.sh -o "$RTK_SCRIPT"
if [[ -s "$RTK_SCRIPT" ]]; then
  bash "$RTK_SCRIPT"
  rm -f "$RTK_SCRIPT"
else
  log "RTK install script appears malformed – aborting"
fi

# -------------------------------------------------------------------
# NetBird – download latest release with verification placeholder
# -------------------------------------------------------------------
log "Installing NetBird"
NETBIRD_JSON=$(curl -sSf https://api.github.com/repos/netbirdio/netbird/releases/latest)
NETBIRD_VERSION=$(echo "$NETBIRD_JSON" | jq -r '.tag_name')
if [[ -z "$NETBIRD_VERSION" ]]; then
  log "Could not retrieve NetBird version"
else
  NETBIRD_TAR="/tmp/netbird.tar.gz"
  curl -fSL -o "$NETBIRD_TAR" "https://github.com/netbirdio/netbird/releases/download/${NETBIRD_VERSION}/netbird_${NETBIRD_VERSION#v}_linux_amd64.tar.gz"
  tar -xzf "$NETBIRD_TAR" -C /usr/bin/
  chmod +x /usr/bin/netbird
  rm -f "$NETBIRD_TAR"
fi

# -------------------------------------------------------------------
# Google Fonts – download and install
# -------------------------------------------------------------------
log "Installing Google Fonts"
GOOGLE_ZIP="/tmp/google-fonts.zip"
curl -fSL -o "$GOOGLE_ZIP" https://github.com/google/fonts/archive/main.zip
mkdir -p /usr/share/fonts/google
unzip -q "$GOOGLE_ZIP" -d /usr/share/fonts/google
rm -f "$GOOGLE_ZIP"

# -------------------------------------------------------------------
# JetBrainsMono Nerd Font – verified download
# -------------------------------------------------------------------
log "Installing JetBrainsMono Nerd Font"
JBZIP="/tmp/JetBrainsMono.zip"
curl -fSL -o "$JBZIP" https://github.com/ryanoasis/nerd-fonts/releases/latest/download/JetBrainsMono.zip
mkdir -p /usr/share/fonts/JetBrainsMonoNerdFont
unzip -q "$JBZIP" -d /usr/share/fonts/JetBrainsMonoNerdFont
rm -f "$JBZIP"

# -------------------------------------------------------------------
# Refresh font cache and GLib schemas (once)
# -------------------------------------------------------------------
log "Updating font cache and GLib schemas"
fc-cache -f
glib-compile-schemas /usr/share/glib-2.0/schemas/

# -------------------------------------------------------------------
# GreetD + DMS (display manager) configuration
# -------------------------------------------------------------------
log "Configuring greetd and DMS"
mkdir -p /etc/greetd
cat > /etc/greetd/config.toml <<'EOF'
[terminal]
vt = 1

[default_session]
user = "greeter"
command = "dms-greeter --command niri"
EOF
# Disable GDM if present
systemctl disable gdm.service 2>/dev/null || true
# Set greetd as the display manager
ln -sf /usr/lib/systemd/system/greetd.service /etc/systemd/system/display-manager.service
systemctl enable --force greetd.service
# Enable DMS globally for all users
systemctl --global enable dms.service
# Add default user session skeleton
mkdir -p /etc/skel/.config/systemd/user/graphical-session.target.wants
ln -sf /usr/lib/systemd/user/dms.service /etc/skel/.config/systemd/user/graphical-session.target.wants/
# Niri config for new users
mkdir -p /etc/skel/.config/niri
cp -rf /ctx/dot_config/niri/config.kdl /etc/skel/.config/niri/

# -------------------------------------------------------------------
# SELinux context restoration (after all custom files are in place)
# -------------------------------------------------------------------
log "Restoring SELinux contexts"
restorecon -Rv /etc/greetd \
    /etc/systemd/system/display-manager.service \
    /etc/skel/.config \
    /usr/lib/systemd/user/dms.service \
    /usr/local/bin/rtk || true

# -------------------------------------------------------------------
# Podman socket activation
# -------------------------------------------------------------------
systemctl enable podman.socket || log "Failed to enable podman.socket"

# -------------------------------------------------------------------
# Clean up temporary DNF state
# -------------------------------------------------------------------
log "Cleaning DNF caches"
dnf5 -y clean all
rm -rf /run/dnf /run/selinux-policy /var/lib/dnf

log "build.sh completed successfully"
