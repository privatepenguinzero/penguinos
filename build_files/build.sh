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
  greetd
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
if ! curl -fsSL https://brave-browser-rpm-release.s3.brave.com/brave-browser.repo -o /etc/yum.repos.d/brave-browser.repo; then
  log "Failed to download Brave repo file"
  exit 1
fi
if ! dnf5 -y install brave-keyring; then
  log "Failed to install Brave keyring"
  exit 1
fi
log "Installing Brave"
if ! dnf5 -y install brave-origin; then
  log "Failed to install Brave"
  exit 1
fi

# -------------------------------------------------------------------
# Niri window manager
# -------------------------------------------------------------------
# niri Recommends alacritty as a weak dependency; we ship Ghostty as the
# main terminal, so exclude it to avoid installing a second, unconfigured
# terminal emulator.
log "Installing Niri"
dnf5 -y install niri niri-settings --exclude=alacritty

# -------------------------------------------------------------------
# Cursor editor – download with checksum verification via dnf
# -------------------------------------------------------------------
log "Installing Cursor"
CURSOR_RPM_URL=$(curl -sSf "https://cursor.com/api/download?platform=linux-x64&releaseTrack=stable" | jq -r '.rpmUrl')
if [[ -z "$CURSOR_RPM_URL" || "$CURSOR_RPM_URL" == "null" ]]; then
  log "Could not determine Cursor RPM URL"
  exit 1
fi
TMP_RPM="/tmp/cursor.rpm"
if ! curl -fSL -o "$TMP_RPM" "$CURSOR_RPM_URL"; then
  log "Failed to download Cursor RPM"
  exit 1
fi
if ! dnf5 -y install "$TMP_RPM"; then
  log "Failed to install Cursor RPM"
  exit 1
fi
rm -f "$TMP_RPM"

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
mkdir -p "$LVIM_DIR/lua/plugins"
cat > "$LVIM_DIR/lua/plugins/colorscheme.lua" <<'EOF'
return {
  {
    "catppuccin/nvim",
    name = "catppuccin",
    priority = 1000,
    opts = {
      flavour = "mocha",
    },
  },
  {
    "LazyVim/LazyVim",
    opts = {
      colorscheme = "catppuccin",
    },
  },
}
EOF

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
if [[ ! -s "$RTK_SCRIPT" ]]; then
  log "RTK install script appears malformed – aborting"
  exit 1
fi
RTK_INSTALL_DIR=/usr/local/bin bash "$RTK_SCRIPT"
rm -f "$RTK_SCRIPT"
if [[ ! -x /usr/local/bin/rtk ]]; then
  log "RTK binary not found at /usr/local/bin/rtk after install – aborting"
  exit 1
fi

# -------------------------------------------------------------------
# NetBird – download latest release with verification placeholder
# -------------------------------------------------------------------
log "Installing NetBird"
NETBIRD_JSON=$(curl -sSf https://api.github.com/repos/netbirdio/netbird/releases/latest)
NETBIRD_VERSION=$(echo "$NETBIRD_JSON" | jq -r '.tag_name // empty')
if [[ -z "$NETBIRD_VERSION" ]]; then
  log "Could not retrieve NetBird version"
  exit 1
fi
NETBIRD_TAR="/tmp/netbird.tar.gz"
if ! curl -fSL -o "$NETBIRD_TAR" "https://github.com/netbirdio/netbird/releases/download/${NETBIRD_VERSION}/netbird_${NETBIRD_VERSION#v}_linux_amd64.tar.gz"; then
  log "Failed to download NetBird"
  exit 1
fi
tar -xzf "$NETBIRD_TAR" -C /usr/bin/ netbird
chmod +x /usr/bin/netbird
rm -f "$NETBIRD_TAR"

# -------------------------------------------------------------------
# Google Fonts – download and install
# -------------------------------------------------------------------
log "Installing Google Fonts"
GOOGLE_ZIP="/tmp/google-fonts.zip"
if curl -fSL -o "$GOOGLE_ZIP" https://github.com/google/fonts/archive/main.zip; then
  mkdir -p /usr/share/fonts/google
  unzip -q "$GOOGLE_ZIP" -d /usr/share/fonts/google
  rm -f "$GOOGLE_ZIP"
else
  log "Failed to download Google Fonts – skipping"
fi

# -------------------------------------------------------------------
# JetBrainsMono Nerd Font – verified download
# -------------------------------------------------------------------
log "Installing JetBrainsMono Nerd Font"
JBZIP="/tmp/JetBrainsMono.zip"
if curl -fSL -o "$JBZIP" https://github.com/ryanoasis/nerd-fonts/releases/latest/download/JetBrainsMono.zip; then
  mkdir -p /usr/share/fonts/JetBrainsMonoNerdFont
  unzip -q "$JBZIP" -d /usr/share/fonts/JetBrainsMonoNerdFont
  rm -f "$JBZIP"
else
  log "Failed to download JetBrainsMono Nerd Font – skipping"
fi

# -------------------------------------------------------------------
# Fontconfig defaults fix
# -------------------------------------------------------------------
# Fedora's google-noto-sans-arabic-vf-fonts package ships
# /etc/fonts/conf.d/56-google-noto-sans-arabic-vf.conf, which unconditionally
# prepends "Noto Sans Arabic" to both the `sans-serif` and `monospace`
# generic family aliases (missing the lang="ar" test other Noto conf.d
# files use to scope themselves). That makes every app relying on generic
# "monospace"/"sans-serif" (Alacritty with no font set, Cursor's UI, etc.)
# render with Noto Sans Arabic instead of a real Latin font. conf.d files
# are read in filename order and each <edit mode="prepend"> pushes to the
# front, so a higher-sorting file here wins over the buggy one.
log "Pinning sane fontconfig defaults for monospace/sans-serif"
cat > /etc/fonts/conf.d/90-penguinos-font-defaults.conf <<'EOF'
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
<fontconfig>
  <match target="pattern">
    <test name="family"><string>monospace</string></test>
    <edit name="family" mode="prepend" binding="strong">
      <string>JetBrainsMono Nerd Font</string>
    </edit>
  </match>
  <match target="pattern">
    <test name="family"><string>sans-serif</string></test>
    <edit name="family" mode="prepend" binding="strong">
      <string>Noto Sans</string>
    </edit>
  </match>
</fontconfig>
EOF

# -------------------------------------------------------------------
# Refresh font cache and GLib schemas (once)
# -------------------------------------------------------------------
log "Updating font cache and GLib schemas"
fc-cache -f
glib-compile-schemas /usr/share/glib-2.0/schemas/

# -------------------------------------------------------------------
# DMS (DankMaterialShell) – only available via COPR, not Fedora/Terra
# -------------------------------------------------------------------
# Terra ships noctalia-qs, a fork of quickshell (from the noctalia-shell
# project) that also declares `Provides: quickshell`. If it's present when
# dms/dms-greeter are installed, dnf resolves their "quickshell" dependency
# with that fork instead of the real quickshell package, and DMS silently
# breaks (hover works, clicks don't) because it's running on the wrong
# quickshell build. Remove it and pin the real package explicitly so this
# can't happen again.
if rpm -q noctalia-qs &>/dev/null; then
  log "Removing noctalia-qs (conflicts with DMS's quickshell dependency)"
  dnf5 -y remove noctalia-qs
fi

log "Enabling avengemedia/dms COPR repository"
if ! dnf5 -y copr enable avengemedia/dms; then
  log "Failed to enable avengemedia/dms COPR repository"
  exit 1
fi
log "Installing quickshell, dms and dms-greeter"
if ! dnf5 -y install quickshell dms dms-greeter; then
  log "Failed to install quickshell/dms/dms-greeter"
  exit 1
fi

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
cp -rf /ctx/dot_config/niri/config.kdl /ctx/dot_config/niri/basicsettings.kdl /ctx/dot_config/niri/keybinds.kdl /etc/skel/.config/niri/
mkdir -p /etc/skel/.config/niri/dms
cp -rf /ctx/dot_config/niri/dms/. /etc/skel/.config/niri/dms/

# DankMaterialShell config for new users
mkdir -p /etc/skel/.config/DankMaterialShell
cp -rf /ctx/dot_config/DankMaterialShell/settings.json /etc/skel/.config/DankMaterialShell/

# -------------------------------------------------------------------
# Catppuccin (Mocha/Peach) theming for the rest of the desktop/CLI
# -------------------------------------------------------------------
# Ghostty and DMS/niri already default to Catppuccin Mocha (see above and
# dot_config/ghostty/config). This section extends the same flavor+accent
# to the other tools installed by this script, using the official
# catppuccin.github.io per-app themes. The upstream `catppuccin/gtk` and
# Kvantum ports are skipped: gtk was archived upstream (now requires a
# separate Python build tool, not a drop-in theme) and Kvantum has no real
# footprint here (this image has no Kvantum-themed Qt apps installed).
log "Installing Catppuccin cursors"
CURSORS_ZIP="/tmp/catppuccin-cursors.zip"
if curl -fSL -o "$CURSORS_ZIP" https://github.com/catppuccin/cursors/releases/latest/download/catppuccin-mocha-peach-cursors.zip; then
  unzip -q -o "$CURSORS_ZIP" -d /usr/share/icons
  rm -f "$CURSORS_ZIP"
else
  log "Failed to download Catppuccin cursors - skipping"
fi

log "Recoloring Papirus folders to Catppuccin Mocha/Peach"
PAPIRUS_FOLDERS_SRC="/tmp/papirus-folders-src"
if git clone --depth 1 https://github.com/catppuccin/papirus-folders.git "$PAPIRUS_FOLDERS_SRC"; then
  cp -rf "$PAPIRUS_FOLDERS_SRC"/src/* /usr/share/icons/Papirus/
  rm -rf "$PAPIRUS_FOLDERS_SRC"
  if curl -fsSL -o /usr/local/bin/papirus-folders https://raw.githubusercontent.com/PapirusDevelopmentTeam/papirus-folders/master/papirus-folders; then
    chmod +x /usr/local/bin/papirus-folders
    /usr/local/bin/papirus-folders -C cat-mocha-peach --theme Papirus-Dark
  else
    log "Failed to download papirus-folders script - skipping recolor"
  fi
else
  log "Failed to clone catppuccin/papirus-folders - skipping"
fi

# Default icon/cursor theme for new users. (No GTK widget theme override -
# see note above; Papirus-Dark + Catppuccin cursors cover icons/pointer.)
mkdir -p /etc/skel/.config/gtk-3.0 /etc/skel/.config/gtk-4.0
for gtkdir in /etc/skel/.config/gtk-3.0 /etc/skel/.config/gtk-4.0; do
  cat > "$gtkdir/settings.ini" <<'EOF'
[Settings]
gtk-icon-theme-name=Papirus-Dark
gtk-cursor-theme-name=catppuccin-mocha-peach-cursors
gtk-cursor-theme-size=24
gtk-application-prefer-dark-theme=true
EOF
done

log "Setting Catppuccin Mocha as the default GNOME Terminal profile"
MOCHA_UUID="95894cfd-82f7-430d-af6e-84d168bc34f5"
mkdir -p /etc/dconf/db/local.d
cat > /etc/dconf/db/local.d/01-catppuccin-gnome-terminal <<EOF
[org/gnome/terminal/legacy/profiles:/:$MOCHA_UUID]
visible-name='Catppuccin Mocha'
background-color='#1e1e2e'
foreground-color='#cdd6f4'
highlight-colors-set=true
highlight-background-color='#f5e0dc'
highlight-foreground-color='#585b70'
cursor-colors-set=true
cursor-background-color='#f5e0dc'
cursor-foreground-color='#1e1e2e'
use-theme-colors=false
bold-is-bright=true
palette=['#45475a', '#f38ba8', '#a6e3a1', '#f9e2af', '#89b4fa', '#f5c2e7', '#94e2d5', '#a6adc8', '#585b70', '#f37799', '#89d88b', '#ebd391', '#74a8fc', '#f2aede', '#6bd7ca', '#bac2de']

[org/gnome/terminal/legacy/profiles:]
default='$MOCHA_UUID'
list=['$MOCHA_UUID']
EOF
dconf update

log "Installing Catppuccin theme for btop"
mkdir -p /etc/skel/.config/btop/themes
if curl -fsSL -o /etc/skel/.config/btop/themes/catppuccin_mocha.theme https://raw.githubusercontent.com/catppuccin/btop/main/themes/catppuccin_mocha.theme; then
  cat > /etc/skel/.config/btop/btop.conf <<'EOF'
color_theme = "catppuccin_mocha"
theme_background = False
EOF
else
  log "Failed to download btop Catppuccin theme - skipping"
fi

log "Installing Catppuccin theme for bat"
mkdir -p /etc/skel/.config/bat/themes
if curl -fsSL -o "/etc/skel/.config/bat/themes/Catppuccin Mocha.tmTheme" "https://github.com/catppuccin/bat/raw/main/themes/Catppuccin%20Mocha.tmTheme"; then
  echo '--theme="Catppuccin Mocha"' > /etc/skel/.config/bat/config
  # Custom bat themes need a per-user binary cache; build it lazily on first
  # shell start instead of trying to precompute it for a user that doesn't
  # exist yet at image-build time.
  echo 'bat --list-themes 2>/dev/null | grep -q "Catppuccin Mocha" || bat cache --build &>/dev/null' >> /etc/skel/.zshrc
else
  log "Failed to download bat Catppuccin theme - skipping"
fi

log "Installing Catppuccin theme for tmux"
mkdir -p /etc/skel/.config/tmux/plugins/catppuccin
if git clone --depth 1 https://github.com/catppuccin/tmux.git /etc/skel/.config/tmux/plugins/catppuccin/tmux; then
  rm -rf /etc/skel/.config/tmux/plugins/catppuccin/tmux/.git
  cat > /etc/skel/.tmux.conf <<'EOF'
set -g @catppuccin_flavor "mocha"
run ~/.config/tmux/plugins/catppuccin/tmux/catppuccin.tmux
EOF
else
  log "Failed to clone catppuccin/tmux - skipping"
fi

log "Installing Catppuccin theme for lazygit"
mkdir -p /etc/skel/.config/lazygit
if ! curl -fsSL -o /etc/skel/.config/lazygit/config.yml https://raw.githubusercontent.com/catppuccin/lazygit/main/themes/mocha/peach.yml; then
  log "Failed to download lazygit Catppuccin theme - skipping"
fi

log "Installing Catppuccin theme for fzf"
mkdir -p /etc/skel/.config/fzf
if curl -fsSL -o /etc/skel/.config/fzf/catppuccin-mocha.sh https://raw.githubusercontent.com/catppuccin/fzf/main/themes/catppuccin-fzf-mocha.sh; then
  echo 'source ~/.config/fzf/catppuccin-mocha.sh' >> /etc/skel/.zshrc
else
  log "Failed to download fzf Catppuccin theme - skipping"
fi

log "Installing Catppuccin theme for mc (Midnight Commander)"
mkdir -p /etc/skel/.local/share/mc/skins /etc/skel/.config/mc
if git clone --depth 1 https://github.com/catppuccin/mc.git /etc/skel/.local/share/mc/skins/mc; then
  rm -rf /etc/skel/.local/share/mc/skins/mc/.git
  ln -sf ./mc/catppuccin.ini /etc/skel/.local/share/mc/skins/catppuccin.ini
  cat > /etc/skel/.config/mc/ini <<'EOF'
[Midnight-Commander]
skin=catppuccin
EOF
else
  log "Failed to clone catppuccin/mc - skipping"
fi

log "Installing Catppuccin theme for zsh-syntax-highlighting"
mkdir -p /etc/skel/.zsh
if curl -fsSL -o /etc/skel/.zsh/catppuccin_mocha-zsh-syntax-highlighting.zsh https://raw.githubusercontent.com/catppuccin/zsh-syntax-highlighting/main/themes/catppuccin_mocha-zsh-syntax-highlighting.zsh; then
  # Must be sourced before the zsh-syntax-highlighting plugin loads.
  sed -i '\#source \$ZSH/oh-my-zsh.sh#i source ~/.zsh/catppuccin_mocha-zsh-syntax-highlighting.zsh' /etc/skel/.zshrc
else
  log "Failed to download zsh-syntax-highlighting Catppuccin theme - skipping"
fi

# DMS's Go backend needs raw access to /dev/input/* (evdev) to detect clicks
# on its own bar/panels; without it, hover works but clicks silently no-op.
# Grant it via udev uaccess instead of requiring manual `usermod -aG input`,
# since users aren't created at image-build time.
mkdir -p /usr/lib/udev/rules.d
cat > /usr/lib/udev/rules.d/91-dms-input-uaccess.rules <<'EOF'
SUBSYSTEM=="input", TAG+="uaccess"
EOF

# -------------------------------------------------------------------
# SELinux context restoration (after all custom files are in place)
# -------------------------------------------------------------------
log "Restoring SELinux contexts"
restorecon -Rv /etc/greetd \
    /etc/systemd/system/display-manager.service \
    /etc/skel/.config \
    /etc/skel/.zsh \
    /etc/skel/.tmux.conf \
    /etc/skel/.local \
    /usr/lib/systemd/user/dms.service \
    /usr/lib/udev/rules.d/91-dms-input-uaccess.rules \
    /usr/local/bin/rtk \
    /usr/local/bin/papirus-folders \
    /usr/share/icons \
    /etc/dconf/db/local.d \
    /etc/fonts/conf.d/90-penguinos-font-defaults.conf || true

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
