#!/usr/bin/env bash

# Strict mode with token‑optimized proxy (rtk) build script
set -euo pipefail

# Helper logging function
log() {
  echo "[build.sh] $*"
}

# Retry options shared by every download in this script.
#
# The image rebuilds on a nightly cron, so a one-off CDN hiccup breaks a build
# with nothing in the repo having changed: run 30434214100 died on
# "(35) Recv failure: Connection reset by peer" fetching a GitHub release asset
# that served fine seconds later, and only a manual rerun cleared it.
#
# --retry-all-errors is the part that matters. Plain --retry only covers
# transient HTTP responses (5xx, 408, 429) and timeouts; connection resets and
# TLS handshake failures need this flag as well. Cost of a genuinely dead URL
# is three extra attempts, roughly six seconds, which is far cheaper than
# losing a nightly image.
CURL_RETRY=(--retry 3 --retry-delay 2 --retry-all-errors)

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
# fastestmirror is deliberately not set: its mirror probing costs more time on
# CI runners than it saves. defaultyes is also left alone - this dnf.conf ships
# in the image, and making `dnf remove` default to yes is a footgun on a
# running system.
add_dnf_option "max_parallel_downloads=10"

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
  nautilus mpv gnome-terminal gnome-system-monitor gnome-calculator loupe mc btop rsync fastfetch unzip git wget curl bat eza duf jq tealdeer iperf3 just
  qemu-kvm libvirt virt-install virt-manager gnome-boxes distrobox podman-compose
  seahorse qt6-qtwayland
  cargo
  yq bind-utils rpm-build chezmoi
  zsh zoxide fzf starship
  neovim ripgrep fd-find lazygit git-delta gitleaks xclip wl-clipboard gcc gcc-c++ make
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
    # Only refresh metadata when retrying. Doing a full clean+makecache before
    # every chunk means re-downloading every repo's metadata a dozen times per
    # build; it only ever helps after a failure that suggests cache corruption.
    if [[ $attempt -gt 1 ]]; then
      dnf5 clean metadata >/dev/null 2>&1 || true
      dnf5 makecache >/dev/null 2>&1 || true
    fi
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
  sync
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
if ! curl "${CURL_RETRY[@]}" -fsSL https://brave-browser-rpm-release.s3.brave.com/brave-browser.repo -o /etc/yum.repos.d/brave-browser.repo; then
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
CURSOR_RPM_URL=$(curl "${CURL_RETRY[@]}" -sSf "https://cursor.com/api/download?platform=linux-x64&releaseTrack=stable" | jq -r '.rpmUrl')
if [[ -z "$CURSOR_RPM_URL" || "$CURSOR_RPM_URL" == "null" ]]; then
  log "Could not determine Cursor RPM URL"
  exit 1
fi
TMP_RPM="/tmp/cursor.rpm"
if ! curl "${CURL_RETRY[@]}" -fSL -o "$TMP_RPM" "$CURSOR_RPM_URL"; then
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
# The `z` plugin is deliberately absent: zoxide below already replaces `cd`
# with a frecency-ranked jumper, and `z` is a second one keeping its own
# database in ~/.z. Two jumpers means neither learns from the directories you
# visit through the other.
sed -i 's/plugins=(git)/plugins=(dnf aliases genpass git zsh-autosuggestions zsh-autocomplete zsh-history-substring-search zsh-syntax-highlighting)/' /etc/skel/.zshrc
# Starship draws the prompt, so Oh My Zsh must not draw one of its own: two
# prompt engines fight and the last one to run wins, unpredictably. Starship
# is already what this image gives bash (via ublue's bling.sh), so zsh gets
# the same prompt rather than a second, different one.
sed -i 's/ZSH_THEME="robbyrussell"/ZSH_THEME=""/' /etc/skel/.zshrc
# shellcheck disable=SC2016  # must reach .zshrc literally, like the zoxide line
echo 'eval "$(starship init zsh)"' >> /etc/skel/.zshrc
# Single quotes on purpose: the command substitution has to reach .zshrc as
# literal text and run when the shell starts. With double quotes bash expands
# it here, during the build, and bakes zoxide's ~100 lines of init output into
# the file wrapped in eval "..." - which then fails at every shell start with
# `command not found: __zoxide_pwd`, `no match found`, and a parse error.
# shellcheck disable=SC2016  # the non-expansion is the entire point
echo 'eval "$(zoxide init zsh --cmd cd)"' >> /etc/skel/.zshrc

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
# nodejs/npm come from CORE_PKGS above.
#
# --prefix /usr is load-bearing: on ostree systems /usr/local is a symlink to
# /var/usrlocal, and /var is machine-local state that `bootc upgrade` never
# updates. npm's default global prefix is /usr/local, so without this the CLI
# is written into a directory that simply isn't part of the shipped image.
log "Installing Claude Code CLI"
npm install -g --prefix /usr --no-fund --no-audit @anthropic-ai/claude-code
if [[ ! -x /usr/bin/claude ]]; then
  log "Claude Code CLI not found at /usr/bin/claude after install"
  exit 1
fi

# -------------------------------------------------------------------
# RTK – Rust Token Killer (verified script download)
# -------------------------------------------------------------------
# The installer is a shell script executed as root, so it is pinned to a commit
# rather than fetched from the master tip. Renovate watches the branch and opens
# a PR when the SHA moves (the `_COMMIT` manager in .github/renovate.json5).
# renovate: datasource=git-refs depName=https://github.com/rtk-ai/rtk branch=master
RTK_INSTALLER_COMMIT="36591fb00d650bf987b57483c0b3a395a35a8dc1"
log "Installing RTK"
RTK_SCRIPT="/tmp/rtk-install.sh"
curl "${CURL_RETRY[@]}" -fsSL "https://raw.githubusercontent.com/rtk-ai/rtk/${RTK_INSTALLER_COMMIT}/install.sh" -o "$RTK_SCRIPT"
if [[ ! -s "$RTK_SCRIPT" ]]; then
  log "RTK install script appears malformed – aborting"
  exit 1
fi
# /usr/bin, not /usr/local/bin - see the Claude Code note above for why.
RTK_INSTALL_DIR=/usr/bin bash "$RTK_SCRIPT"
rm -f "$RTK_SCRIPT"
if [[ ! -x /usr/bin/rtk ]]; then
  log "RTK binary not found at /usr/bin/rtk after install – aborting"
  exit 1
fi

# Third-party tool versions are pinned rather than resolved from
# .../releases/latest. This image rebuilds on a nightly cron, so tracking
# "latest" meant its contents changed on their own and a bad upstream release
# broke the build with nothing in this repo having changed. Renovate watches
# these `renovate:` comments and opens a PR per bump, which keeps updates
# automatic but visible and revertible. It also removes the dependency on
# api.github.com, whose unauthenticated 60 req/hr limit is shared across all
# GitHub Actions runner NAT IPs and used to 403 at random.
#
# What is deliberately NOT pinned, and why: the Oh My Zsh / zsh-plugin clones,
# the LazyVim starter, the google/fonts sparse checkout and the Catppuccin theme
# files below all track their default branch. They are plugin frameworks and
# colorscheme data whose whole point is to track upstream, none of them is
# fetched as a privileged executable, and pinning seven more SHAs would cost
# more churn than the drift is worth. Everything that lands in /usr/bin or runs
# as root during the build IS pinned. Revisit that line, not the list.

# -------------------------------------------------------------------
# NetBird – pinned release download
# -------------------------------------------------------------------
# renovate: datasource=github-releases depName=netbirdio/netbird
NETBIRD_VERSION="v0.75.0"
log "Installing NetBird ${NETBIRD_VERSION}"
# Downloaded under its upstream asset name so the published checksum line, which
# is keyed by filename, can be fed straight to `sha256sum -c`.
NETBIRD_ASSET="netbird_${NETBIRD_VERSION#v}_linux_amd64.tar.gz"
NETBIRD_TAR="/tmp/${NETBIRD_ASSET}"
if ! curl "${CURL_RETRY[@]}" -fSL -o "$NETBIRD_TAR" "https://github.com/netbirdio/netbird/releases/download/${NETBIRD_VERSION}/${NETBIRD_ASSET}"; then
  log "Failed to download NetBird"
  exit 1
fi
NETBIRD_CHECKSUMS="/tmp/netbird-checksums.txt"
if ! curl "${CURL_RETRY[@]}" -fsSL -o "$NETBIRD_CHECKSUMS" "https://github.com/netbirdio/netbird/releases/download/${NETBIRD_VERSION}/netbird_${NETBIRD_VERSION#v}_checksums.txt"; then
  log "Failed to download NetBird checksums"
  exit 1
fi
if ! (cd /tmp && grep " ${NETBIRD_ASSET}$" "$NETBIRD_CHECKSUMS" | sha256sum -c -); then
  log "NetBird checksum verification failed"
  exit 1
fi
tar -xzf "$NETBIRD_TAR" -C /usr/bin/ netbird
chmod +x /usr/bin/netbird
rm -f "$NETBIRD_TAR" "$NETBIRD_CHECKSUMS"

# -------------------------------------------------------------------
# Superfile – terminal file manager (verified release download)
# -------------------------------------------------------------------
# renovate: datasource=github-releases depName=yorukot/superfile
SUPERFILE_VERSION="v1.6.0"
log "Installing Superfile ${SUPERFILE_VERSION}"
SUPERFILE_ASSET="superfile-linux-${SUPERFILE_VERSION}-amd64.tar.gz"
SUPERFILE_TAR="/tmp/${SUPERFILE_ASSET}"
if ! curl "${CURL_RETRY[@]}" -fSL -o "$SUPERFILE_TAR" "https://github.com/yorukot/superfile/releases/download/${SUPERFILE_VERSION}/${SUPERFILE_ASSET}"; then
  log "Failed to download Superfile"
  exit 1
fi
SUPERFILE_CHECKSUMS="/tmp/superfile-checksums.txt"
# A missing checksum file is treated as a hard failure, not a warning: anyone
# able to swap the tarball can drop the manifest too, so skipping verification
# on a 404 would defeat the check it is meant to enforce.
if ! curl "${CURL_RETRY[@]}" -fsSL -o "$SUPERFILE_CHECKSUMS" "https://github.com/yorukot/superfile/releases/download/${SUPERFILE_VERSION}/superfile-${SUPERFILE_VERSION}-checksums.txt"; then
  log "Failed to download Superfile checksums"
  exit 1
fi
if ! (cd /tmp && grep " ${SUPERFILE_ASSET}$" "$SUPERFILE_CHECKSUMS" | sha256sum -c -); then
  log "Superfile checksum verification failed"
  exit 1
fi
SUPERFILE_EXTRACT_DIR="/tmp/superfile-extract"
mkdir -p "$SUPERFILE_EXTRACT_DIR"
tar -xzf "$SUPERFILE_TAR" -C "$SUPERFILE_EXTRACT_DIR"
SUPERFILE_BIN=$(find "$SUPERFILE_EXTRACT_DIR" -type f -name spf -print -quit)
if [[ -z "$SUPERFILE_BIN" ]]; then
  log "Could not find spf binary in Superfile archive"
  exit 1
fi
install -m 0755 "$SUPERFILE_BIN" /usr/bin/spf
rm -rf "$SUPERFILE_TAR" "$SUPERFILE_CHECKSUMS" "$SUPERFILE_EXTRACT_DIR"

# -------------------------------------------------------------------
# Herdr – terminal/agent multiplexer, used here instead of tmux
# -------------------------------------------------------------------
# Upstream ships a single statically linked Rust binary per platform and
# publishes no checksum file alongside it, so the artifact is verified by
# executing it after install rather than by hash.
# renovate: datasource=github-releases depName=ogulcancelik/herdr
HERDR_VERSION="v0.7.5"
log "Installing Herdr ${HERDR_VERSION}"
HERDR_DOWNLOAD="/tmp/herdr-linux-x86_64"
if ! curl "${CURL_RETRY[@]}" -fSL -o "$HERDR_DOWNLOAD" "https://github.com/ogulcancelik/herdr/releases/download/${HERDR_VERSION}/herdr-linux-x86_64"; then
  log "Failed to download Herdr"
  exit 1
fi
install -m 0755 "$HERDR_DOWNLOAD" /usr/bin/herdr
rm -f "$HERDR_DOWNLOAD"
if ! /usr/bin/herdr --version; then
  log "Herdr binary is not runnable after install"
  exit 1
fi
install -d /usr/share/zsh/site-functions
if ! /usr/bin/herdr completion zsh > /usr/share/zsh/site-functions/_herdr; then
  log "Failed to generate Herdr zsh completions - skipping"
  rm -f /usr/share/zsh/site-functions/_herdr
fi

# -------------------------------------------------------------------
# Proton Pass CLI – secret retrieval, incl. chezmoi's protonPass templates
# -------------------------------------------------------------------
# Not packaged in Fedora/Terra/RPM Fusion, so this is a release download.
# Upstream ships one statically linked binary per platform *plus* a matching
# .sha256, so unlike Herdr it is hash-verified rather than exercised.
# Note the tag carries no leading "v" (2.2.3, not v2.2.3) - unlike every other
# pin in this file - so PASS_CLI_VERSION is used bare in the download URL.
# renovate: datasource=github-releases depName=protonpass/pass-cli
PASS_CLI_VERSION="2.2.3"
log "Installing Proton Pass CLI ${PASS_CLI_VERSION}"
PASS_CLI_ASSET="pass-cli-linux-x86_64"
PASS_CLI_DOWNLOAD="/tmp/${PASS_CLI_ASSET}"
PASS_CLI_BASE_URL="https://github.com/protonpass/pass-cli/releases/download/${PASS_CLI_VERSION}"
if ! curl "${CURL_RETRY[@]}" -fSL -o "$PASS_CLI_DOWNLOAD" "${PASS_CLI_BASE_URL}/${PASS_CLI_ASSET}"; then
  log "Failed to download Proton Pass CLI"
  exit 1
fi
# As with Superfile, a missing checksum file is a hard failure rather than a
# skipped check. This one already names its asset in `sha256sum -c` format, so
# it is fed in whole instead of grepped out of a combined manifest.
PASS_CLI_CHECKSUM="/tmp/${PASS_CLI_ASSET}.sha256"
if ! curl "${CURL_RETRY[@]}" -fsSL -o "$PASS_CLI_CHECKSUM" "${PASS_CLI_BASE_URL}/${PASS_CLI_ASSET}.sha256"; then
  log "Failed to download Proton Pass CLI checksum"
  exit 1
fi
if ! (cd /tmp && sha256sum -c "$PASS_CLI_CHECKSUM"); then
  log "Proton Pass CLI checksum verification failed"
  exit 1
fi
install -m 0755 "$PASS_CLI_DOWNLOAD" /usr/bin/pass-cli
rm -f "$PASS_CLI_DOWNLOAD" "$PASS_CLI_CHECKSUM"
# Subcommand is "completions" (plural), unlike Herdr's "completion".
if ! /usr/bin/pass-cli completions zsh > /usr/share/zsh/site-functions/_pass-cli; then
  log "Failed to generate Proton Pass CLI zsh completions - skipping"
  rm -f /usr/share/zsh/site-functions/_pass-cli
fi

# -------------------------------------------------------------------
# Google Fonts – curated subset, from the Fedora repositories
# -------------------------------------------------------------------
# These used to come from a blobless sparse checkout of google/fonts. Fedora
# packages 12 of the 14 families for the same ~35 MB on disk, which removes a
# clone of a very large repository from every nightly build - the cost of that
# clone is in the repo metadata, not in how many directories get checked out,
# so fetching even one family that way is expensive.
#
# Poppins and Fira Sans are not packaged in Fedora, Terra or RPM Fusion and are
# therefore dropped: nothing in this image selects them by name, they only ever
# populated the font menu. Do NOT reintroduce the clone to get them back.
#
# Failure here is fatal on purpose. install_pkg_chunk passes --skip-unavailable,
# so a package renamed upstream would otherwise be skipped in silence and the
# image would quietly ship a different set of fonts than this list claims.
log "Installing Google Fonts (curated subset, from Fedora)"
GOOGLE_FONT_PKGS=(
  rsms-inter-vf-fonts              # Inter
  google-roboto-fonts              # Roboto
  google-roboto-mono-fonts         # Roboto Mono
  open-sans-fonts                  # Open Sans
  lato-fonts                       # Lato
  julietaula-montserrat-fonts      # Montserrat
  adobe-source-code-pro-fonts      # Source Code Pro
  vernnobile-nunito-fonts          # Nunito
  weiweihuanghuang-work-sans-fonts # Work Sans
  fira-code-fonts                  # Fira Code
  ibm-plex-sans-fonts              # IBM Plex Sans
  ibm-plex-mono-fonts              # IBM Plex Mono
)
if ! install_pkg_chunk "${GOOGLE_FONT_PKGS[@]}"; then
  log "Failed to install Google Fonts packages"
  exit 1
fi
for font_pkg in "${GOOGLE_FONT_PKGS[@]}"; do
  if ! rpm -q "$font_pkg" >/dev/null 2>&1; then
    log "Google Font package not installed: $font_pkg (renamed or dropped upstream?)"
    exit 1
  fi
done
log "Installed ${#GOOGLE_FONT_PKGS[@]} Google Font packages"

# -------------------------------------------------------------------
# JetBrainsMono Nerd Font – verified download
# -------------------------------------------------------------------
# The upstream archive carries 96 files: every weight of three separate
# families (the base one plus the Mono and Propo spacing variants), ~223 MB
# installed. Ghostty and the fontconfig monospace alias both ask for
# "JetBrainsMono Nerd Font", which is the base family, so extract only its four
# standard styles - about 10 MB.
# renovate: datasource=github-releases depName=ryanoasis/nerd-fonts
NERDFONT_VERSION="v3.4.0"
log "Installing JetBrainsMono Nerd Font ${NERDFONT_VERSION}"
JBZIP="/tmp/JetBrainsMono.zip"
if curl "${CURL_RETRY[@]}" -fSL -o "$JBZIP" "https://github.com/ryanoasis/nerd-fonts/releases/download/${NERDFONT_VERSION}/JetBrainsMono.zip"; then
  # Upstream publishes one SHA-256.txt covering every font archive in the release.
  NERDFONT_CHECKSUMS="/tmp/nerd-fonts-SHA-256.txt"
  if ! curl "${CURL_RETRY[@]}" -fsSL -o "$NERDFONT_CHECKSUMS" "https://github.com/ryanoasis/nerd-fonts/releases/download/${NERDFONT_VERSION}/SHA-256.txt"; then
    log "Failed to download JetBrainsMono Nerd Font checksums"
    exit 1
  fi
  if ! (cd /tmp && grep " JetBrainsMono.zip$" "$NERDFONT_CHECKSUMS" | sha256sum -c -); then
    log "JetBrainsMono Nerd Font checksum verification failed"
    exit 1
  fi
  rm -f "$NERDFONT_CHECKSUMS"
  mkdir -p /usr/share/fonts/JetBrainsMonoNerdFont
  unzip -q -j -o "$JBZIP" \
    'JetBrainsMonoNerdFont-Regular.ttf' \
    'JetBrainsMonoNerdFont-Italic.ttf' \
    'JetBrainsMonoNerdFont-Bold.ttf' \
    'JetBrainsMonoNerdFont-BoldItalic.ttf' \
    -d /usr/share/fonts/JetBrainsMonoNerdFont
  rm -f "$JBZIP"
  if [[ ! -f /usr/share/fonts/JetBrainsMonoNerdFont/JetBrainsMonoNerdFont-Regular.ttf ]]; then
    log "JetBrainsMono Nerd Font archive layout changed - no fonts extracted"
    exit 1
  fi
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
install -D -m 0644 /ctx/system_files/etc/greetd/config.toml /etc/greetd/config.toml
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
# renovate: datasource=github-releases depName=catppuccin/cursors
CURSORS_VERSION="v2.0.0"
log "Installing Catppuccin cursors ${CURSORS_VERSION}"
CURSORS_ZIP="/tmp/catppuccin-cursors.zip"
if curl "${CURL_RETRY[@]}" -fSL -o "$CURSORS_ZIP" "https://github.com/catppuccin/cursors/releases/download/${CURSORS_VERSION}/catppuccin-mocha-peach-cursors.zip"; then
  unzip -q -o "$CURSORS_ZIP" -d /usr/share/icons
  rm -f "$CURSORS_ZIP"
else
  log "Failed to download Catppuccin cursors - skipping"
fi

# renovate: datasource=github-releases depName=PapirusDevelopmentTeam/papirus-folders
PAPIRUS_FOLDERS_VERSION="v1.14.0"
log "Recoloring Papirus folders to Catppuccin Mocha/Peach"
PAPIRUS_FOLDERS_SRC="/tmp/papirus-folders-src"
if git clone --depth 1 https://github.com/catppuccin/papirus-folders.git "$PAPIRUS_FOLDERS_SRC"; then
  cp -rf "$PAPIRUS_FOLDERS_SRC"/src/* /usr/share/icons/Papirus/
  rm -rf "$PAPIRUS_FOLDERS_SRC"
  # This script ships in the image and runs as root here, so it is pinned to a
  # release tag rather than the master tip. Upstream publishes no checksum
  # alongside it, so it is verified by executing it after install - the same
  # approach used for Herdr above.
  if curl "${CURL_RETRY[@]}" -fsSL -o /usr/bin/papirus-folders "https://raw.githubusercontent.com/PapirusDevelopmentTeam/papirus-folders/${PAPIRUS_FOLDERS_VERSION}/papirus-folders"; then
    chmod +x /usr/bin/papirus-folders
    if ! /usr/bin/papirus-folders --version; then
      log "papirus-folders is not runnable after install - aborting"
      exit 1
    fi
    /usr/bin/papirus-folders -C cat-mocha-peach --theme Papirus-Dark
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
if curl "${CURL_RETRY[@]}" -fsSL -o /etc/skel/.config/btop/themes/catppuccin_mocha.theme https://raw.githubusercontent.com/catppuccin/btop/main/themes/catppuccin_mocha.theme; then
  cat > /etc/skel/.config/btop/btop.conf <<'EOF'
color_theme = "catppuccin_mocha"
theme_background = False
EOF
else
  log "Failed to download btop Catppuccin theme - skipping"
fi

log "Installing Catppuccin theme for bat"
mkdir -p /etc/skel/.config/bat/themes
if curl "${CURL_RETRY[@]}" -fsSL -o "/etc/skel/.config/bat/themes/Catppuccin Mocha.tmTheme" "https://github.com/catppuccin/bat/raw/main/themes/Catppuccin%20Mocha.tmTheme"; then
  echo '--theme="Catppuccin Mocha"' > /etc/skel/.config/bat/config
  # Custom bat themes need a per-user binary cache; build it lazily on first
  # shell start instead of trying to precompute it for a user that doesn't
  # exist yet at image-build time.
  echo 'bat --list-themes 2>/dev/null | grep -q "Catppuccin Mocha" || bat cache --build &>/dev/null' >> /etc/skel/.zshrc
else
  log "Failed to download bat Catppuccin theme - skipping"
fi

log "Installing Catppuccin theme for herdr"
# Herdr ships Catppuccin as a built-in theme (its "catppuccin" is the Mocha
# flavour), so there's nothing to download - just select it and override the
# accent token with Mocha Peach to match the rest of the image.
mkdir -p /etc/skel/.config/herdr
cat > /etc/skel/.config/herdr/config.toml <<'EOF'
[theme]
name = "catppuccin"

[theme.custom]
accent = "#fab387"

[update]
# herdr lives on the read-only bootc image and is updated by rebasing, so
# `herdr update` can't replace it - don't nag about new versions.
version_check = false
EOF

log "Installing Catppuccin theme for lazygit"
mkdir -p /etc/skel/.config/lazygit
if ! curl "${CURL_RETRY[@]}" -fsSL -o /etc/skel/.config/lazygit/config.yml https://raw.githubusercontent.com/catppuccin/lazygit/main/themes/mocha/peach.yml; then
  log "Failed to download lazygit Catppuccin theme - skipping"
fi

log "Installing Catppuccin theme for delta and wiring it as git's pager"
mkdir -p /etc/skel/.config/git
if curl "${CURL_RETRY[@]}" -fsSL -o /etc/skel/.config/git/catppuccin.gitconfig https://raw.githubusercontent.com/catppuccin/delta/main/catppuccin.gitconfig; then
  cat > /etc/skel/.gitconfig <<'EOF'
[include]
	path = ~/.config/git/catppuccin.gitconfig
[core]
	pager = delta
[interactive]
	diffFilter = delta --color-only
[delta]
	features = catppuccin-mocha
EOF
else
  log "Failed to download delta Catppuccin theme - skipping"
fi

log "Installing Catppuccin theme for fzf"
mkdir -p /etc/skel/.config/fzf
if curl "${CURL_RETRY[@]}" -fsSL -o /etc/skel/.config/fzf/catppuccin-mocha.sh https://raw.githubusercontent.com/catppuccin/fzf/main/themes/catppuccin-fzf-mocha.sh; then
  echo 'source ~/.config/fzf/catppuccin-mocha.sh' >> /etc/skel/.zshrc
else
  log "Failed to download fzf Catppuccin theme - skipping"
fi

# The theme above only sets colours. The key bindings are what make fzf worth
# having - Ctrl+R over history, Ctrl+T for a file path, Alt+C to jump into a
# subdirectory - and they live in a separate file that nothing else loads.
if [[ -f /usr/share/fzf/shell/key-bindings.zsh ]]; then
  echo 'source /usr/share/fzf/shell/key-bindings.zsh' >> /etc/skel/.zshrc
else
  log "fzf key-bindings.zsh not found - shortcuts will be unavailable"
fi

log "Installing Catppuccin theme for starship"
# Upstream ships the palette only, not a prompt layout. starship resolves the
# standard colour names (green, red, ...) against the active palette, so this
# recolours the default prompt without changing its format - which is the
# point: the prompt keeps showing directory, git status and command duration
# exactly as before, in Mocha colours.
mkdir -p /etc/skel/.config
STARSHIP_PALETTE="/tmp/starship-mocha.toml"
if curl "${CURL_RETRY[@]}" -fsSL -o "$STARSHIP_PALETTE" https://raw.githubusercontent.com/catppuccin/starship/main/themes/mocha.toml; then
  {
    echo 'palette = "catppuccin_mocha"'
    echo
    cat "$STARSHIP_PALETTE"
    # The palette defines Catppuccin's own colour names and overrides the
    # standard ones it shares (red, green, yellow, blue...). It has no `cyan`
    # or `purple`, which is what the default directory and git_branch styles
    # ask for, so those two would stay plain ANSI while everything around them
    # turned Mocha. Point them at the palette's nearest equivalents.
    echo
    echo '[directory]'
    echo 'style = "bold blue"'
    echo
    echo '[git_branch]'
    echo 'style = "bold mauve"'
  } > /etc/skel/.config/starship.toml
else
  log "Failed to download starship Catppuccin palette - skipping"
fi
rm -f "$STARSHIP_PALETTE"

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

log "Installing Catppuccin theme for superfile"
mkdir -p /etc/skel/.config/superfile/theme
if curl "${CURL_RETRY[@]}" -fsSL -o /etc/skel/.config/superfile/theme/catppuccin-mocha-peach.toml https://raw.githubusercontent.com/catppuccin/superfile/main/themes/mocha/catppuccin-mocha-peach.toml; then
  cat > /etc/skel/.config/superfile/config.toml <<'EOF'
theme = "catppuccin-mocha-peach"
EOF
else
  log "Failed to download superfile Catppuccin theme - skipping"
fi

log "Installing Catppuccin theme for zsh-syntax-highlighting"
mkdir -p /etc/skel/.zsh
if curl "${CURL_RETRY[@]}" -fsSL -o /etc/skel/.zsh/catppuccin_mocha-zsh-syntax-highlighting.zsh https://raw.githubusercontent.com/catppuccin/zsh-syntax-highlighting/main/themes/catppuccin_mocha-zsh-syntax-highlighting.zsh; then
  # Must be sourced before the zsh-syntax-highlighting plugin loads.
  sed -i '\#source \$ZSH/oh-my-zsh.sh#i source ~/.zsh/catppuccin_mocha-zsh-syntax-highlighting.zsh' /etc/skel/.zshrc
else
  log "Failed to download zsh-syntax-highlighting Catppuccin theme - skipping"
fi

# Raw evdev access for DMS - see the rule file itself for why.
install -D -m 0644 /ctx/system_files/usr/lib/udev/rules.d/91-dms-input-uaccess.rules \
    /usr/lib/udev/rules.d/91-dms-input-uaccess.rules

# -------------------------------------------------------------------
# SELinux context restoration (after all custom files are in place)
# -------------------------------------------------------------------
log "Restoring SELinux contexts"
restorecon -Rv /etc/greetd \
    /etc/systemd/system/display-manager.service \
    /etc/skel/.config \
    /etc/skel/.zsh \
    /etc/skel/.local \
    /usr/lib/systemd/user/dms.service \
    /usr/lib/udev/rules.d/91-dms-input-uaccess.rules \
    /usr/bin/rtk \
    /usr/bin/papirus-folders \
    /usr/bin/herdr \
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
