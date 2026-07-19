#!/bin/bash

set -ouex pipefail

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
dnf -y install nautilus mpv gnome-terminal gnome-system-monitor gnome-calculator loupe mc btop rsync tmux fastfetch unzip git wget curl

## Virtualizzazione
dnf -y install qemu-kvm libvirt virt-install virt-manager

## Terra enable
dnf5 config-manager setopt terra.enabled=1 2>/dev/null || \
    dnf -y install --nogpgcheck --repofrompath 'terra,https://repos.fyralabs.com/terra$releasever' terra-release

## Ghostty
dnf -y install ghostty

# fully-featured ffmpeg con componenti non-free da rpm fusion
dnf -y install https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm
dnf -y install ffmpeg x264-libs --allowerasing

# Codec multimediali extra
dnf -y swap ffmpeg-free ffmpeg --allowerasing
dnf -y install gstreamer1-plugins-good gstreamer1-plugins-bad-free gstreamer1-plugins-bad-freeworld gstreamer1-plugins-ugly gstreamer1-libav --allowerasing --setopt="install_weak_deps=False" --exclude=PackageKit-gstreamer-plugin

# Nautilus open any terminal extension
curl -Lo /etc/yum.repos.d/nautilus-open-any-terminal.repo \
    https://copr.fedorainfracloud.org/coprs/monkeygold/nautilus-open-any-terminal/repo/fedora-$(rpm -E %fedora)/monkeygold-nautilus-open-any-terminal-fedora-$(rpm -E %fedora).repo
# dnf install -y nautilus-open-any-terminal
# glib-compile-schemas /usr/share/glib-2.0/schemas
# gsettings set com.github.stunkymonkey.nautilus-open-any-terminal terminal kitty

## Brave Origin (Extracting severely malformed RPM)
dnf -y config-manager addrepo --from-repofile=https://brave-browser-rpm-release.s3.brave.com/brave-browser.repo
dnf -y install brave-keyring
dnf -y download brave-origin

# The brave-origin RPM is malformed (cpio mkdir fails on existing /opt).
# Extract manually using rpm2cpio (always available on Fedora).
BRAVE_RPM="$(ls brave-origin-*.rpm 2>/dev/null | head -1)"
if [ -n "$BRAVE_RPM" ]; then
    mkdir -p /tmp/brave-extract
    cd /tmp/brave-extract
    rpm2cpio /"$BRAVE_RPM" 2>/dev/null | cpio -idm 2>/dev/null || true

    # /opt is a broken symlink to /var/opt on Aurora — create target directly
    mkdir -p /var/opt/brave.com
    [ -d opt/brave.com/brave-origin ] && cp -rf opt/brave.com/brave-origin /opt/brave.com/
    [ -d etc ] && cp -rf etc/* /etc/ 2>/dev/null || true

    cd /
    rm -rf /tmp/brave-extract
fi
rm -f /brave-origin-*.rpm

# Install Niri
dnf -y install niri

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
    /usr/lib/systemd/user/dms.service || true

# Abilita DMS per TUTTI gli utenti (fix definitivo: non dipende più da /etc/skel,
# quindi funziona anche per utenti già esistenti prima di questo build)
systemctl --global enable dms.service

## --- FINE SETUP GREETD/DMS ---

# DEV packages
#dnf -y install cargo evtest git input-remapper libevdev-devel libinput-utils python3-devel
# dnf -y install bitwarden-cli

## VSCodium
rpmkeys --import https://gitlab.com/paulcarroty/vscodium-deb-rpm-repo/-/raw/master/pub.gpg
cat > /etc/yum.repos.d/vscodium.repo << 'EOF'
[gitlab.com_paulcarroty_vscodium_repo]
name=download.vscodium.com
baseurl=https://download.vscodium.com/rpms/
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=https://gitlab.com/paulcarroty/vscodium-deb-rpm-repo/-/raw/master/pub.gpg
metadata_expire=1h
EOF
dnf -y install codium

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
