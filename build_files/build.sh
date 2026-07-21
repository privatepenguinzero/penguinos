#!/bin/bash

set -ouex pipefail

# Bluefin ha /usr/local -> ../var/usrlocal e /root -> var/roothome.
# Assicuriamoci che i target dei symlink esistano prima che npm/pip/etc. ci scrivano.
mkdir -p /var/usrlocal/bin /var/usrlocal/lib /var/roothome

## DNF5 Speedup
sed -i '/^\[main\]/a max_parallel_downloads=10' /etc/dnf/dnf.conf

## DNF extra options (da fedora_things_to_do.sh)
sed -i '/^\[main\]/a fastestmirror=True' /etc/dnf/dnf.conf
sed -i '/^\[main\]/a defaultyes=True' /etc/dnf/dnf.conf

## Aggiornamenti automatici
dnf -y install dnf5-plugin-automatic
cp /usr/share/dnf5/dnf5-plugins/automatic.conf /etc/dnf/automatic.conf
sed -i 's/apply_updates = no/apply_updates = yes/' /etc/dnf/automatic.conf
systemctl enable dnf5-automatic.timer

## SSH server
dnf -y install openssh-server
systemctl enable sshd

## System apps
dnf -y install nautilus mpv gnome-terminal gnome-system-monitor gnome-calculator loupe mc btop rsync tmux fastfetch unzip git wget curl bat eza duf jq tealdeer iperf3 just

## Virtualizzazione e containerizzazione
dnf -y install qemu-kvm libvirt virt-install virt-manager gnome-boxes distrobox podman-compose

## Imposta hostname di default per l'immagine
echo "penguinos" > /etc/hostname

## Terra enable
dnf5 config-manager setopt terra.enabled=1 2>/dev/null || \
    dnf -y install --nogpgcheck --repofrompath 'terra,https://repos.fyralabs.com/terra$releasever' terra-release

## Ghostty
dnf -y install ghostty
# Ship default Ghostty config to /etc/skel
mkdir -p /etc/skel/.config/ghostty
cp -rf /ctx/dot_config/ghostty/config /etc/skel/.config/ghostty/

## Rust toolchain
dnf -y install cargo

# fully-featured ffmpeg con componenti non-free da rpm fusion
dnf -y install https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm
dnf -y install ffmpeg x264-libs --allowerasing

# Codec multimediali extra
dnf -y swap ffmpeg-free ffmpeg --allowerasing
dnf -y install gstreamer1-plugins-good gstreamer1-plugins-bad-free gstreamer1-plugins-bad-freeworld gstreamer1-plugins-ugly gstreamer1-libav --allowerasing --setopt="install_weak_deps=False" --exclude=PackageKit-gstreamer-plugin

## Python tooling
dnf -y install python3-pip python3-devel
# uv (standalone binary)
curl -LsSf https://github.com/astral-sh/uv/releases/latest/download/uv-x86_64-unknown-linux-gnu.tar.gz \
  | tar xzf - -C /usr/bin --strip-components=1
chmod +x /usr/bin/uv /usr/bin/uvx

## Utility CLI
dnf -y install yq bind-utils rpm-build

# Nautilus open any terminal extension
curl -Lo /etc/yum.repos.d/nautilus-open-any-terminal.repo \
    https://copr.fedorainfracloud.org/coprs/monkeygold/nautilus-open-any-terminal/repo/fedora-$(rpm -E %fedora)/monkeygold-nautilus-open-any-terminal-fedora-$(rpm -E %fedora).repo
dnf install -y nautilus-open-any-terminal
glib-compile-schemas /usr/share/glib-2.0/schemas
gsettings set com.github.stunkymonkey.nautilus-open-any-terminal terminal ghostty

## Brave Origin (Official RPM package)
dnf -y config-manager addrepo --from-repofile=https://brave-browser-rpm-release.s3.brave.com/brave-browser.repo
dnf -y install brave-keyring

# On Fedora Atomic, /opt is symlinked to /var/opt, which breaks RPM cpio extraction
# (the RPM tries to mkdir under /opt and fails because the symlink target differs).
# Remove the symlink and create /opt as a real directory before installing brave-origin.
# Also create /var/opt so rpm-ostree can preserve it across deployments.
rm -f /opt && mkdir /opt
mkdir -p /var/opt

# Install brave-origin directly via dnf — the package is available and functional
dnf -y install brave-origin

# Install Niri
dnf -y install niri niri-settings

curl -Lo /etc/yum.repos.d/peterwu.repo \
    https://copr.fedorainfracloud.org/coprs/peterwu/rendezvous/repo/fedora-$(rpm -E %fedora)/peterwu-rendezvous-fedora-$(rpm -E %fedora).repo
dnf -y install bibata-cursor-themes

# Install Dank Linux shell (DMS)
curl --output-dir "/etc/yum.repos.d/" \
    --remote-name "https://copr.fedorainfracloud.org/coprs/avengemedia/dms/repo/fedora-$(rpm -E %fedora)/avengemedia-dms-fedora-$(rpm -E %fedora).repo"
dnf -y install quickshell dms greetd dms-greeter --allowerasing

## --- SETUP GREETD/DMS (sezione corretta) ---

# Config greetd
mkdir -p /etc/greetd/
cat > /etc/greetd/config.toml << EOF
[terminal]
vt = 1

[default_session]
user = "greeter"
command = "dms-greeter --command niri"
EOF

# Disabilita esplicitamente gdm PRIMA di impostare greetd come display manager
# (evita che restino due DM abilitati in conflitto)
systemctl disable gdm.service 2>/dev/null || true

# Imposta greetd come display manager al posto di gdm
rm -f /etc/systemd/system/display-manager.service
ln -s /usr/lib/systemd/system/greetd.service /etc/systemd/system/display-manager.service
systemctl enable --force greetd.service

# Sessione utente di default con niri + dms
mkdir -p /etc/skel/.config/systemd/user/graphical-session.target.wants
ln -s /usr/lib/systemd/user/dms.service /etc/skel/.config/systemd/user/graphical-session.target.wants/

mkdir -p /etc/skel/.config/niri/
cp -rf /ctx/dot_config/niri/config.kdl /etc/skel/.config/niri/

# IMPORTANTE: riallinea il contesto SELinux di tutto ciò che abbiamo creato/modificato a mano.
# Senza questo, greetd/dms possono venire bloccati da SELinux al boot (schermo nero/hang).
restorecon -Rv /etc/greetd \
    /etc/systemd/system/display-manager.service \
    /etc/skel/.config \
    /usr/lib/systemd/user/dms.service \
    /usr/local/bin/rtk || true

# Abilita DMS per TUTTI gli utenti (fix definitivo: non dipende più da /etc/skel,
# quindi funziona anche per utenti già esistenti prima di questo build)
systemctl --global enable dms.service

## --- FINE SETUP GREETD/DMS ---

## App GUI e utilità
dnf -y install seahorse
flatpak install -y --noninteractive flathub com.github.tchx84.Flatseal 2>/dev/null || true

## Qt Wayland support
dnf -y install qt6-qtwayland

## Cursor (RPM version)
# Install jq for JSON parsing
dnf -y install jq
# Get latest Cursor RPM from official API and install
CURSOR_RPM_URL=$(curl -s 'https://cursor.com/api/download?platform=linux-x64&releaseTrack=stable' | jq -r '.rpmUrl')
if [ -n "$CURSOR_RPM_URL" ]; then
    curl -L -o /tmp/cursor.rpm "$CURSOR_RPM_URL"
    dnf -y install /tmp/cursor.rpm
    rm -f /tmp/cursor.rpm
else
    echo "Warning: Could not determine Cursor RPM URL, skipping Cursor installation."
fi

## Zsh + Oh My Zsh (installati nello skeleton, verranno usati dai nuovi utenti)
dnf -y install zsh zoxide fzf
git clone https://github.com/ohmyzsh/ohmyzsh.git /etc/skel/.oh-my-zsh
cp /etc/skel/.oh-my-zsh/templates/zshrc.zsh-template /etc/skel/.zshrc
git clone https://github.com/zsh-users/zsh-autosuggestions /etc/skel/.oh-my-zsh/custom/plugins/zsh-autosuggestions
git clone https://github.com/marlonrichert/zsh-autocomplete.git /etc/skel/.oh-my-zsh/custom/plugins/zsh-autocomplete
git clone https://github.com/zsh-users/zsh-history-substring-search /etc/skel/.oh-my-zsh/custom/plugins/zsh-history-substring-search
git clone https://github.com/zsh-users/zsh-syntax-highlighting.git /etc/skel/.oh-my-zsh/custom/plugins/zsh-syntax-highlighting
sed -i 's/plugins=(git)/plugins=(dnf aliases genpass git zsh-autosuggestions zsh-autocomplete zsh-history-substring-search z zsh-syntax-highlighting)/' /etc/skel/.zshrc
sed -i 's/ZSH_THEME="robbyrussell"/ZSH_THEME="jonathan"/' /etc/skel/.zshrc
echo 'eval "$(zoxide init zsh --cmd cd)"' >> /etc/skel/.zshrc

## LazyVim (Neovim distribution)
dnf -y install neovim ripgrep fd-find lazygit xclip wl-clipboard gcc gcc-c++ make
git clone https://github.com/LazyVim/starter /etc/skel/.config/nvim
rm -rf /etc/skel/.config/nvim/.git

## Claude Code (CLI AI assistant by Anthropic)
dnf -y install nodejs npm
npm install -g @anthropic-ai/claude-code

## RTK — Rust Token Killer (token-optimized CLI proxy)
# Installed alongside Claude Code in /usr/local/bin so it's available system-wide
curl -fsSL https://raw.githubusercontent.com/rtk-ai/rtk/refs/heads/master/install.sh | sh

## NetBird (solo il programma, nessuna configurazione automatica)
NETBIRD_VERSION=$(curl -s https://api.github.com/repos/netbirdio/netbird/releases/latest | grep tag_name | cut -d '"' -f4)
curl -fLo /tmp/netbird.tar.gz "https://github.com/netbirdio/netbird/releases/download/${NETBIRD_VERSION}/netbird_${NETBIRD_VERSION#v}_linux_amd64.tar.gz"
tar -xzf /tmp/netbird.tar.gz -C /usr/bin/
chmod +x /usr/bin/netbird
rm -f /tmp/netbird.tar.gz

## Google Fonts (system-wide, non nella home utente che non esiste ancora in fase di build)
curl -Lo /tmp/google-fonts.zip https://github.com/google/fonts/archive/main.zip
mkdir -p /usr/share/fonts/google
unzip -q /tmp/google-fonts.zip -d /usr/share/fonts/google
rm -f /tmp/google-fonts.zip
fc-cache -f

## Nerd Font Ghostty (JetBrainsMono Nerd Font)
mkdir -p /usr/share/fonts/JetBrainsMonoNerdFont
curl -fLo /tmp/JetBrainsMono.zip https://github.com/ryanoasis/nerd-fonts/releases/latest/download/JetBrainsMono.zip
unzip -q /tmp/JetBrainsMono.zip -d /usr/share/fonts/JetBrainsMonoNerdFont
rm -f /tmp/JetBrainsMono.zip
fc-cache -f

## Icone e font management
dnf -y install papirus-icon-theme

#### Enable podman
systemctl enable podman.socket

# Remove waybar in modo sicuro, senza trascinare via dipendenze condivise
dnf -y remove waybar --noautoremove || true

# this is needed for some glib applications
glib-compile-schemas /usr/share/glib-2.0/schemas/

## CLEAN UP
dnf5 -y clean all
rm -rf /run/dnf /run/selinux-policy
rm -rf /var/lib/dnf
